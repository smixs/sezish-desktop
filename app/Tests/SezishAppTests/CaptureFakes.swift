import AudioToolbox
import Foundation
import SezishCore

@testable import SezishApp

/// The stop watchdog, fired by hand: a test decides when "the timeout passed", so no
/// test ever waits on the wall clock.
final class ManualWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private var timeouts: [TimeInterval] = []

    var schedule: StopWatchdog {
        { [self] seconds, fire in
            lock.withLock {
                pending.append(fire)
                timeouts.append(seconds)
            }
        }
    }

    /// Every timeout ever scheduled, in order.
    var scheduledTimeouts: [TimeInterval] { lock.withLock { timeouts } }

    /// Spins (yielding, never sleeping) until `count` watchdogs were scheduled in total.
    func waitForScheduled(_ count: Int) async {
        while scheduledTimeouts.count < count { await Task.yield() }
    }

    /// The timeout passes for everything scheduled so far.
    func fireAll() {
        let fires = lock.withLock {
            let taken = pending
            pending = []
            return taken
        }
        fires.forEach { $0() }
    }
}

/// A gate a fake HAL call can be parked on: `enter` reports that the call is inside,
/// `release` lets it out. Unreleased, the call hangs exactly like a HAL mutex that
/// never comes back.
final class Hold: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func park() {
        entered.signal()
        released.wait()
    }

    func waitUntilParked() { entered.wait() }

    /// Lets every parked (and every future) call through.
    func release() {
        for _ in 0..<64 { released.signal() }
    }
}

/// Stands in for CoreAudio under `SystemAudioTap`: records which queue every
/// registration was handed, fires output-device changes the way the HAL does
/// (asynchronously, onto the listener's queue), and can park or fail any call.
final class FakeTapBackend: SystemTapBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _ioQueues: [DispatchQueue] = []
    private var _listenerQueue: DispatchQueue?
    private var _listener: AudioObjectPropertyListenerBlock?
    private var _aggregatesStarted = 0
    private var _aggregatesStopped = 0
    private var _tapsDestroyed = 0
    private var _listenerRemoved = false

    /// Set: the next `startAggregate` parks on this hold (a rebuild in flight).
    var holdNextStart: Hold? {
        get { lock.withLock { _holdNextStart } }
        set { lock.withLock { _holdNextStart = newValue } }
    }
    private var _holdNextStart: Hold?

    /// Set: every `stopAggregate` parks here (AudioDeviceStop stuck on the HAL mutex).
    var holdStops: Hold? {
        get { lock.withLock { _holdStops } }
        set { lock.withLock { _holdStops = newValue } }
    }
    private var _holdStops: Hold?

    /// Set: the next `startAggregate` throws (a rebuild CoreAudio refuses).
    var failNextStart: Bool {
        get { lock.withLock { _failNextStart } }
        set { lock.withLock { _failNextStart = newValue } }
    }
    private var _failNextStart = false

    var ioQueues: [DispatchQueue] { lock.withLock { _ioQueues } }
    var listenerQueue: DispatchQueue? { lock.withLock { _listenerQueue } }
    var aggregatesStarted: Int { lock.withLock { _aggregatesStarted } }
    var aggregatesStopped: Int { lock.withLock { _aggregatesStopped } }
    var tapsDestroyed: Int { lock.withLock { _tapsDestroyed } }
    var listenerRemoved: Bool { lock.withLock { _listenerRemoved } }

    struct Refused: Error {}

    func createTap(coverage: TapCoverage) throws -> TapHandle {
        let format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        return TapHandle(id: 7, uuid: UUID(), format: format)
    }

    func destroyTap(_ tap: TapHandle) {
        lock.withLock { _tapsDestroyed += 1 }
    }

    func startAggregate(
        for tap: TapHandle, ioQueue: DispatchQueue,
        onInput: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void
    ) throws -> AggregateHandle {
        let (hold, fail): (Hold?, Bool) = lock.withLock {
            _ioQueues.append(ioQueue)
            let hold = _holdNextStart
            _holdNextStart = nil
            let fail = _failNextStart
            _failNextStart = false
            return (hold, fail)
        }
        hold?.park()
        if fail { throw Refused() }
        return lock.withLock {
            _aggregatesStarted += 1
            return AggregateHandle(
                id: AudioObjectID(100 + _aggregatesStarted), ioProcID: nil,
                output: "output-\(_aggregatesStarted)")
        }
    }

    func stopAggregate(_ aggregate: AggregateHandle) {
        holdStops?.park()
        lock.withLock { _aggregatesStopped += 1 }
    }

    func addOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        lock.withLock {
            _listenerQueue = queue
            _listener = listener
        }
    }

    func removeOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        lock.withLock {
            _listenerRemoved = true
            _listener = nil
        }
    }

    /// `times` output-device changes, each dispatched onto the listener's queue the
    /// way CoreAudio delivers them: asynchronously, one block per change.
    func fireOutputChanges(_ times: Int) {
        let (queue, listener) = lock.withLock { (_listenerQueue, _listener) }
        guard let queue, let listener else { return }
        for _ in 0..<times {
            queue.async {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                listener(1, &address)
            }
        }
    }
}

/// A microphone for the meeting recorder: delivers nothing by itself, can refuse to
/// start, and its stop can hang on a hold the test controls.
final class FakeMeetingMic: MeetingMicCapture, @unchecked Sendable {
    private let refuses: Bool
    private let stopHold: Hold?
    private let lock = NSLock()
    private var _stops = 0

    init(refuses: Bool = false, stopHold: Hold? = nil) {
        self.refuses = refuses
        self.stopHold = stopHold
    }

    struct Refused: Error {}

    var stops: Int { lock.withLock { _stops } }

    func start() throws {
        if refuses { throw Refused() }
    }

    func stopSynchronously() {
        lock.withLock { _stops += 1 }
        stopHold?.park()
    }
}

/// A system-audio capture for the meeting recorder that keeps its sample callback, so
/// a test can play a late delivery after the stop, and answers its stop with a fixed
/// result (a real tap's timeout is `SystemAudioTap`'s business, tested there).
final class FakeSystemCapture: SystemCapture, @unchecked Sendable {
    let onSamples: @Sendable ([Float]) -> Void
    private let result: CaptureStopResult
    private let lock = NSLock()
    private var _stops = 0
    private var _lost: Bool

    init(
        result: CaptureStopResult = .stopped, lost: Bool = false,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        self.result = result
        self._lost = lost
        self.onSamples = onSamples
    }

    var stops: Int { lock.withLock { _stops } }

    var lostDuringRecording: Bool { lock.withLock { _lost } }

    func start(coverage: TapCoverage) throws {}

    func stop(timeout: TimeInterval) async -> CaptureStopResult {
        lock.withLock { _stops += 1 }
        return result
    }
}

/// Every system capture a recorder built, in order.
final class SystemCaptures: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [FakeSystemCapture] = []

    func add(_ capture: FakeSystemCapture) { lock.withLock { _all.append(capture) } }
    var all: [FakeSystemCapture] { lock.withLock { _all } }
}

/// A tone far above the speech threshold, `frames` long.
func loudTone(frames: Int) -> [Float] {
    (0..<frames).map { 0.5 * sinf(2 * .pi * 440 * Float($0) / 16_000) }
}
