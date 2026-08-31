import Foundation

/// One step of an interactive login, in the shape the UI needs it.
///
/// `nonisolated` for the same reason as `EngineStatus`: the app target defaults to
/// MainActor isolation, and these values are produced on the pipe-reader threads.
nonisolated enum LoginEvent: Sendable {
    /// Open this in the SYSTEM browser. Never in an embedded WebKit view: Anthropic's
    /// OAuth flow refuses one (bux#79), and the user's existing browser session is
    /// half the point of a subscription login.
    case authURL(URL)
    /// Device-code fallback: show both, the user types the code into the page.
    case deviceCode(url: String, code: String)
    /// A progress line for the UI log.
    case info(String)
    case finished(success: Bool, message: String)
}

// MARK: - Shared process plumbing

/// Foundation's process plumbing predates `Sendable`, and every call made through
/// this box — `isRunning`, `terminate`, `processIdentifier`, a read on one pipe end
/// owned by exactly one queue — is safe off the main thread. Same idea as the box
/// inside `ProcessRunner`, which is private to that file.
private nonisolated final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// SIGTERM → grace → SIGKILL, the escalation `ProcessRunner` performs for batch runs.
/// Repeated here because these sessions cannot use `ProcessRunner` at all: it closes
/// stdin at launch and only reports after the child is gone, and an interactive login
/// needs the opposite of both.
private nonisolated func terminateChild(_ process: Process, grace: TimeInterval = 2) {
    guard process.isRunning else { return }
    process.terminate()
    let box = UncheckedBox(process)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
        if box.value.isRunning { kill(box.value.processIdentifier, SIGKILL) }
    }
}

private nonisolated func loginTail(_ text: String, limit: Int = 300) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? "…\(trimmed.suffix(limit))" : trimmed
}

// MARK: - Claude

