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

/// The restart scheduler, fired by hand: a test decides when "the settle window
/// passed". Each fired job runs synchronously on the queue it was handed, so the
/// recorder's control queue keeps its order exactly as it would with `asyncAfter`.
final class ManualMicScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(DispatchQueue, @Sendable () -> Void)] = []
    private var _delays: [TimeInterval] = []

    var schedule: MicRestartScheduler {
        { [self] delay, queue, work in
            lock.withLock {
                pending.append((queue, work))
                _delays.append(delay)
            }
        }
    }

    /// Every delay ever scheduled, in order.
    var delays: [TimeInterval] { lock.withLock { _delays } }
    var pendingCount: Int { lock.withLock { pending.count } }

    /// The delay passes for everything scheduled so far. Jobs these jobs schedule
    /// stay pending for the next call.
    func fireAll() {
        let jobs = lock.withLock {
            let taken = pending
            pending = []
            return taken
        }
        for (queue, work) in jobs { queue.sync(execute: work) }
    }
}

/// A wall clock a test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 0)

    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Stands in for one `AVAudioEngine`: records every call in order, keeps the
/// configuration-change observer and the tap's delivery so a test can play both, and
/// can be stopped "by the system" the way a device change stops the real one.
final class FakeMicEngine: MicEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _running = false
    private var _retired = false
    private var handler: (@Sendable () -> Void)?
    private var deliver: (@Sendable ([Float]) -> Void)?
    private let pinHold: Hold?
    private let failsToStart: Bool
    private let sampleRate: Double

    init(pinHold: Hold? = nil, failsToStart: Bool = false, sampleRate: Double = 48_000) {
        self.pinHold = pinHold
        self.failsToStart = failsToStart
        self.sampleRate = sampleRate
    }

    struct Refused: Error {}

    var calls: [String] { lock.withLock { _calls } }
    var retired: Bool { lock.withLock { _retired } }
    var observed: Bool { lock.withLock { handler != nil } }
    var starts: Int { calls.filter { $0 == "start" }.count }
    var pins: [String] { calls.filter { $0.hasPrefix("pin") } }

    var isRunning: Bool { lock.withLock { _running } }

    func pinInput(to deviceID: AudioDeviceID) throws {
        lock.withLock { _calls.append("pin \(deviceID)") }
        pinHold?.park()
    }

    func installTap(_ deliver: @escaping @Sendable ([Float]) -> Void) throws -> Double {
        lock.withLock {
            _calls.append("tap")
            self.deliver = deliver
        }
        return sampleRate
    }

    func start() throws {
        lock.withLock { _calls.append("start") }
        if failsToStart { throw Refused() }
        lock.withLock { _running = true }
    }

    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            _calls.append("observe")
            self.handler = handler
        }
    }

    func retire() {
        lock.withLock {
            _calls.append("retire")
            _retired = true
            _running = false
            handler = nil
            deliver = nil
        }
    }

    /// What `AVAudioEngineConfigurationChange` does to a real engine: it is already
    /// stopped when the notification arrives.
    func stopBySystem() {
        lock.withLock { _running = false }
    }

    /// One `AVAudioEngineConfigurationChange`, delivered on the caller's thread the
    /// way NotificationCenter does on the engine's internal thread.
    func fireConfigurationChange() {
        let handler = lock.withLock { self.handler }
        handler?()
    }

    /// A buffer the engine's tap hands over while it is installed.
    func play(_ samples: [Float]) {
        let deliver = lock.withLock { self.deliver }
        deliver?(samples)
    }

    /// The tap delivery as it was when installed, kept past a retire so a test can
    /// replay a buffer that was already in flight.
    func keptDelivery() -> (@Sendable ([Float]) -> Void)? {
        lock.withLock { deliver }
    }
}

/// Stands in for AVFoundation under `MicRecorder`: hands out fake engines (each one
/// configured by the test in advance), answers whether a device is alive, and never
/// asks for a permission.
final class FakeMicBackend: MicEngineBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _engines: [FakeMicEngine] = []
    private var _alive = true
    private var _pinHolds: [Int: Hold] = [:]
    private var _failStartFrom: Int?

    var engines: [FakeMicEngine] { lock.withLock { _engines } }

    /// Whether the pinned device is still there.
    var deviceAlive: Bool {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }

    /// The engine built `index`-th (0 is the first start) parks inside its pin.
    func holdPin(ofEngine index: Int, on hold: Hold) {
        lock.withLock { _pinHolds[index] = hold }
    }

    /// Every engine from the `index`-th on refuses to start.
    func failStarts(fromEngine index: Int) {
        lock.withLock { _failStartFrom = index }
    }

    func ensurePermission() throws {}

    func makeEngine() -> any MicEngine {
        lock.withLock {
            let index = _engines.count
            let engine = FakeMicEngine(
                pinHold: _pinHolds[index],
                failsToStart: _failStartFrom.map { index >= $0 } ?? false
            )
            _engines.append(engine)
            return engine
        }
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool { deviceAlive }
}

/// Whatever a recorder delivered, in order.
final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [[Float]] = []

    var sink: @Sendable ([Float]) -> Void { { [self] in let s = $0; lock.withLock { _all.append(s) } } }
    var all: [[Float]] { lock.withLock { _all } }
}
