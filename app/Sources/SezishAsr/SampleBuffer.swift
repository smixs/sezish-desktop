import Foundation

/// Samples arrive from the realtime audio thread and leave on an actor: the lock is the
/// whole point, `feed` must never await.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ new: [Float]) { lock.withLock { samples.append(contentsOf: new) } }

    func take(_ count: Int) -> [Float]? {
        lock.withLock { () -> [Float]? in
            guard samples.count >= count else { return nil }
            let chunk = Array(samples.prefix(count))
            samples.removeFirst(count)
            return chunk
        }
    }

    func takeAll() -> [Float] {
        lock.withLock { () -> [Float] in
            let all = samples
            samples.removeAll(keepingCapacity: true)
            return all
        }
    }

    func reset() { lock.withLock { samples.removeAll(keepingCapacity: true) } }
}
