import Foundation

public enum ModelDownloadError: Error, Equatable {
    case notHTTP
    case httpStatus(Int)
    case sizeMismatch(expected: Int, actual: Int)
}

/// Downloads model files over `URLSession`, streaming to a `.part` file and renaming it
/// atomically on success.
///
/// - Resume: if a `.part` file already exists it sends `Range: bytes=<size>-` and appends
///   the tail. If the server ignores the range (200 instead of 206) it restarts cleanly.
/// - Redirects (e.g. HuggingFace → cdn-lfs) are followed by `URLSession` automatically.
/// - On completion the on-disk size is checked against the expected size; a mismatch deletes
///   the `.part` file and throws. No retries — the caller re-invokes.
///
/// `@unchecked Sendable`: `configuration` is treated as immutable after init; each download
/// spins up its own `URLSession`, so there is no shared mutable state.
public final class ModelDownloader: @unchecked Sendable {
    /// `(bytesDownloaded, totalBytes)` — reported as the stream progresses, for UI.
    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    private let configuration: URLSessionConfiguration
    private let flushBytes = 256 * 1024

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    /// Fetches every missing file of `store` in order.
    public func downloadMissing(_ store: ModelStore, progress: ProgressHandler? = nil) async throws {
        for file in store.missingFiles {
            try await download(file, store: store, progress: progress)
        }
    }

    /// Fetches a single file into `store.localURL(for:)`.
    public func download(_ file: ModelFile, store: ModelStore, progress: ProgressHandler? = nil) async throws {
        try await download(
            file,
            from: store.remoteURL(for: file),
            to: store.localURL(for: file),
            progress: progress
        )
    }

    func download(_ file: ModelFile, from remoteURL: URL, to finalURL: URL, progress: ProgressHandler?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let partPath = finalURL.path + ".part"
        let partURL = URL(fileURLWithPath: partPath)
        let existing = fileSize(atPath: partPath) ?? 0

        var request = URLRequest(url: remoteURL)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let session = URLSession(configuration: configuration)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelDownloadError.notHTTP }

        let appending: Bool
        switch http.statusCode {
        case 206: appending = true          // server honored Range
        case 200: appending = false         // full body — ignore any partial
        default: throw ModelDownloadError.httpStatus(http.statusCode)
        }

        let handle = try openPart(at: partURL, path: partPath, appending: appending, fm: fm)
        defer { try? handle.close() }

        var written = appending ? existing : 0
        let total = file.size
        progress?(written, total)

        var buffer = Data()
        buffer.reserveCapacity(flushBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= flushBytes {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                progress?(written, total)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
            progress?(written, total)
        }

        let actual = fileSize(atPath: partPath) ?? written
        guard actual == total else {
            try? fm.removeItem(at: partURL)
            throw ModelDownloadError.sizeMismatch(expected: total, actual: actual)
        }

        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: partURL, to: finalURL)   // atomic rename on the same volume
    }

    private func openPart(at url: URL, path: String, appending: Bool, fm: FileManager) throws -> FileHandle {
        if appending {
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        }
        fm.createFile(atPath: path, contents: nil)   // truncates any stale partial
        return try FileHandle(forWritingTo: url)
    }

    private func fileSize(atPath path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }
}
