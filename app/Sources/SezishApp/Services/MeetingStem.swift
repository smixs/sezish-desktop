import Foundation
import SezishCore

/// Bridges a realtime audio callback to a disk spool: appends land in a pending
/// buffer under a lock, a serial utility queue drains them to the file — file
/// I/O never runs on the audio thread.
nonisolated final class MeetingStem: @unchecked Sendable {
    private let spool: PCMSpoolFile
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Float] = []

    init(spool: PCMSpoolFile, label: String) {
        self.spool = spool
        self.queue = DispatchQueue(label: "com.smixs.sezish.stem.\(label)", qos: .utility)
    }

    func ingest(_ samples16k: [Float]) {
        lock.withLock { pending.append(contentsOf: samples16k) }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drains the tail and finalizes the spool. Returns total frames written.
    func finish() throws -> Int {
        queue.sync { drain() }
        return try spool.finalize()
    }

    private func drain() {
        let chunk = lock.withLock {
            let taken = pending
            pending = []
            return taken
        }
        guard !chunk.isEmpty else { return }
        // A failed write drops this chunk; the stem keeps going — a partial
        // recording beats an aborted call.
        try? spool.append(chunk)
    }
}
