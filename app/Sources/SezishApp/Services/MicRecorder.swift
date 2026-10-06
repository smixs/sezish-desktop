@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import SezishCore
import os

enum MicError: LocalizedError {
    case permissionDenied
    case permissionPending
    case formatUnavailable
    case deviceUnavailable(any Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "sezish needs Microphone permission. Enable it in System Settings → Privacy & Security → Microphone."
        case .permissionPending:
            "Grant Microphone access when prompted, then hold the key again."
        case .formatUnavailable:
            "No usable microphone input format is available."
        case .deviceUnavailable(let cause):
            "The selected input device could not be opened: \(cause.localizedDescription)"
        }
    }
}

/// The meeting recorder's microphone. Its stop is synchronous on purpose: the
/// recorder runs it on a dispatch queue of its own under a watchdog, because an
/// `AVAudioEngine.stop` on a broken HAL may never return, and an async stop would park
/// that hang on a cooperative-pool thread for good.
nonisolated protocol MeetingMicCapture: Sendable {
    func start() throws
    func stopSynchronously()
}

/// Captures the mic with `AVAudioEngine`, resampling every buffer to 16 kHz mono
/// Float32 on the fly. A fresh engine is built on each `start()` and fully retired on
/// `stop()` (stop + reset): the FluidVoice pattern that avoids the input node sticking.
///
/// The meeting mic (`restartsOnConfigurationChange`) also survives a device change
/// (owner decision D1, incident 06.10.2026): `AVAudioEngine` stops itself on
/// `AVAudioEngineConfigurationChange`, and the meeting kept recording 10 minutes with
/// a mic stopped 3 s in. Every change schedules one restart check after a settle
/// window; the check retires the stopped engine and builds a fresh one on the same
/// pinned device. Dictation never subscribes: a take lasts seconds, and the next hold
/// builds a new engine anyway.
///
/// Threading: `controlQueue` owns the engine (start, stop, every restart), so a
/// restart and a stop never interleave. The generation and the stop flag live under
/// `lock` instead: the tap reads the generation on the audio thread, and the stop
/// raises its flag before it queues, so a restart already waiting finds it.
nonisolated final class MicRecorder: MicCapture, MeetingMicCapture, @unchecked Sendable {
    /// How long a restart waits after the first configuration change, so a burst of
    /// changes (the incident had several per second while the output flapped between
    /// AirPods and the speakers) coalesces into one restart. In the incident one burst
    /// of the engine's own rerouting took ~1 s from the pin to a settled device.
    nonisolated static let restartSettleWindow: TimeInterval = 1
    /// Minimum time between two restarts. A device that keeps flapping can then cost
    /// at most one engine rebuild (and its sub-second gap) every 3 s instead of
    /// churning the HAL continuously.
    nonisolated static let restartSpacing: TimeInterval = 3
    /// Consecutive restarts that may fail (the device is gone, the engine refuses to
    /// start) before the mic is given up for the rest of the take. Each try is
    /// `restartSpacing` apart, so ~15 s for a headset to come back. A later
    /// configuration change starts a new round.
    nonisolated static let restartAttemptLimit = 5

    /// The real clock for the restart check.
    nonisolated static let realScheduler: MicRestartScheduler = { delay, queue, work in
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    let controlQueue = DispatchQueue(label: "com.smixs.sezish.mic.control", qos: .userInitiated)

    /// Per-buffer RMS for the recording indicator, fired on the realtime tap thread
    /// (~12 Hz at the 4096 buffer). Immutable, so it needs no lock coverage.
    private let onLevel: (@Sendable (Float) -> Void)?
    /// Streaming mode: when set, resampled chunks go to the callback (realtime thread).
    /// Dictation (nil) keeps the buffered path.
    private let onSamples16k: (@Sendable ([Float]) -> Void)?
    /// Whether the tap also accumulates the take for `stop()`. Streaming dictation needs
    /// both: the transcriber eats the audio live, and history still stores the .wav.
    /// A meeting (callback, no buffer) must never accumulate an hour of samples in RAM.
    private let keepsBuffer: Bool
    private let pinnedDeviceID: AudioDeviceID?
    let restartsOnConfigurationChange: Bool
    private let backend: any MicEngineBackend
    private let scheduler: MicRestartScheduler
    private let now: @Sendable () -> Date

    // controlQueue state
    private var engine: (any MicEngine)?
    private var restartPending = false
    private var coalescedChanges = 0
    private var lastRestartAt: Date?
    private var failedRestarts = 0

    // lock state
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Bumped for every engine built: a buffer stamped with an older one comes from an
    /// engine already replaced, and is dropped.
    private var generation = 0
    private var stopping = false

    /// `deviceID` is the input this recorder must open: the meeting path, where the
    /// mic has to be the device the call app listens to. nil leaves the engine on
    /// whatever it picks itself, which is all dictation ever wants.
    init(
        deviceID: AudioDeviceID? = nil,
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onSamples16k: (@Sendable ([Float]) -> Void)? = nil,
        keepsBuffer: Bool? = nil,
        restartsOnConfigurationChange: Bool = false,
        backend: any MicEngineBackend = AVMicEngineBackend(),
        scheduler: @escaping MicRestartScheduler = MicRecorder.realScheduler,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pinnedDeviceID = deviceID
        self.onLevel = onLevel
        self.onSamples16k = onSamples16k
        self.keepsBuffer = keepsBuffer ?? (onSamples16k == nil)
        self.restartsOnConfigurationChange = restartsOnConfigurationChange
        self.backend = backend
        self.scheduler = scheduler
        self.now = now
    }

    /// Raised by a stop before it queues; a restart checks it before it starts an engine.
    var isStopping: Bool { lock.withLock { stopping } }

    /// Opens the device this recorder was built for (nil is the engine's own default,
    /// which is all dictation wants). A device that cannot be opened fails the start
    /// with its cause: falling back to the default would silently record the room
    /// instead of the call.
    func start() throws {
        try backend.ensurePermission()
        lock.withLock {
            samples = []
            stopping = false
        }
        try controlQueue.sync {
            do {
                _ = try buildEngine()
            } catch {
                engine?.retire()
                engine = nil
                throw error
            }
        }
    }

    func stop() async throws -> [Float] {
        halt()
    }

    func stopSynchronously() {
        _ = halt()
    }

    /// Retires the engine and hands back whatever the buffered path accumulated. The
    /// stop flag goes up first, so a restart already queued or in flight never starts
    /// an engine; the retire then waits its turn behind it on `controlQueue`.
    private func halt() -> [Float] {
        lock.withLock { stopping = true }
        controlQueue.sync {
            engine?.retire()
            engine = nil
        }
        return lock.withLock {
            let captured = samples
            samples = []
            return captured
        }
    }

    // MARK: - Engine

    /// Builds, pins, taps and starts a fresh engine as the current one. On
    /// `controlQueue`. The engine is current before anything can fail, so whoever
    /// comes next (a stop, the next restart) retires it.
    private func buildEngine() throws -> Double {
        let engine = backend.makeEngine()
        let generation = lock.withLock {
            self.generation += 1
            return self.generation
        }
        self.engine = engine
        if restartsOnConfigurationChange {
            engine.observeConfigurationChanges { [weak self] in
                self?.configurationChanged(in: generation)
            }
        }
        if let pinnedDeviceID {
            try engine.pinInput(to: pinnedDeviceID)
        }
        let sampleRate = try engine.installTap { [weak self] samples in
            self?.deliver(samples, from: generation)
        }
        guard !isStopping else { throw RestartCancelled() }
        try engine.start()
        return sampleRate
    }

    /// The tap's delivery, on the audio thread.
    private func deliver(_ converted: [Float], from generation: Int) {
        let current = lock.withLock { self.generation == generation && !stopping }
        guard current else { return }
        onSamples16k?(converted)
        if keepsBuffer {
            lock.withLock { samples.append(contentsOf: converted) }
        }
        onLevel?(AudioLevel.rms(converted))
    }

    // MARK: - Restart (meeting only)

    private struct RestartCancelled: Error {}

    /// AVFoundation's thread: never waits, only queues.
    private func configurationChanged(in generation: Int) {
        controlQueue.async { [weak self] in
            self?.noteConfigurationChange(in: generation)
        }
    }

    private func noteConfigurationChange(in generation: Int) {
        let (current, stopping) = lock.withLock { (self.generation, self.stopping) }
        guard !stopping, generation == current else {
            meetingMicLog.debug("mic configuration changed: engine \(generation) already replaced or stopping, ignored")
            return
        }
        let running = engine?.isRunning ?? false
        if restartPending {
            coalescedChanges += 1
            meetingMicLog.notice(
                "mic configuration changed: engine \(generation) running \(running), coalesced into the pending restart check"
            )
            return
        }
        coalescedChanges = 0
        failedRestarts = 0
        let delay = restartDelay()
        meetingMicLog.notice(
            "mic configuration changed: engine \(generation) running \(running), restart check in \(delay, format: .fixed(precision: 1)) s"
        )
        scheduleRestart(after: delay, for: generation)
    }

    /// The settle window, stretched so two restarts stay `restartSpacing` apart.
    private func restartDelay() -> TimeInterval {
        let sinceLast = lastRestartAt.map { now().timeIntervalSince($0) } ?? .infinity
        return max(Self.restartSettleWindow, Self.restartSpacing - sinceLast)
    }

    private func scheduleRestart(after delay: TimeInterval, for generation: Int) {
        restartPending = true
        scheduler(delay, controlQueue) { [weak self] in
            self?.restartIfNeeded(scheduledFor: generation)
        }
    }

    /// On `controlQueue`, once the window has passed.
    private func restartIfNeeded(scheduledFor scheduled: Int) {
        restartPending = false
        let (current, stopping) = lock.withLock { (generation, self.stopping) }
        guard !stopping, scheduled == current, let old = engine else {
            meetingMicLog.notice("mic restart skipped: the mic is stopping or was rebuilt since")
            return
        }
        let coalesced = coalescedChanges
        coalescedChanges = 0
        if old.isRunning {
            meetingMicLog.notice(
                "mic restart not needed: engine \(current) still running (\(coalesced) more changes coalesced)"
            )
            return
        }
        if let pinnedDeviceID, !backend.isDeviceAlive(pinnedDeviceID) {
            meetingMicLog.error(
                "mic restart deferred: pinned device \(pinnedDeviceID) is gone, not switching to another input"
            )
            retryOrGiveUp()
            return
        }

        lastRestartAt = now()
        old.retire()
        engine = nil
        do {
            let sampleRate = try buildEngine()
            failedRestarts = 0
            meetingMicLog.notice(
                "mic restarted: engine \(current) -> \(current + 1), device \(self.pinnedDeviceID.map(String.init) ?? "default", privacy: .public), input \(sampleRate, format: .fixed(precision: 0)) Hz, \(coalesced) more changes coalesced"
            )
        } catch is RestartCancelled {
            meetingMicLog.notice("mic restart cancelled: the mic is stopping")
        } catch {
            meetingMicLog.error("mic restart failed: \(error.localizedDescription, privacy: .public)")
            retryOrGiveUp()
        }
    }

    /// A restart that could not happen is tried again `restartSpacing` later, up to
    /// `restartAttemptLimit` tries in a row.
    private func retryOrGiveUp() {
        failedRestarts += 1
        guard failedRestarts < Self.restartAttemptLimit else {
            meetingMicLog.error(
                "mic restart given up after \(self.failedRestarts) tries: the mic stays stopped until the next configuration change"
            )
            return
        }
        let generation = lock.withLock { self.generation }
        scheduleRestart(after: Self.restartSpacing, for: generation)
    }
}

/// Every configuration change the meeting mic sees and every restart it makes.
private nonisolated let meetingMicLog = Logger(subsystem: "com.smixs.sezish", category: "meeting-mic")
