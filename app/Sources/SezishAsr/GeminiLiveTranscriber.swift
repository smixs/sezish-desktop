import Foundation
import os
import SezishCore

public enum GeminiLiveError: LocalizedError, Equatable {
    case invalidApiKey
    case connectionFailed(String)
    case serverClosed(code: Int, reason: String)
    case setupTimeout
    case finalTimeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidApiKey:
            return "Ключ Gemini не принят сервером. Проверьте ключ в настройках."
        case .connectionFailed(let reason):
            return "Не удалось соединиться с Gemini: \(reason)"
        case .serverClosed(let code, let reason):
            return "Gemini закрыл соединение (код \(code)): \(reason)"
        case .setupTimeout:
            return "Gemini не открыл сессию вовремя. Попробуйте ещё раз."
        case .finalTimeout:
            return "Gemini не прислал финальный текст. Попробуйте ещё раз."
        case .cancelled:
            return "Сессия Gemini отменена."
        }
    }
}

/// Stopwatch over the injected clock. `any Clock<Duration>` hides its `Instant`, so `now`
/// cannot be read through the existential at all; closing over the concrete clock once, at
/// construction, is the only way to measure with it.
struct ElapsedTimer: Sendable {
    private let begin: @Sendable () -> @Sendable () -> Duration

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        begin = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    /// Starts a measurement. The returned closure answers how long ago that happened.
    func started() -> @Sendable () -> Duration { begin() }
}

