import Foundation

/// How a capture's stop ended: its work returned, or the watchdog gave up on it.
nonisolated enum CaptureStopResult: Sendable, Equatable {
    case stopped
    /// The stop never came back within its timeout (incident 06.10.2026: the HAL
    /// mutex was never released). The work stays queued and runs if the queue ever
    /// wakes up; the caller moves on without it.
    case abandoned
}

/// Schedules the stop watchdog: after `seconds`, call `fire`. Injected so tests fire
/// it by hand and never wait on the wall clock.
typealias StopWatchdog = @Sendable (_ seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> Void

/// A synchronous stop that may never return, run so its caller always does. The body
/// runs on a dispatch queue (never in the cooperative pool, where a stuck body would
/// pin a pool thread forever), the watchdog races it from another queue, and a
/// one-shot continuation takes whichever finishes first.
nonisolated enum GuardedStop {
    /// The real clock: a global queue fires the watchdog after `seconds`.
    static let realWatchdog: StopWatchdog = { seconds, fire in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: fire)
    }

    /// `onAbandon` runs only when the watchdog wins, before the caller resumes, so
    /// whatever it marks is already visible to the caller.
    static func run(
        on queue: DispatchQueue,
        timeout: TimeInterval,
        watchdog: StopWatchdog,
        onAbandon: @escaping @Sendable () -> Void = {},
        body: @escaping @Sendable () -> Void
    ) async -> CaptureStopResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CaptureStopResult, Never>) in
            let once = OneShot(continuation)
            queue.async {
                body()
                once.resume(.stopped)
            }
            watchdog(timeout) {
                once.resume(.abandoned, onWin: onAbandon)
            }
        }
    }
}

/// A continuation that resumes exactly once, whoever gets there first.
private nonisolated final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureStopResult, Never>?

    init(_ continuation: CheckedContinuation<CaptureStopResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: CaptureStopResult, onWin: () -> Void = {}) {
        let won: CheckedContinuation<CaptureStopResult, Never>? = lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
        guard let won else { return }
        onWin()
        won.resume(returning: result)
    }
}