/// Drives `claude auth login --claudeai` and reports what it prints.
///
/// Plain pipes, no PTY. That is the whole trick: over pipes the CLI gives up on
/// drawing a terminal UI and prints the OAuth URL in clear text within about a second
/// (anthropics/claude-code#81545), which is exactly the string we need to hand to the
/// system browser. Three more rules come from products that shipped this flow:
///
/// - the child's stdin STAYS OPEN until it exits. Closing it after launch — which is
///   what `ProcessRunner` does, and why this class exists instead — kills the flow
///   before the OAuth callback lands (stablyai/orca#7446). It is also the channel the
///   browser-fallback code goes back through: the official docs say `claude auth
///   login` reads the pasted code from standard input.
/// - output is ANSI-stripped before anything is matched (aperant#907), because the
///   URL arrives wrapped in colour and hyperlink escapes.
/// - only claude.ai / claude.com URLs count. The banner also prints docs and issue
///   links, and opening one of those instead of the OAuth page is the failure users
///   report (bux#79).
///
/// The output format has no stability contract, so nothing here parses it: it scans
/// for a URL, forwards every other line to the log, and never treats "unexpected
/// output" as an error.
nonisolated final class ClaudeLoginSession: @unchecked Sendable {
    private let binary: URL
    private let timeout: TimeInterval

    /// Every mutation and every emitted event happens here. stdout and stderr get
    /// their own reader queues from Foundation and the termination callback a third
    /// thread; funnelling all three through one serial queue is what makes "URL
    /// first, finished last" a guarantee rather than a hope.
    private let queue = DispatchQueue(label: "sh.sezi.claude-login")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutReader: UncheckedBox<FileHandle>?
    private var stderrReader: UncheckedBox<FileHandle>?
    private var onEvent: (@Sendable (LoginEvent) -> Void)?
    private var lineBuffer = ""
    private var stderrTail = ""
    private var didEmitURL = false
    private var didFinish = false
    private var didTerminate = false
    private var openReaders = 0
    private var endReason: String?
    private var timeoutTask: Task<Void, Never>?

    /// - Parameter timeout: how long the user gets to finish in the browser. Five
    ///   minutes is generous on purpose — a login that dies mid-flow leaves the CLI
    ///   in a state only the CLI can explain.
    init(binary: URL, timeout: TimeInterval = 300) {
        self.binary = binary
        self.timeout = timeout
    }

    // MARK: Pure helpers

    /// CSI (`ESC [ … final`) and OSC (`ESC ] … BEL | ST`) — the two families a CLI
    /// uses for colour, cursor moves and clickable hyperlinks.
    private static let csiPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
    private static let oscPattern = "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"

    /// Escapes out, text in. Everything downstream matches on the result, because a
    /// URL wrapped in an OSC 8 hyperlink is not a URL to any regex.
    static func stripANSI(_ text: String) -> String {
        // Built per call: `Regex` is not `Sendable`, and a login prints a handful of
        // lines — the build cost is nothing next to the process it describes.
        guard let osc = try? Regex(oscPattern), let csi = try? Regex(csiPattern) else {
            return text
        }
        return text.replacing(osc, with: "").replacing(csi, with: "")
    }

    /// Only the two hosts that can carry an Anthropic OAuth page. A banner's docs and
    /// GitHub links must never win this race.
    private static let authURLPattern = #"https://(?:www\.)?(?:claude\.ai|claude\.com)/\S+"#

    static func firstAuthURL(in strippedText: String) -> URL? {
        guard let regex = try? Regex(authURLPattern),
            let match = strippedText.firstMatch(of: regex)
        else { return nil }
        return URL(string: String(strippedText[match.range]))
    }

    // MARK: Lifecycle

    /// Events arrive on this class's private queue, in order, until `.finished`.
    func start(onEvent: @escaping @Sendable (LoginEvent) -> Void) {
        queue.async { self.startOnQueue(onEvent) }
    }

    private func startOnQueue(_ onEvent: @escaping @Sendable (LoginEvent) -> Void) {
        guard process == nil, !didFinish else { return }
        self.onEvent = onEvent

        let child = Process()
        child.executableURL = binary
        child.arguments = ["auth", "login", "--claudeai"]

        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        child.standardOutput = out
        child.standardError = err
        child.standardInput = input

        // The write end is retained for the whole session — this IS keeping stdin
        // open (orca#7446), not an accident of ownership.
        stdin = input.fileHandleForWriting
        let outBox = UncheckedBox(out.fileHandleForReading)
        let errBox = UncheckedBox(err.fileHandleForReading)
        stdoutReader = outBox
        stderrReader = errBox
        openReaders = 2

        outBox.value.readabilityHandler = { [self] _ in
            read(from: outBox, isStderr: false)
        }
        errBox.value.readabilityHandler = { [self] _ in
            read(from: errBox, isStderr: true)
        }
        // Armed before the launch: a child can be dead before `run()` returns, and a
        // handler installed afterwards would never fire.
        child.terminationHandler = { [self] _ in
            queue.async { self.childTerminated() }
        }
        process = child

        do {
            try child.run()
        } catch {
            process = nil
            finish(success: false, message: "cannot launch \(binary.path): \(error.localizedDescription)")
            return
        }

        emit(.info("waiting for the sign-in url…"))
        armTimeout()
    }

    /// The code the browser fallback shows, handed back to the CLI's stdin — the
    /// documented way `claude auth login` accepts it.
    func submitCode(_ code: String) {
        queue.async {
            guard let stdin = self.stdin, !self.didFinish else { return }
            let line = code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try? stdin.write(contentsOf: Data(line.utf8))
            self.emit(.info("code submitted"))
        }
    }

    /// Ends the flow: closes stdin, then SIGTERM → 2s → SIGKILL, so "cancelled"
    /// always means the child is actually gone.
    func cancel() {
        queue.async { self.cancelOnQueue(reason: "cancelled") }
    }

    private func cancelOnQueue(reason: String) {
        guard !didFinish else { return }
        if endReason == nil { endReason = reason }

        try? stdin?.close()
        stdin = nil

        guard let process, process.isRunning else {
            finish(success: false, message: endReason ?? reason)
            return
        }
        // The termination handler turns this into the final event.
        terminateChild(process)
    }

    private func armTimeout() {
        timeoutTask = Task { [self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            queue.async {
                self.cancelOnQueue(reason: "timeout after \(Int(self.timeout))s")
            }
        }
    }

    // MARK: Output

    private func read(from box: UncheckedBox<FileHandle>, isStderr: Bool) {
        let chunk = box.value.availableData
        guard !chunk.isEmpty else {
            // EOF. The handler must go, or Foundation spins on it forever.
            box.value.readabilityHandler = nil
            queue.async { self.readerFinished() }
            return
        }
        queue.async { self.ingest(chunk, isStderr: isStderr) }
    }

    private func ingest(_ chunk: Data, isStderr: Bool) {
        guard !didFinish else { return }
        let text = Self.stripANSI(String(decoding: chunk, as: UTF8.self))
        if isStderr { stderrTail = String((stderrTail + text).suffix(2000)) }

        lineBuffer += text
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newline])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handle(line: line)
        }
    }

    /// Only complete lines are scanned. A URL split across two pipe chunks would
    /// otherwise match as a truncated prefix and burn the one `.authURL` we emit.
    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !didEmitURL, let url = Self.firstAuthURL(in: trimmed) {
            didEmitURL = true
            emit(.authURL(url))
            return
        }
        emit(.info(trimmed))
    }

    private func readerFinished() {
        openReaders -= 1
        finishIfChildIsDone()
    }

    private func childTerminated() {
        didTerminate = true
        finishIfChildIsDone()
        // Safety net: a grandchild inheriting our pipes would hold the readers open
        // past the child's death, and the user would sit on a spinner that is over.
        queue.asyncAfter(deadline: .now() + 1) {
            guard !self.didFinish, self.didTerminate else { return }
            self.finishFromExit()
        }
    }

    private func finishIfChildIsDone() {
        guard didTerminate, openReaders <= 0, !didFinish else { return }
        finishFromExit()
    }

    private func finishFromExit() {
        // Whatever never got its newline is still worth logging.
        let pending = lineBuffer
        lineBuffer = ""
        handle(line: pending)

        let status = process?.terminationStatus ?? -1
        if let endReason {
            finish(success: false, message: endReason)
        } else if status == 0 {
            finish(success: true, message: "signed in")
        } else {
            finish(success: false, message: "claude exited \(status): \(loginTail(stderrTail))")
        }
    }

    private func finish(success: Bool, message: String) {
        guard !didFinish else { return }
        didFinish = true

        timeoutTask?.cancel()
        timeoutTask = nil
        stdoutReader?.value.readabilityHandler = nil
        stderrReader?.value.readabilityHandler = nil
        try? stdin?.close()
        stdin = nil
        if let process, process.isRunning { terminateChild(process) }

        emit(.finished(success: success, message: message))
        // Releases the caller's closure — and with it whatever the UI captured.
        onEvent = nil
        stdoutReader = nil
        stderrReader = nil
    }

    private func emit(_ event: LoginEvent) {
        onEvent?(event)
    }
}

