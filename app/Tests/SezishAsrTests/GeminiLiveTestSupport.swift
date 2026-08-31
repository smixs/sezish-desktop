import Foundation

@testable import SezishAsr

/// Scriptable stand-in for the socket. The test decides what the server says and when:
/// `enqueue` hands the receive loop a frame, `serverClose` ends the connection with a code.
/// Every wait helper is event-driven — no sleeps, no real time.
final class FakeWebSocket: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _connects: [URL] = []
    private var _sent: [String] = []
    private var _sentByConnection: [[String]] = []
    private var closedConnections: Set<Int> = []
    private var _closeCount = 0
    private var _receiveCount = 0
    private var _pingCount = 0
    private var inbox: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var failure: Error?
    private var sendWaiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var receiveWaiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Answers the `setup` frame with `{"setupComplete": {}}`, like the real server does.
    var autoSetupComplete = true
    /// Holds audio frames inside `send`, so a drain running in parallel shows up: its frame
    /// reaches the wire while this one is still in flight. Set to nil to let later frames
    /// through while an earlier one stays parked.
    var audioHold: SendHold? {
        get { lock.withLock { _audioHold } }
        set { lock.withLock { _audioHold = newValue } }
    }
    private var _audioHold: SendHold?
    /// Set to make the next `connect` throw.
    var connectFailure: Error?
    /// Set to make `ping` throw, i.e. a pong that never comes back from a dead TCP.
    var pingFailure: Error?
    /// Set to make `send` throw while the receive loop stays parked — a socket whose death
    /// only the writing side has noticed.
    var sendFailure: Error?
    /// Parks inside `connect`, after the socket is booked but before the handshake finishes.
    var connectHold: SendHold? {
        get { lock.withLock { _connectHold } }
        set { lock.withLock { _connectHold = newValue } }
    }
    private var _connectHold: SendHold?
    /// Closes the socket from inside the `setup` send, i.e. before the client had any chance
    /// to start waiting for `setupComplete`. That is how a bad key actually behaves.
    var closeAfterSetup: (code: Int, reason: String)?

    var connects: [URL] { lock.withLock { _connects } }
    var connectCount: Int { lock.withLock { _connects.count } }
    var sent: [String] { lock.withLock { _sent } }
    /// Frames that reached socket number `index` (1-based), i.e. what that connection saw.
    /// A frame written to a socket that is already closed never lands anywhere.
    func sentOn(connection index: Int) -> [String] {
        lock.withLock { _sentByConnection.indices.contains(index - 1) ? _sentByConnection[index - 1] : [] }
    }
    var closeCount: Int { lock.withLock { _closeCount } }
    var pingCount: Int { lock.withLock { _pingCount } }
    /// How many frames the receive loop has asked for. `n` means `n - 1` frames were handled.
    var receiveCount: Int { lock.withLock { _receiveCount } }

    // MARK: WebSocketTransport

    func connect(_ url: URL) async throws {
        if let connectFailure { throw connectFailure }
        lock.withLock {
            _connects.append(url)
            _sentByConnection.append([])
            inbox.removeAll()
            failure = nil
        }
        if let hold = connectHold { await hold.hold() }
    }

    func send(_ text: String) async throws {
        let isSetup = text.hasPrefix(#"{"setup":"#)
        // The socket this frame belongs to is decided when the send starts, not when it
        // completes: a frame held in flight while the session is dropped is gone with it.
        let connection = lock.withLock { _connects.count - 1 }
        if text.hasPrefix(#"{"realtimeInput":{"audio":"#), let hold = audioHold {
            await hold.hold()
        }
        if let sendFailure { throw sendFailure }
        let closed = lock.withLock { () -> Error? in
            guard connection >= 0 else {
                return WebSocketCloseError(code: 1_006, reason: "socket is not open")
            }
            if closedConnections.contains(connection) {
                return WebSocketCloseError(code: 1_000, reason: "closed by client")
            }
            return connection == _connects.count - 1 ? failure : nil
        }
        if let closed { throw closed }
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            _sent.append(text)
            _sentByConnection[connection].append(text)
            let hit = sendWaiters.filter { $0.needed <= _sent.count }
            sendWaiters.removeAll { $0.needed <= _sent.count }
            return hit.map(\.continuation)
        }
        ready.forEach { $0.resume() }
        if isSetup, let closeAfterSetup {
            serverClose(code: closeAfterSetup.code, reason: closeAfterSetup.reason)
            // Still inside `send`, so the receive loop gets the failure first.
            for _ in 0..<60 { await Task.yield() }
        }
        if isSetup, autoSetupComplete { enqueue(#"{"setupComplete": {}}"#) }
    }

    func receive() async throws -> String {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            _receiveCount += 1
            let hit = receiveWaiters.filter { $0.needed <= _receiveCount }
            receiveWaiters.removeAll { $0.needed <= _receiveCount }
            return hit.map(\.continuation)
        }
        ready.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            enum Next { case frame(String), error(Error), park }
            let next: Next = lock.withLock {
                if !inbox.isEmpty { return .frame(inbox.removeFirst()) }
                if let failure { return .error(failure) }
                receiver = continuation
                return .park
            }
            switch next {
            case .frame(let text): continuation.resume(returning: text)
            case .error(let error): continuation.resume(throwing: error)
            case .park: break
            }
        }
    }

    func ping() async throws {
        let dead = lock.withLock { () -> Error? in
            _pingCount += 1
            if let pingFailure { return pingFailure }
            guard !_connects.isEmpty, !closedConnections.contains(_connects.count - 1) else {
                return WebSocketCloseError(code: 1_006, reason: "socket is not open")
            }
            return failure
        }
        if let dead { throw dead }
    }

    func close() async {
        let parked: CheckedContinuation<String, Error>? = lock.withLock {
            _closeCount += 1
            if !_connects.isEmpty { closedConnections.insert(_connects.count - 1) }
            failure = failure ?? WebSocketCloseError(code: 1_000, reason: "closed by client")
            let waiter = receiver
            receiver = nil
            return waiter
        }
        parked?.resume(throwing: WebSocketCloseError(code: 1_000, reason: "closed by client"))
    }

    // MARK: Script

    func enqueue(_ text: String) {
        let parked: CheckedContinuation<String, Error>? = lock.withLock {
            guard let waiter = receiver else {
                inbox.append(text)
                return nil
            }
            receiver = nil
            return waiter
        }
        parked?.resume(returning: text)
    }

    /// The server drops the connection, e.g. close 1007 on a bad key.
    func serverClose(code: Int, reason: String) {
        let error = WebSocketCloseError(code: code, reason: reason)
        let parked: CheckedContinuation<String, Error>? = lock.withLock {
            failure = error
            let waiter = receiver
            receiver = nil
            return waiter
        }
        parked?.resume(throwing: error)
    }

    func waitForSends(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if _sent.count >= count { return true }
                sendWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    func waitForReceives(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if _receiveCount >= count { return true }
                receiveWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Scriptable stand-in for one HTTP round trip. The test decides the status and the body,
/// and reads back what the client actually posted.
final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var status = 200
    var body = Data(#"{"candidates":[{"content":{"parts":[{"text":"перегнали"}]}}]}"#.utf8)
    /// Set to make `send` throw, i.e. a request that never reached the server.
    var failure: Error?

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    /// The posted JSON body, decoded.
    func payload(of index: Int = 0) -> [String: Any] {
        guard let data = requests[index].httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    /// The prompt part of the posted body.
    func prompt(of index: Int = 0) -> String {
        let contents = payload(of: index)["contents"] as? [[String: Any]] ?? []
        let parts = contents.first?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.first ?? ""
    }

    /// Bytes of the inline audio the client attached.
    func audioBytes(of index: Int = 0) -> Int {
        let contents = payload(of: index)["contents"] as? [[String: Any]] ?? []
        let parts = contents.first?["parts"] as? [[String: Any]] ?? []
        let inline = parts.compactMap { $0["inline_data"] as? [String: Any] }.first ?? [:]
        return Data(base64Encoded: inline["data"] as? String ?? "")?.count ?? 0
    }

    func mimeType(of index: Int = 0) -> String {
        let contents = payload(of: index)["contents"] as? [[String: Any]] ?? []
        let parts = contents.first?["parts"] as? [[String: Any]] ?? []
        let inline = parts.compactMap { $0["inline_data"] as? [String: Any] }.first ?? [:]
        return inline["mime_type"] as? String ?? ""
    }
}

/// Parks every audio frame inside `send` until the test lets it through, one at a time.
/// `entries` is how many sends are in flight: a drain running in parallel with `flushTail`
/// shows up as a second one.
final class SendHold: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    private var waiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var entries: Int { lock.withLock { count } }

    func hold() async {
        await withCheckedContinuation { continuation in
            let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                parked.append(continuation)
                count += 1
                let hit = waiters.filter { $0.needed <= count }
                waiters.removeAll { $0.needed <= count }
                return hit.map(\.continuation)
            }
            ready.forEach { $0.resume() }
        }
    }

    func waitForEntries(_ needed: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if count >= needed { return true }
                waiters.append((needed, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Lets the oldest held frame through.
    func releaseNext() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            parked.isEmpty ? nil : parked.removeFirst()
        }
        continuation?.resume()
    }
}

/// Time only moves when the test says so. `advance` releases every sleeper whose deadline
/// has passed; `waitForSleeps` lets the test wait until the code under test is actually
/// parked on the clock, so advancing can never happen too early.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(id: Int, deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0
    private var registered = 0
    private var registerWaiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            registered += 1
            return nextID
        }
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            let hit = registerWaiters.filter { $0.needed <= registered }
            registerWaiters.removeAll { $0.needed <= registered }
            return hit.map(\.continuation)
        }
        ready.forEach { $0.resume() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Next { case fire, cancel, park }
                let next: Next = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }
                    if current >= deadline { return .fire }
                    sleepers.append((id, deadline, continuation))
                    return .park
                }
                switch next {
                case .fire: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            let parked: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return sleepers.remove(at: index).continuation
            }
            parked?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = current.advanced(by: duration)
            let hit = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return hit.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Is something parked on exactly this deadline, counted from now? Precise where
    /// `waitForSleeps` is not: several timers can be in flight at once (setup, final,
    /// keepalive) and only one of them is the one the test is about to fire.
    func hasSleep(after duration: Duration) -> Bool {
        lock.withLock {
            let deadline = current.advanced(by: duration)
            return sleepers.contains { $0.deadline == deadline }
        }
    }

    /// Waits until `count` sleeps have been started since the clock was created.
    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if registered >= count { return true }
                registerWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
}