/// Streaming dictation over `gemini-3.5-transcribe-live`.
///
/// One socket serves the whole app session: the spike measured 0.57-0.89 s for handshake plus
/// setup, and the server keeps the connection alive between takes with no context bleeding
/// from one take into the next. A take is `activityStart` → audio chunks → `activityEnd` →
/// `generationComplete`; the socket stays open afterwards.
public actor GeminiLiveTranscriber: StreamingTranscriber {
    /// 100 ms at 16 kHz — the cadence the spike ran at, and the one that keeps
    /// `activityEnd` → final at ~0.3 s instead of ~1.2 s.
    private static let chunkSamples = 1_600
    /// 30 s at 16 kHz. Below it the socket keeps up with a file poured into it; above it the
    /// take belongs to the batch endpoint.
    static let batchAfterSamples = 30 * 16_000
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let apiKey: String
    private let mode: GeminiTranscriptionMode
    private let transport: any WebSocketTransport
    private let clock: any Clock<Duration>
    private let setupTimeout: Duration
    private let finalTimeout: Duration
    private let keepaliveInterval: Duration
    private let staleAfter: Duration
    private let elapsed: ElapsedTimer
    private let url: URL
    /// The unary route for takes too long for the socket.
    private let batch: GeminiBatchTranscriber

    /// `.notice` and `.error` are the levels that survive on disk, so this is what
    /// `log show --predicate 'subsystem == "com.smixs.sezish"'` gets to see after the fact.
    /// The key lives in the URL, so nothing here ever prints a URL or an unredacted error.
    private nonisolated let logger = Logger(subsystem: "com.smixs.sezish", category: "gemini")

    private nonisolated let buffer = SampleBuffer()

    // Session (survives takes).
    private var socketGeneration = 0
    private var hasSocket = false
    private var isOpen = false
    private var setupDone = false
    private var setupWaiter: CheckedContinuation<Void, Error>?
    /// Why the current socket died. Kept because the close can beat `waitForSetup` to the
    /// continuation, and then there is nobody to resume.
    private var sessionFailure: Error?
    private var receiveTask: Task<Void, Never>?
    /// Pings the socket while nobody is dictating. A socket left alone dies quietly: `send`
    /// into a stale TCP does not fail, it hangs until the idle timeout.
    private var keepaliveTask: Task<Void, Never>?
    /// How long ago the last frame went out or came in.
    private var sinceLastFrame: @Sendable () -> Duration
    /// The handshake in flight. `warmup` and the key press race each other by design, and the
    /// loser must wait for the winner instead of dropping a half-open socket.
    private var connectTask: Task<Void, Error>?
    private var connectToken = 0

    // Take (one key press).
    private var takeGeneration = 0
    private var startTask: Task<Void, Never>?
    private var takeActive = false
    private var speaking = false
    private var finishing = false
    private var finals: [String] = []
    private var takeError: Error?
    private var generationDone = false
    private var finalWaiter: CheckedContinuation<Void, Error>?
    private var drainTask: Task<Void, Never>?
    /// The server warned it is closing this session. Honoured between takes.
    private var reconnectAfterTake = false

    public init(
        apiKey: String,
        mode: GeminiTranscriptionMode,
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        http: any HTTPTransport = URLSessionHTTPTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        setupTimeout: Duration = .seconds(10),
        finalTimeout: Duration = .seconds(20),
        keepaliveInterval: Duration = .seconds(10),
        staleAfter: Duration = .seconds(45)
    ) {
        self.apiKey = apiKey
        self.mode = mode
        self.transport = transport
        self.clock = clock
        self.setupTimeout = setupTimeout
        self.finalTimeout = finalTimeout
        self.keepaliveInterval = keepaliveInterval
        self.staleAfter = staleAfter
        batch = GeminiBatchTranscriber(apiKey: apiKey, mode: mode, transport: http)
        let elapsed = ElapsedTimer(clock)
        self.elapsed = elapsed
        sinceLastFrame = elapsed.started()

        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        url = components.url!
    }

    // MARK: - Transcriber

    /// Pays the handshake up front. Failures are silent on purpose: this runs on a hunch that
    /// dictation is coming, and a real failure shows up again in `finishStream`.
    public func warmup() async {
        await honourGoAway()
        try? await ensureConnected()
    }

    /// Unary path (retry from history): one take, start to finish.
    ///
    /// A recording is not speech arriving in realtime — it goes out as fast as the socket
    /// takes it, and past a couple of minutes the server answers that with
    /// «Resource has been exhausted» and closes the session. Anything longer than
    /// `batchAfterSamples` therefore goes over the unary endpoint instead, which eats a whole
    /// file in one request. Short retries stay on the socket: it is already open and warm.
    public func transcribe(_ samples16k: [Float]) async throws -> String {
        guard !samples16k.isEmpty else { return "" }
        if samples16k.count > Self.batchAfterSamples {
            return try await batch.transcribe(samples16k)
        }
        await startStream()
        feed(samples16k)
        return try await finishStream()
    }

    // MARK: - StreamingTranscriber

    /// Opening the session is slow (handshake plus setup), and the key can be released before
    /// it finishes. The work goes into `startTask` so `finishStream` can wait for it instead of
    /// racing it: without that, `activityEnd` would go out before `activityStart`.
    public func startStream() async {
        takeGeneration += 1
        let generation = takeGeneration
        finals = []
        takeError = nil
        generationDone = false
        takeActive = true
        speaking = false
        let task = Task { await self.openTake(generation: generation) }
        startTask = task
        await task.value
    }

    private func openTake(generation: Int) async {
        do {
            try await connectAndAnnounceSpeech(generation: generation)
        } catch {
            // Esc (or another take) already moved on: this one owns nothing anymore.
            guard generation == takeGeneration else { return }
            // Mapped here too: `waitForSetup` can throw a bare CancellationError, and the
            // coordinator writes whatever lands here into the history.
            takeError = mapped(error)
            return
        }
        guard generation == takeGeneration else { return }
        speaking = true
        // Whatever `feed` buffered while the session was opening goes out now.
        scheduleDrain()
    }

    public nonisolated func feed(_ samples16k: [Float]) {
        guard !samples16k.isEmpty else { return }
        buffer.append(samples16k)
        Task { await self.scheduleDrain() }
    }

    public func finishStream() async throws -> String {
        let result: Result<String, Error>
        do {
            result = .success(try await runFinish())
        } catch {
            logger.error("take failed: \(self.describe(error), privacy: .public)")
            result = .failure(error)
        }
        await honourGoAway()
        return try result.get()
    }

    /// Acts on a `goAway` once the take is over: the next one opens a fresh socket instead of
    /// starting on a session the server is about to close.
    private func honourGoAway() async {
        guard reconnectAfterTake, !takeActive else { return }
        await disconnect(reason: "session marked for reconnect")
    }

    private func runFinish() async throws -> String {
        await startTask?.value
        // From here the tail is `flushTail`'s alone: a drain started by `feed` would race it
        // for the buffer and could land audio after `activityEnd`.
        finishing = true
        defer {
            takeActive = false
            speaking = false
            finishing = false
        }
        if let takeError {
            buffer.reset()
            throw takeError
        }

        await flushTail()
        var sinceActivityEnd: (@Sendable () -> Duration)?
        if takeError == nil {
            do {
                try await send(GeminiLiveProtocol.activityEndMessage)
                logger.notice("activityEnd sent")
                sinceActivityEnd = elapsed.started()
            } catch {
                markSessionDead()
                takeError = mapped(error)
            }
        }
        if takeError == nil, !generationDone {
            do {
                try await waitForGeneration()
            } catch {
                takeError = takeError ?? error
            }
        }
        if let takeError { throw takeError }

        let text = finals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sinceActivityEnd {
            logger.notice(
                "final received \(Self.millis(sinceActivityEnd())) ms after activityEnd, \(text.count) chars")
        }
        return text
    }

    /// Esc must not sit through `setupTimeout`, so this never waits for `startTask`:
    /// bumping the generation and disconnecting is enough. `disconnect` resumes the setup
    /// waiter with a cancellation, and the orphaned start finds its generation gone.
    public func cancelStream() async {
        takeGeneration += 1
        startTask = nil
        takeActive = false
        speaking = false
        finishing = false
        finals = []
        takeError = nil
        generationDone = false
        resumeFinal(throwing: CancellationError())
        drainTask?.cancel()
        drainTask = nil
        buffer.reset()
        // Cheaper than draining the take we no longer want: the next one reconnects.
        await disconnect(reason: "cancelled")
    }

    /// Closes the session for good. The owner calls this before dropping the transcriber
    /// (engine switched in settings): `deinit` cannot await, so a socket carrying the API key
    /// in its URL would otherwise outlive the object that opened it.
    public func shutdown() async {
        await disconnect(reason: "shutdown")
    }

    /// Best effort net: cancels the loop and fires a detached close. `deinit` may read stored
    /// properties but may not await, so the close is not observable from here.
    deinit {
        receiveTask?.cancel()
        keepaliveTask?.cancel()
        guard hasSocket else { return }
        let transport = self.transport
        Task { await transport.close() }
    }

    // MARK: - Session

    /// Every frame that reaches the wire is proof the socket is still alive.
    private func send(_ frame: String) async throws {
        try await transport.send(frame)
        markFrame()
    }

    private func markFrame() { sinceLastFrame = elapsed.started() }

    private func ensureConnected() async throws {
        if isOpen { return }
        if let pending = connectTask {
            try await pending.value
            if isOpen { return }
        }
        connectToken += 1
        let token = connectToken
        let task = Task<Void, Error> { try await self.openSession() }
        connectTask = task
        defer { if connectToken == token { connectTask = nil } }
        try await task.value
    }

    private func openSession() async throws {
        logger.notice("connect started")
        let handshake = elapsed.started()
        do {
            try await openSocket()
        } catch {
            logger.error("connect failed: \(self.describe(error), privacy: .public)")
            throw error
        }
        logger.notice("setupComplete in \(Self.millis(handshake())) ms")
    }

    private func openSocket() async throws {
        await disconnect(reason: "reconnect")
        sessionFailure = nil
        // `disconnect` cannot close what does not exist yet, so a cancellation landing while
        // the handshake runs leaves the socket to this method: it comes back to an owner that
        // is gone and has to hang up itself.
        let generation = socketGeneration
        do {
            try await transport.connect(url)
        } catch {
            throw mapped(error)
        }
        guard generation == socketGeneration else {
            await transport.close()
            throw CancellationError()
        }
        hasSocket = true
        socketGeneration += 1
        setupDone = false
        startReceiveLoop(generation: socketGeneration)
        do {
            try await send(GeminiLiveProtocol.setupMessage(mode: mode))
        } catch {
            throw mapped(error)
        }
        try await waitForSetup(generation: socketGeneration)
        isOpen = true
        markFrame()
        startKeepalive(generation: socketGeneration)
    }

    /// Between takes nothing travels the socket, and a dead TCP looks exactly like a live idle
    /// one until something is written to it. The ping is that something, paid every
    /// `keepaliveInterval` so the answer is here long before the next key press.
    private func startKeepalive(generation: Int) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self, clock, keepaliveInterval] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: keepaliveInterval) } catch { return }
                guard let self else { return }
                await self.keepaliveTick(generation: generation)
            }
        }
    }

    private func keepaliveTick(generation: Int) async {
        // During a take the audio frames are the keepalive; a ping would only add noise.
        guard generation == socketGeneration, isOpen, !takeActive else { return }
        do {
            try await transport.ping()
            guard generation == socketGeneration else { return }
            markFrame()
        } catch {
            guard generation == socketGeneration else { return }
            logger.error("keepalive ping failed: \(self.describe(error), privacy: .public)")
            // A take that slipped in between owns the failure now: `handleFailure` hands it
            // the error, and dropping the socket under it would only lose the diagnosis.
            handleFailure(error, generation: generation)
            guard !takeActive else { return }
            await disconnect(reason: "keepalive")
        }
    }

    /// A socket idle since the last take can be dead without anyone noticing: the first frame
    /// of the new take is where that shows up, so it gets one reconnect.
    private func connectAndAnnounceSpeech(generation: Int) async throws {
        // Past `staleAfter` the socket is not worth the gamble: a fresh handshake costs
        // deterministic tenths of a second, a dead one costs the idle timeout.
        let idle = sinceLastFrame()
        if isOpen, idle >= staleAfter {
            logger.notice("stale session (\(Self.millis(idle) / 1_000) s idle), reconnecting")
            await disconnect(reason: "stale")
        }
        let reused = isOpen
        logger.notice(
            "take start (\(reused ? "reused socket" : "fresh", privacy: .public), idle \(Self.millis(idle) / 1_000) s)")
        try await ensureConnected()
        // Speech is announced only for a take that is still the current one: the handshake
        // is long enough for Esc to happen inside it.
        guard generation == takeGeneration else { throw CancellationError() }
        do {
            try await send(GeminiLiveProtocol.activityStartMessage)
        } catch {
            markSessionDead()
            guard reused else { throw mapped(error) }
            await disconnect(reason: "activityStart failed on a reused socket")
            try await ensureConnected()
            guard generation == takeGeneration else { throw CancellationError() }
            do {
                try await send(GeminiLiveProtocol.activityStartMessage)
            } catch {
                markSessionDead()
                throw mapped(error)
            }
        }
    }

    /// A send that failed means the socket is gone, whatever the receive loop still believes.
    /// The take is lost either way; what must not happen is the next one walking into the same
    /// corpse, so the session is marked dead here and hung up once the take is over.
    private func markSessionDead() {
        isOpen = false
        setupDone = false
        reconnectAfterTake = true
    }

    private func startReceiveLoop(generation: Int) {
        receiveTask = Task { [weak self, transport] in
            while !Task.isCancelled {
                do {
                    let frame = try await transport.receive()
                    guard let self else { return }
                    await self.handle(frame, generation: generation)
                } catch {
                    await self?.handleFailure(error, generation: generation)
                    return
                }
            }
        }
    }

    /// Never call `disconnect` from here: it awaits this very task.
    private func handle(_ frame: String, generation: Int) {
        guard generation == socketGeneration else { return }
        markFrame()
        for event in GeminiLiveProtocol.parse(frame) {
            switch event {
            case .setupComplete:
                setupDone = true
                resumeSetup(throwing: nil)
            case .goAway:
                // Dropping the socket now would cost the take in progress; it waits.
                logger.notice("goAway")
                reconnectAfterTake = true
            case .final(let text):
                guard takeActive else { continue }
                finals.append(text)
            case .generationComplete:
                guard takeActive else { continue }
                generationDone = true
                resumeFinal(throwing: nil)
            case .interim, .empty, .unknown:
                continue
            }
        }
    }

    private func handleFailure(_ error: Error, generation: Int) {
        guard generation == socketGeneration else { return }
        isOpen = false
        setupDone = false
        let reason = mapped(error)
        sessionFailure = reason
        resumeSetup(throwing: reason)
        guard takeActive else { return }
        takeError = takeError ?? reason
        resumeFinal(throwing: reason)
    }

    private func disconnect(reason: String) async {
        if hasSocket { logger.notice("disconnect (\(reason, privacy: .public))") }
        socketGeneration += 1 // anything still in flight on the old socket is dead to us
        isOpen = false
        setupDone = false
        reconnectAfterTake = false
        resumeSetup(throwing: CancellationError())
        // Cancelled, never awaited: this can run inside that very task.
        keepaliveTask?.cancel()
        keepaliveTask = nil
        let loop = receiveTask
        receiveTask = nil
        loop?.cancel()
        if hasSocket {
            hasSocket = false
            await transport.close()
        }
        await loop?.value
    }

    // MARK: - Waiting

    private func waitForSetup(generation: Int) async throws {
        if setupDone { return }
        if let sessionFailure { throw sessionFailure }
        let timeout = Task { [clock, setupTimeout] in
            do { try await clock.sleep(for: setupTimeout) } catch { return }
            self.fireSetupTimeout(generation: generation)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            if setupDone {
                continuation.resume()
                return
            }
            if let sessionFailure {
                continuation.resume(throwing: sessionFailure)
                return
            }
            setupWaiter = continuation
        }
    }

    private func fireSetupTimeout(generation: Int) {
        guard generation == socketGeneration, !setupDone else { return }
        resumeSetup(throwing: GeminiLiveError.setupTimeout)
    }

    private func waitForGeneration() async throws {
        let generation = socketGeneration
        let timeout = Task { [clock, finalTimeout] in
            do { try await clock.sleep(for: finalTimeout) } catch { return }
            self.fireFinalTimeout(generation: generation)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            if generationDone || takeError != nil {
                continuation.resume()
                return
            }
            finalWaiter = continuation
        }
    }

    private func fireFinalTimeout(generation: Int) {
        guard generation == socketGeneration, takeActive, !generationDone else { return }
        resumeFinal(throwing: GeminiLiveError.finalTimeout)
    }

    private func resumeSetup(throwing error: Error?) {
        guard let waiter = setupWaiter else { return }
        setupWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    private func resumeFinal(throwing error: Error?) {
        guard let waiter = finalWaiter else { return }
        finalWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    // MARK: - Audio

    /// Drains are chained, not parallel: chunks must reach the server in the order they were
    /// spoken, and `feed` can fire from the audio thread while a send is still in flight.
    private func scheduleDrain() {
        guard speaking, !finishing, takeError == nil else { return }
        let previous = drainTask
        let generation = takeGeneration
        drainTask = Task { [weak self] in
            await previous?.value
            await self?.drain(tail: false, generation: generation)
        }
    }

    private func flushTail() async {
        let previous = drainTask
        drainTask = nil
        await previous?.value
        await drain(tail: true, generation: takeGeneration)
    }

    /// Cancelling a `Task` does not stop a send: neither this code nor
    /// `URLSessionWebSocketTask.send` is cancellation aware. So every hop out and back checks
    /// whether the take it belongs to is still the current one. A drain left over from a
    /// cancelled take must not spend the next take's audio nor report its own failure.
    private func drain(tail: Bool, generation: Int) async {
        guard generation == takeGeneration, speaking, takeError == nil else { return }
        while let chunk = buffer.take(Self.chunkSamples) {
            await sendAudio(chunk, generation: generation)
            guard generation == takeGeneration, takeError == nil else { return }
        }
        guard tail, generation == takeGeneration else { return }
        let rest = buffer.takeAll()
        if !rest.isEmpty { await sendAudio(rest, generation: generation) }
    }

    private func sendAudio(_ samples: [Float], generation: Int) async {
        guard generation == takeGeneration else { return }
        let frame = GeminiLiveProtocol.audioMessage(pcm16: GeminiLiveProtocol.pcm16(samples))
        do {
            try await send(frame)
        } catch {
            guard generation == takeGeneration else { return }
            markSessionDead()
            takeError = takeError ?? mapped(error)
        }
    }

    // MARK: - Errors

    private func mapped(_ error: Error) -> Error {
        if let close = error as? WebSocketCloseError {
            if close.code == 1_007, close.reason.contains("API key not valid") {
                return GeminiLiveError.invalidApiKey
            }
            return GeminiLiveError.serverClosed(code: close.code, reason: close.reason)
        }
        if error is GeminiLiveError { return error }
        if error is CancellationError { return GeminiLiveError.cancelled }
        return GeminiLiveError.connectionFailed(redacted(error))
    }

    /// One short English line per error for the log. Everything that could carry the key goes
    /// through `redacted`.
    private func describe(_ error: Error) -> String {
        guard let gemini = mapped(error) as? GeminiLiveError else { return redacted(error) }
        switch gemini {
        case .invalidApiKey: return "invalid api key"
        case .connectionFailed(let reason): return reason
        case .serverClosed(let code, let reason): return "server closed \(code): \(reason)"
        case .setupTimeout: return "setup timeout"
        case .finalTimeout: return "final timeout"
        case .cancelled: return "cancelled"
        }
    }

    private static func millis(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// The key lives in the URL, so any URLSession error text is a leak candidate.
    private func redacted(_ error: Error) -> String {
        error.localizedDescription.replacingOccurrences(of: apiKey, with: "***")
    }

    // MARK: - Test seam

    /// Waits until the receive loop has finished handling a socket failure. Tests only:
    /// on a healthy socket the loop never returns.
    func waitForReceiveLoop() async {
        await receiveTask?.value
    }
}
