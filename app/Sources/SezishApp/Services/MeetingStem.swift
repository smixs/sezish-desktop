import Foundation
import SezishCore

/// Bridges a realtime audio callback to a disk spool: appends land in a pending
/// buffer under a lock, a serial utility queue drains them to the file, so file
/// I/O never runs on the audio thread.
///
/// Every touch of the spool happens on that queue, the finalize included:
/// `PCMSpoolFile` is not thread-safe. Once closed (by `close()` or `finish()`) the
/// stem refuses deliveries, because a capture abandoned on a stuck stop may still
/// fire its callback long after the take was written.
nonisolated final class MeetingStem: @unchecked Sendable {
    private let spool: PCMSpoolFile
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Float] = []
    private var closed = false

    init(spool: PCMSpoolFile, label: String) {
        self.spool = spool
        self.queue = DispatchQueue(label: "com.smixs.sezish.stem.\(label)", qos: .utility)
    }

    func ingest(_ samples16k: [Float]) {
        let accepted: Bool = lock.withLock {
            guard !closed else { return false }
            pending.append(contentsOf: samples16k)
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Nothing delivered from here on reaches the file.
    func close() {
        lock.withLock { closed = true }
    }

    /// Closes the stem, drains the tail and finalizes the spool, all on the stem's
    /// queue. Returns total frames written.
    func finish() throws -> Int {
        close()
        return try queue.sync {
            drain()
            return try spool.finalize()
        }
    }

    private func drain() {
        let chunk = lock.withLock {
            let taken = pending
            pending = []
            return taken
        }
        guard !chunk.isEmpty else { return }
        // A failed write drops this chunk; the stem keeps going: a partial
        // recording beats an aborted call.
        try? spool.append(chunk)
    }
}