// MARK: - Frames

enum Frame {
    static let setupComplete = #"{"setupComplete": {}}"#
    static let emptyContent = #"{"serverContent": {}}"#
    static let generationComplete = #"{"serverContent": {"generationComplete": true}}"#
    static func interim(_ text: String) -> String {
        #"{"serverContent": {"interimInputTranscription": {"text": "\#(text)"}}}"#
    }
    static func final(_ text: String) -> String {
        #"{"serverContent": {"inputTranscription": {"text": "\#(text)"}}}"#
    }
}

extension FakeWebSocket {
    /// Base64 payload sizes of every audio frame the client sent, in order.
    var audioPayloadSizes: [Int] {
        sent.compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let input = (object as? [String: Any])?["realtimeInput"] as? [String: Any],
                  let audio = input["audio"] as? [String: Any],
                  let data = audio["data"] as? String,
                  let decoded = Data(base64Encoded: data) else { return nil }
            return decoded.count
        }
    }

    var setupFrames: [String] { sent.filter { $0.hasPrefix(#"{"setup":"#) } }
    var activityStarts: Int { sent.filter { $0 == GeminiLiveProtocol.activityStartMessage }.count }
    var activityEnds: Int { sent.filter { $0 == GeminiLiveProtocol.activityEndMessage }.count }
}