// MARK: - Codex

/// Incremental decoder for a JSON-RPC stream over a pipe.
///
/// `codex app-server` speaks JSON-RPC 2.0 over stdio, but the framing is not
/// something we can pin from the outside: newline-delimited objects are the common
/// shape and LSP-style `Content-Length` headers the other. Both are decoded here and
/// detected per message, so the app works either way — a live run against the real
/// binary will confirm which branch it actually takes, and nothing has to change when
/// it does.
///
/// Tolerant by design: a line that is not JSON is skipped, not fatal. Anything the
/// server logs to stdout must not take the login down with it.
nonisolated final class JsonRpcFraming {
    /// `[UInt8]`, not `Data`: array indices re-base after `removeFirst`, and a `Data`
    /// slice's do not — which is exactly the bug an incremental decoder cannot afford.
    private var buffer: [UInt8] = []

    private static let header = Array("content-length:".utf8)

    private enum HeaderPrefix {
        case absent
        /// Matches so far but is too short to decide — wait for more bytes.
        case partial
        case full
    }

    /// Feeds one raw chunk and returns every message it completed.
    func append(_ chunk: Data) -> [[String: Any]] {
        buffer.append(contentsOf: chunk)

        var messages: [[String: Any]] = []
        loop: while true {
            dropLeadingWhitespace()
            if buffer.isEmpty { break }

            switch headerPrefix() {
            case .partial:
                break loop
            case .full:
                guard let (body, consumed) = contentLengthMessage() else { break loop }
                buffer.removeFirst(consumed)
                if let message = Self.decode(body) { messages.append(message) }
            case .absent:
                guard let newline = buffer.firstIndex(of: 0x0A) else { break loop }
                let line = Array(buffer[0..<newline])
                buffer.removeFirst(newline + 1)
                if let message = Self.decode(line) { messages.append(message) }
            }
        }
        return messages
    }

    private func dropLeadingWhitespace() {
        var drop = 0
        while drop < buffer.count, buffer[drop] == 0x20 || buffer[drop] == 0x09
            || buffer[drop] == 0x0A || buffer[drop] == 0x0D
        {
            drop += 1
        }
        if drop > 0 { buffer.removeFirst(drop) }
    }

    private func headerPrefix() -> HeaderPrefix {
        let common = min(buffer.count, Self.header.count)
        for index in 0..<common where Self.asciiLower(buffer[index]) != Self.header[index] {
            return .absent
        }
        return buffer.count >= Self.header.count ? .full : .partial
    }

    /// - Returns: the body bytes and how much of the buffer the whole message ate, or
    ///   `nil` while the message is still incomplete.
    private func contentLengthMessage() -> ([UInt8], Int)? {
        guard let separator = headerSeparator() else { return nil }
        let bodyStart = separator.index + separator.length

        let headerText = String(decoding: buffer[0..<separator.index], as: UTF8.self)
        guard let length = Self.contentLength(in: headerText) else {
            // A header block we cannot read: drop it and keep decoding what follows.
            return ([], bodyStart)
        }
        guard buffer.count >= bodyStart + length else { return nil }
        return (Array(buffer[bodyStart..<(bodyStart + length)]), bodyStart + length)
    }

    /// `\n\n` as well as `\r\n\r\n`: the spec says CRLF, and a writer that forgets is
    /// not a reason to stall the stream.
    private func headerSeparator() -> (index: Int, length: Int)? {
        var best: (index: Int, length: Int)?
        for pattern in ["\r\n\r\n", "\n\n"] {
            let bytes = Array(pattern.utf8)
            guard let index = Self.firstIndex(of: bytes, in: buffer) else { continue }
            if best == nil || index < best!.index { best = (index, bytes.count) }
        }
        return best
    }

    private static func contentLength(in headerText: String) -> Int? {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) {
            var matched = true
            for offset in 0..<pattern.count where bytes[start + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    private static func decode(_ bytes: [UInt8]) -> [String: Any]? {
        guard !bytes.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
            let message = object as? [String: Any]
        else { return nil }
        return message
    }
}

/// Drives a ChatGPT-subscription login through `codex app-server`.
///
/// This is the official integration surface: `app-server` is JSON-RPC 2.0 over stdio,
/// which means the login is a conversation with defined messages instead of screen
/// scraping. The flow is `account/read` (already signed in?) → `account/login/start`
/// → open the returned `authUrl` in the system browser → wait for the
/// `account/login/completed` notification. `chatgptDeviceCode` is the same call with
/// a different `type`, answering with a verification URL and a code to type.
///
/// Tolerant everywhere else: messages we did not ask for are ignored, because a
/// server free to add notifications must not be able to break a login by doing so.
nonisolated final class CodexLoginSession: @unchecked Sendable {
    /// Requests go out newline-delimited, matching the framing we expect back. If a
    /// live `codex app-server` turns out to want LSP-style headers on its input, this
    /// is the one switch to flip — reading already handles both.
    var useContentLengthFraming = false

    private let binary: URL
    private let codexHome: URL?
    private let timeout: TimeInterval

    /// Serialises the reader queues and the termination callback, exactly as in
    /// `ClaudeLoginSession`.
    private let queue = DispatchQueue(label: "sh.sezi.codex-login")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutReader: UncheckedBox<FileHandle>?
    private var stderrReader: UncheckedBox<FileHandle>?
    private var onEvent: (@Sendable (LoginEvent) -> Void)?
    private let framing = JsonRpcFraming()
    private var stderrTail = ""
    private var preferDeviceCode = false
    private var nextID = 0
    private var accountReadID = 0
    private var loginStartID = 0
    private var didFinish = false
    private var didTerminate = false
    private var openReaders = 0
    private var endReason: String?
    private var timeoutTask: Task<Void, Never>?

    /// - Parameter codexHome: `CODEX_HOME` for our own private install; ignored for a
    ///   codex the user installed themselves, which keeps its own `~/.codex`. Suffix
    ///   rule duplicated from `EngineLocator` (it is private there) — same copy the
    ///   `SummaryRunner` carries, change all of them together.
    init(binary: URL, codexHome: URL?, timeout: TimeInterval = 300) {
        self.binary = binary
        self.codexHome = codexHome
        self.timeout = timeout
    }

    private static let privateInstallTail = ["sezish", "bin", "codex"]

    private static func isPrivateInstall(_ binary: URL) -> Bool {
        binary.standardizedFileURL.pathComponents.suffix(3).elementsEqual(privateInstallTail)
    }

    // MARK: Lifecycle

    func start(
        preferDeviceCode: Bool = false, onEvent: @escaping @Sendable (LoginEvent) -> Void
    ) {
        queue.async { self.startOnQueue(preferDeviceCode: preferDeviceCode, onEvent: onEvent) }
    }

    private func startOnQueue(
        preferDeviceCode: Bool, onEvent: @escaping @Sendable (LoginEvent) -> Void
    ) {
        guard process == nil, !didFinish else { return }
        self.preferDeviceCode = preferDeviceCode
        self.onEvent = onEvent

        let child = Process()
        child.executableURL = binary
        child.arguments = ["app-server"]
        if let codexHome, Self.isPrivateInstall(binary) {
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = codexHome.path
            child.environment = env
        }

        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        child.standardOutput = out
        child.standardError = err
        child.standardInput = input

        // Stdin is the request channel, so it stays open for the whole session.
        stdin = input.fileHandleForWriting
        let outBox = UncheckedBox(out.fileHandleForReading)
        let errBox = UncheckedBox(err.fileHandleForReading)
        stdoutReader = outBox
        stderrReader = errBox
        openReaders = 2

        outBox.value.readabilityHandler = { [self] _ in
            read(from: outBox, isStderr: false)
        }
        errBox.value.readabilityHandler = { [self] _ in
            read(from: errBox, isStderr: true)
        }
        child.terminationHandler = { [self] _ in
            queue.async { self.childTerminated() }
        }
        process = child

        do {
            try child.run()
        } catch {
            process = nil
            finish(success: false, message: "cannot launch \(binary.path): \(error.localizedDescription)")
            return
        }

        emit(.info("asking codex about the account…"))
        // `refreshToken: false` — this is a question, not a reason to spend a network
        // round trip refreshing a session the user may be about to replace anyway.
        accountReadID = sendRequest(method: "account/read", params: ["refreshToken": false])
        armTimeout()
    }

    func cancel() {
        queue.async { self.cancelOnQueue(reason: "cancelled") }
    }

    private func cancelOnQueue(reason: String) {
        guard !didFinish else { return }
        if endReason == nil { endReason = reason }

        try? stdin?.close()
        stdin = nil

        guard let process, process.isRunning else {
            finish(success: false, message: endReason ?? reason)
            return
        }
        terminateChild(process)
    }

    private func armTimeout() {
        timeoutTask = Task { [self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            queue.async {
                self.cancelOnQueue(reason: "timeout after \(Int(self.timeout))s")
            }
        }
    }

    // MARK: Requests

    @discardableResult
    private func sendRequest(method: String, params: [String: Any]) -> Int {
        nextID += 1
        let id = nextID
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    private func send(_ message: [String: Any]) {
        guard let stdin,
            // `.withoutEscapingSlashes` for the method names: `account\/read` is legal
            // JSON, but every other client on this protocol writes `account/read`, and
            // a wire format that reads like the docs is one less thing to doubt when
            // the server answers nothing.
            let body = try? JSONSerialization.data(
                withJSONObject: message, options: [.withoutEscapingSlashes]
            )
        else { return }

        var payload = Data()
        if useContentLengthFraming {
            payload.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
            payload.append(body)
        } else {
            payload.append(body)
            payload.append(0x0A)
        }
        try? stdin.write(contentsOf: payload)
    }

    // MARK: Messages

    private func read(from box: UncheckedBox<FileHandle>, isStderr: Bool) {
        let chunk = box.value.availableData
        guard !chunk.isEmpty else {
            box.value.readabilityHandler = nil
            queue.async { self.readerFinished() }
            return
        }
        queue.async { self.ingest(chunk, isStderr: isStderr) }
    }

    private func ingest(_ chunk: Data, isStderr: Bool) {
        guard !didFinish else { return }

        // stderr is the server's log, never its protocol — it goes to the UI log only.
        guard !isStderr else {
            let text = String(decoding: chunk, as: UTF8.self)
            stderrTail = String((stderrTail + text).suffix(2000))
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { emit(.info(trimmed)) }
            }
            return
        }

        for message in framing.append(chunk) {
            handle(message)
            if didFinish { return }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            // A notification or a server→client request. Exactly one of them matters;
            // everything else is the server being chatty, which is its right.
            guard method == "account/login/completed" else { return }
            let params = message["params"] as? [String: Any] ?? [:]
            if params["success"] as? Bool == true {
                finish(success: true, message: "signed in")
            } else {
                let reason = params["error"] as? String ?? "sign-in was not completed"
                finish(success: false, message: reason)
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        if id == accountReadID {
            handleAccountRead(message)
        } else if id == loginStartID {
            handleLoginStart(message)
        }
    }

    private func handleAccountRead(_ message: [String: Any]) {
        let account = (message["result"] as? [String: Any])?["account"]
        if let account, !(account is NSNull) {
            // Nothing to do: this codex home already holds a session.
            finish(success: true, message: "already logged in")
            return
        }
        // An error here says the server could not answer, not that the user is signed
        // in — either way the next step is the same login attempt.
        let type = preferDeviceCode ? "chatgptDeviceCode" : "chatgpt"
        emit(.info("requesting a sign-in url…"))
        loginStartID = sendRequest(method: "account/login/start", params: ["type": type])
    }

    private func handleLoginStart(_ message: [String: Any]) {
        guard let result = message["result"] as? [String: Any] else {
            let reason = (message["error"] as? [String: Any])?["message"] as? String
            finish(success: false, message: reason ?? "codex refused to start a login")
            return
        }

        // Device-code fields first: they only appear when that is what we asked for.
        if let verification = result["verificationUrl"] as? String,
            let code = result["userCode"] as? String
        {
            emit(.deviceCode(url: verification, code: code))
            return
        }
        if let authUrl = result["authUrl"] as? String, let url = URL(string: authUrl) {
            emit(.authURL(url))
            return
        }
        finish(success: false, message: "codex returned no sign-in url")
    }

    // MARK: Termination

    private func readerFinished() {
        openReaders -= 1
        finishIfChildIsDone()
    }

    private func childTerminated() {
        didTerminate = true
        finishIfChildIsDone()
        queue.asyncAfter(deadline: .now() + 1) {
            guard !self.didFinish, self.didTerminate else { return }
            self.finishFromExit()
        }
    }

    private func finishIfChildIsDone() {
        guard didTerminate, openReaders <= 0, !didFinish else { return }
        finishFromExit()
    }

    /// Reached only when the server died without telling us how the login went — the
    /// completed notification finishes the session first in every normal run.
    private func finishFromExit() {
        let status = process?.terminationStatus ?? -1
        if let endReason {
            finish(success: false, message: endReason)
        } else {
            finish(
                success: false,
                message: "codex app-server exited \(status): \(loginTail(stderrTail))"
            )
        }
    }

    private func finish(success: Bool, message: String) {
        guard !didFinish else { return }
        didFinish = true

        timeoutTask?.cancel()
        timeoutTask = nil
        stdoutReader?.value.readabilityHandler = nil
        stderrReader?.value.readabilityHandler = nil
        try? stdin?.close()
        stdin = nil
        // The already-logged-in path finishes while the server is still running, so
        // the kill belongs here rather than on the cancel path alone.
        if let process, process.isRunning { terminateChild(process) }

        emit(.finished(success: success, message: message))
        onEvent = nil
        stdoutReader = nil
        stderrReader = nil
    }

    private func emit(_ event: LoginEvent) {
        onEvent?(event)
    }
}
