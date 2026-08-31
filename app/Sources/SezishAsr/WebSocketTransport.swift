import Foundation

/// The peer closed the socket. `code` and `reason` are the close frame as the server sent it
/// (Gemini answers a bad key with 1007 «API key not valid...» *after* the HTTP 101).
public struct WebSocketCloseError: Error, Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// Test seam over a text WebSocket. Everything above it is pure protocol work.
public protocol WebSocketTransport: Sendable {
    func connect(_ url: URL) async throws
    func send(_ text: String) async throws
    /// Next text frame. Throws when the peer closed the socket (carry close code + reason in the error).
    func receive() async throws -> String
    /// Round trip to the peer. Returns when the pong is back, throws when it never comes:
    /// the only way to tell a live socket from a dead TCP without sending real audio.
    func ping() async throws
    func close() async
}

/// `URLSessionWebSocketTask` behind the seam.
///
/// The session is its own, never `URLSession.shared`: closing a dictation session cancels
/// tasks, and that must not touch the ASR uploads running on the shared session.
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    /// The system default of 60 s, i.e. «the caller did not tune this».
    private static let untunedRequestTimeout: TimeInterval = 60
    /// `timeoutIntervalForRequest` is the idle timer of the task and every frame resets it, so
    /// this is how long a socket may stay silent before the send or receive parked on it gives
    /// up. Keepalive pings run well under it; the point is that a dead TCP surfaces in seconds
    /// instead of the minute the system default costs.
    private static let idleTimeout: TimeInterval = 15

    public init(configuration: URLSessionConfiguration = .default) {
        let tuned = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        if tuned.timeoutIntervalForRequest == Self.untunedRequestTimeout {
            tuned.timeoutIntervalForRequest = Self.idleTimeout
        }
        session = URLSession(configuration: tuned)
    }

    deinit { session.invalidateAndCancel() }

    private var current: URLSessionWebSocketTask? { lock.withLock { task } }

    /// Returns as soon as the task is resumed: the handshake runs in the background and its
    /// failures surface on the first `send`/`receive`, which is where we handle them anyway.
    public func connect(_ url: URL) async throws {
        let socket = session.webSocketTask(with: url)
        let previous: URLSessionWebSocketTask? = lock.withLock {
            let old = task
            task = socket
            return old
        }
        previous?.cancel(with: .goingAway, reason: nil)
        socket.resume()
    }

    public func send(_ text: String) async throws {
        guard let socket = current else {
            throw WebSocketCloseError(code: 1_006, reason: "socket is not open")
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw Self.closeError(socket, fallback: error)
        }
    }

    public func receive() async throws -> String {
        guard let socket = current else {
            throw WebSocketCloseError(code: 1_006, reason: "socket is not open")
        }
        do {
            switch try await socket.receive() {
            case .string(let text):
                return text
            case .data(let data):
                return String(decoding: data, as: UTF8.self)
            @unknown default:
                throw WebSocketCloseError(code: 1_003, reason: "unsupported frame")
            }
        } catch {
            throw Self.closeError(socket, fallback: error)
        }
    }

    public func ping() async throws {
        guard let socket = current else {
            throw WebSocketCloseError(code: 1_006, reason: "socket is not open")
        }
        let gate = PingGate()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.attach(continuation)
                    socket.sendPing { error in
                        gate.settle(error.map { .failure($0) } ?? .success(()))
                    }
                }
            } onCancel: {
                gate.settle(.failure(CancellationError()))
            }
        } catch {
            throw Self.closeError(socket, fallback: error)
        }
    }

    public func close() async {
        let socket: URLSessionWebSocketTask? = lock.withLock {
            let old = task
            task = nil
            return old
        }
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// The close frame is not in the thrown error: `receive` fails with a transport error and
    /// the code/reason land on the task itself. `.invalid` means the socket is still open.
    private static func closeError(_ socket: URLSessionWebSocketTask, fallback: Error) -> Error {
        guard socket.closeCode != .invalid else { return fallback }
        let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return WebSocketCloseError(code: socket.closeCode.rawValue, reason: reason)
    }
}

/// `sendPing`'s handler is not a well-behaved continuation: it fires twice when the TCP
/// connection is aborted underneath it, and not at all when the task is cancelled mid flight.
/// The gate turns both into exactly one resume — the first outcome wins, later ones are dropped.
private final class PingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var early: Result<Void, Error>?

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        let result: Result<Void, Error>? = lock.withLock {
            guard let early else {
                self.continuation = continuation
                return nil
            }
            settled = true
            return early
        }
        if let result { continuation.resume(with: result) }
    }

    func settle(_ result: Result<Void, Error>) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !settled else { return nil }
            guard let waiter = continuation else {
                early = early ?? result
                return nil
            }
            settled = true
            continuation = nil
            return waiter
        }
        waiter?.resume(with: result)
    }
}
