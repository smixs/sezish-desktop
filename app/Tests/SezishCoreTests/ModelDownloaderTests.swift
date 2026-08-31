import Foundation
import Testing
@testable import SezishCore

// MARK: - Test doubles

/// Thread-safe reference box for smuggling values out of the URLProtocol callback
/// (which runs on URLSession's queue) back into the test body.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var wrapped: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private struct MockResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Intercepts every request and answers with whatever the current handler returns.
/// The download suite is `.serialized`, so the single static handler is never shared
/// across concurrent tests.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> MockResponse)?
    private static let lock = NSLock()

    static func set(_ handler: (@Sendable (URLRequest) -> MockResponse)?) {
        lock.lock(); _handler = handler; lock.unlock()
    }
    private static func current() -> (@Sendable (URLRequest) -> MockResponse)? {
        lock.lock(); defer { lock.unlock() }; return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.current() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let mock = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: mock.status, httpVersion: "HTTP/1.1", headerFields: mock.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func mockConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return config
}

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sezish-dl-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Tests

@Suite(.serialized) struct ModelDownloaderTests {
    @Test func freshDownloadWritesFileWithCorrectSize() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir); MockURLProtocol.set(nil) }
        let payload = Data("hello world".utf8)          // 11 bytes
        let file = ModelFile(name: "weights.bin", size: payload.count)
        let store = ModelStore(root: dir, files: [file])

        MockURLProtocol.set { _ in MockResponse(status: 200, headers: [:], body: payload) }

        let downloader = ModelDownloader(configuration: mockConfiguration())
        try await downloader.download(file, store: store)

        let written = try Data(contentsOf: store.localURL(for: file))
        #expect(written == payload)
        #expect(store.isComplete)
        #expect(!FileManager.default.fileExists(atPath: store.localURL(for: file).path + ".part"))
    }

    @Test func resumeSendsRangeHeaderAndAppendsTail() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir); MockURLProtocol.set(nil) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let head = Data(repeating: 0xAB, count: 100)     // already-downloaded partial
        let tail = Data(repeating: 0xCD, count: 40)
        let full = head + tail
        let file = ModelFile(name: "weights.bin", size: full.count)
        let store = ModelStore(root: dir, files: [file])

        // Seed the .part file with the first 100 bytes.
        try head.write(to: URL(fileURLWithPath: store.localURL(for: file).path + ".part"))

        let seenRange = Box<String?>(nil)
        MockURLProtocol.set { request in
            seenRange.wrapped = request.value(forHTTPHeaderField: "Range")
            return MockResponse(status: 206, headers: [:], body: tail)
        }

        let downloader = ModelDownloader(configuration: mockConfiguration())
        try await downloader.download(file, store: store)

        #expect(seenRange.wrapped == "bytes=100-")
        let written = try Data(contentsOf: store.localURL(for: file))
        #expect(written == full)
        #expect(store.isComplete)
    }

    @Test func sizeMismatchThrowsAndDeletesPart() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir); MockURLProtocol.set(nil) }
        let file = ModelFile(name: "weights.bin", size: 20)   // expect 20…
        let store = ModelStore(root: dir, files: [file])
        let shortBody = Data(repeating: 0x01, count: 12)      // …but only 12 arrive

        MockURLProtocol.set { _ in MockResponse(status: 200, headers: [:], body: shortBody) }

        let downloader = ModelDownloader(configuration: mockConfiguration())
        await #expect(throws: ModelDownloadError.sizeMismatch(expected: 20, actual: 12)) {
            try await downloader.download(file, store: store)
        }
        #expect(!FileManager.default.fileExists(atPath: store.localURL(for: file).path + ".part"))
        #expect(!store.isComplete)
    }

    @Test func progressReportsMonotonicBytesUpToTotal() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir); MockURLProtocol.set(nil) }
        let payload = Data(repeating: 0x7, count: 500)
        let file = ModelFile(name: "weights.bin", size: payload.count)
        let store = ModelStore(root: dir, files: [file])

        MockURLProtocol.set { _ in MockResponse(status: 200, headers: [:], body: payload) }

        let samples = Box<[Int]>([])
        let downloader = ModelDownloader(configuration: mockConfiguration())
        try await downloader.download(file, store: store) { done, total in
            #expect(total == 500)
            samples.wrapped.append(done)
        }
        #expect(samples.wrapped.last == 500)
        #expect(samples.wrapped == samples.wrapped.sorted())   // non-decreasing
    }
}
