import Foundation

/// Test seam over one HTTP round trip, the unary twin of `WebSocketTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable {
    case notHTTP
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    /// `.shared` on purpose: the ASR uploads already live there, and unlike the dictation
    /// socket nothing here is ever cancelled wholesale.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        return (data, http)
    }
}
