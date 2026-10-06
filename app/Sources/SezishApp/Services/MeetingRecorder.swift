import AudioToolbox
import Foundation
import SezishCore
import os

/// One line per stop: clock time against what each stem holds, and how each capture's
/// stop ended. "Ten minutes, zero mic frames" was invisible until now.
private nonisolated let captureLog = Logger(subsystem: "com.smixs.sezish", category: "meeting-stop")

/// Orchestrates a meeting capture: mic stem (own AVAudioEngine instance,
/// independent of the dictation recorder) + system-audio stem (process tap),
/// both spooled to disk, mixed to one mono track on stop.
@MainActor
final class MeetingRecorder {
    /// Builds this recording's microphone. Injectable because the device id handed over
    /// here is the whole mic route, and nothing else in the app can see what reached it.
    typealias MicFactory = (AudioDeviceID?, @escaping @Sendable ([Float]) -> Void) -> MeetingMicCapture
    /// Builds this recording's system-audio capture. Injectable for the same reason as
    /// the mic: the stop logic is held by tests against captures that hang.
    typealias SystemFactory = (@escaping @Sendable ([Float]) -> Void) -> SystemCapture

    /// The owner's limit (D4): how long a stop waits for either capture.
    nonisolated static let defaultStopTimeout: TimeInterval = 5

    private let meetingsDir: URL
    private let makeMic: MicFactory
    private let makeSystem: SystemFactory
    private let stopTimeout: TimeInterval
    private let watchdog: StopWatchdog

    init(
        meetingsDir: URL = MeetingRecorder.meetingsDirectory,
        makeMic: @escaping MicFactory = MeetingRecorder.engineMic,
        makeSystem: @escaping SystemFactory = MeetingRecorder.coreAudioSystem,
        stopTimeout: TimeInterval = MeetingRecorder.defaultStopTimeout,
        watchdog: @escaping StopWatchdog = GuardedStop.realWatchdog
    ) {
        self.meetingsDir = meetingsDir
        self.makeMic = makeMic
        self.makeSystem = makeSystem
        self.stopTimeout = stopTimeout
        self.watchdog = watchdog
    }

    /// The real mic: a fresh `AVAudioEngine`, pinned to `deviceID` before the format is
    /// read and the tap installed. nil is the engine's own default: dictation's way.
    /// Restarted on the same device when a device change stops it (owner decision D1);
    /// dictation's mic is not.
    nonisolated static func engineMic(
        deviceID: AudioDeviceID?, onSamples16k: @escaping @Sendable ([Float]) -> Void
    ) -> MeetingMicCapture {
        MicRecorder(deviceID: deviceID, onSamples16k: onSamples16k, restartsOnConfigurationChange: true)
    }

    /// The real system audio: a process tap on CoreAudio.
    nonisolated static func coreAudioSystem(
        onSamples16k: @escaping @Sendable ([Float]) -> Void
    ) -> SystemCapture {
        SystemAudioTap(onSamples16k: onSamples16k)
    }

    enum StartOutcome {
        case full
        /// System-audio tap failed (typically TCC denied): recording continues
        /// with the mic only — a one-sided record beats none.
        case micOnly(Error)
    }

    struct Capture: Sendable {
        let mixed16k: [Float]
        let duration: TimeInterval
        let systemAudioCaptured: Bool
        let tempDir: URL
        /// Frames per stem and how each capture's stop ended.
        let integrity: MeetingCaptureIntegrity
    }

    enum MeetingRecorderError: Error {
        case notRecording
        /// A capture of an earlier take had to be abandoned (owner decision D3):
        /// CoreAudio in this process is not trusted again until the app restarts.
        case captureBroken
    }

    private var mic: (any MeetingMicCapture)?
    private var system: (any SystemCapture)?
    /// Shut first thing on stop: whatever a capture still delivers after that, live
    /// or abandoned, reaches neither the stems, nor the pipeline, nor the loudness
    /// signals the next take inherits.
    private var micGate: SampleGate?
    private var systemGate: SampleGate?
    private var micStem: MeetingStem?
    private var systemStem: MeetingStem?
    private var tempDir: URL?
    private(set) var startDate: Date?
    /// The silence stop's per-track signals, fed from the audio callbacks.
    private let micLoudness = MeetingLoudnessSignal()
    private let systemLoudness = MeetingLoudnessSignal()
    /// When the stop poll last looked at the signals; the first tick asks about
    /// the whole recording so far.
    private var loudnessPolledAt: Date?

    var isRecording: Bool { startDate != nil }

    /// Set for good when a stop had to abandon a capture: every later start refuses
    /// at once, before a single CoreAudio call, so a stuck HAL can neither hang the
    /// main thread on the next start nor pile up taps until the app restarts.
    private(set) var captureBroken = false

    static var meetingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sezish", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `pipeline` (optional) gets the same sample streams the stems spool, for
    /// incremental transcription while the recording is still running. `coverage`
    /// decides whose audio the system stem holds — the call app's own processes, or
    /// everything that plays when no app could be named (decided in `SezishCore`).
    /// `device` pins the microphone to the input the call app listens to; nil leaves
    /// the engine on the system default, exactly as dictation records.
    func start(
        coverage: TapCoverage, device: AudioDeviceID?,
        pipeline: MeetingTranscriptionPipeline? = nil
    ) throws -> StartOutcome {
        guard !isRecording else { return .full }
        guard !captureBroken else { throw MeetingRecorderError.captureBroken }

        let dir = meetingsDir
            .appendingPathComponent(".rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micStem = MeetingStem(
            spool: try PCMSpoolFile(url: dir.appendingPathComponent("mic.wav")), label: "mic"
        )
        let systemStem = MeetingStem(
            spool: try PCMSpoolFile(url: dir.appendingPathComponent("system.wav")), label: "system"
        )

        // Mic first: the user's own voice is the non-negotiable half.
        let micLoudness = self.micLoudness
        let micGate = SampleGate()
        let mic = makeMic(device) { samples in
            micGate.pass {
                micStem.ingest(samples)
                pipeline?.ingestMic(samples)
                micLoudness.ingest(samples)
            }
        }
        do {
            try mic.start()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        var outcome = StartOutcome.full
        let systemLoudness = self.systemLoudness
        let systemGate = SampleGate()
        let system = makeSystem { samples in
            systemGate.pass {
                systemStem.ingest(samples)
                pipeline?.ingestSystem(samples)
                systemLoudness.ingest(samples)
            }
        }
        do {
            try system.start(coverage: coverage)
            self.system = system
            self.systemStem = systemStem
            self.systemGate = systemGate
        } catch {
            // Mic survives without the system half: a one-sided record beats none.
            outcome = .micOnly(error)
            self.system = nil
            self.systemStem = nil
            self.systemGate = nil
            pipeline?.systemStreamUnavailable()
        }

        self.mic = mic
        self.micStem = micStem
        self.micGate = micGate
        self.tempDir = dir
        self.startDate = Date()
        loudnessPolledAt = self.startDate
        return outcome
    }

    /// One stop-poll tick's input: whether each track held a speech frame since
    /// the previous tick. Without a system stem the mic is the only track there
    /// is, so it alone decides — a mic-only recording must still stop on silence.
    func loudness(at now: Date) -> (mic: Bool, system: Bool) {
        let since = loudnessPolledAt ?? now
        loudnessPolledAt = now
        let mic = micLoudness.isLoud(since: since)
        guard system != nil else { return (mic: mic, system: false) }
        return (mic: mic, system: systemLoudness.isLoud(since: since))
    }

    /// Never waits on a capture synchronously: each stop runs under the watchdog, and
    /// a capture that does not come back in `stopTimeout` is abandoned. The take is
    /// written from whatever reached the disk either way.
    func stop() async throws -> Capture {
        guard let startDate, let tempDir, let mic, let micStem, let micGate else {
            throw MeetingRecorderError.notRecording
        }
        let duration = Date().timeIntervalSince(startDate)
        let systemStem = systemStem
        let system = system
        let systemGate = systemGate
        let systemCaptured = system != nil
        let timeout = stopTimeout
        let watchdog = watchdog

        micGate.close()
        systemGate?.close()
        resetState()

        async let micStop = GuardedStop.run(
            on: DispatchQueue(label: "com.smixs.sezish.meeting-mic.stop", qos: .userInitiated),
            timeout: timeout, watchdog: watchdog
        ) { mic.stopSynchronously() }
        async let systemStop = Self.stop(system, timeout: timeout)
        let micResult = await micStop
        let systemResult = await systemStop
        let systemLost = system?.lostDuringRecording ?? false
        if micResult == .abandoned || systemResult == .abandoned {
            captureBroken = true
        }

        // Finalize + chunked mixdown off the main actor (hundreds of MB for long calls).
        return try await Task.detached(priority: .userInitiated) {
            let micFrames = try micStem.finish()
            let systemFrames = try systemStem?.finish()
            let integrity = MeetingCaptureIntegrity(
                micFrames: micFrames, systemFrames: systemFrames,
                micAbandoned: micResult == .abandoned,
                systemAbandoned: systemResult == .abandoned,
                systemLost: systemLost
            )
            Self.log(integrity, duration: duration)

            let micReader = try PCMSpoolReader(url: tempDir.appendingPathComponent("mic.wav"))
            let systemReader = systemCaptured
                ? try? PCMSpoolReader(url: tempDir.appendingPathComponent("system.wav"))
                : nil

            var mixed: [Float] = []
            mixed.reserveCapacity(max(micReader.frameCount, systemReader?.frameCount ?? 0))
            while true {
                let a = try micReader.readChunk(maxFrames: 65_536)
                let b = try systemReader?.readChunk(maxFrames: 65_536)
                if a == nil, b == nil { break }
                mixed.append(contentsOf: AudioMixdown.mix((a ?? [])[...], (b ?? [])[...]))
            }

            return Capture(
                mixed16k: mixed,
                duration: duration,
                systemAudioCaptured: systemReader != nil,
                tempDir: tempDir,
                integrity: integrity
            )
        }.value
    }

    /// A recording without a system capture has nothing to stop.
    private nonisolated static func stop(
        _ system: (any SystemCapture)?, timeout: TimeInterval
    ) async -> CaptureStopResult {
        guard let system else { return .stopped }
        return await system.stop(timeout: timeout)
    }

    private nonisolated static func log(_ integrity: MeetingCaptureIntegrity, duration: TimeInterval) {
        let rate = Double(MeetingCaptureIntegrity.sampleRate)
        let mic = Double(integrity.micFrames) / rate
        let system = integrity.systemFrames.map { String(format: "%.1f s", Double($0) / rate) } ?? "none"
        let line = String(
            format: "meeting capture: %.1f s by clock, mic %.1f s%@, system %@%@%@",
            duration, mic,
            integrity.micAbandoned ? " (stop abandoned)" : "",
            system,
            integrity.systemAbandoned ? " (stop abandoned)" : "",
            integrity.systemLost ? " (rebuild failed)" : ""
        )
        if integrity.abandoned || integrity.isBroken(duration: duration) {
            captureLog.error("\(line, privacy: .public)")
        } else {
            captureLog.notice("\(line, privacy: .public)")
        }
    }

    private func resetState() {
        mic = nil
        system = nil
        micGate = nil
        systemGate = nil
        micStem = nil
        systemStem = nil
        tempDir = nil
        startDate = nil
        loudnessPolledAt = nil
        micLoudness.reset()
        systemLoudness.reset()
    }
}

/// One track's loudness for the silence stop. The realtime callback only folds
/// samples into a 100 ms frame and stamps the last loud moment as a `Date`; the
/// 1 Hz poll then asks whether that was since it last looked, so a poll that
/// slips a beat still sees the track as alive.
private nonisolated final class MeetingLoudnessSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var meter = MeetingLoudnessMeter()
    private var lastLoudAt: Date?

    func ingest(_ samples16k: [Float]) {
        lock.withLock {
            if meter.append(samples16k) { lastLoudAt = Date() }
        }
    }

    func isLoud(since previousTick: Date) -> Bool {
        lock.withLock { lastLoudAt.map { $0 >= previousTick } ?? false }
    }

    /// Nothing of one take survives into the next: the recorder outlives every
    /// recording, so a half-counted frame or a stale "loud" moment would otherwise
    /// shift the start of the next take's silence window.
    func reset() {
        lock.withLock {
            meter.reset()
            lastLoudAt = nil
        }
    }
}

/// One capture's door to the rest of the recording. The check and the delivery run
/// under one lock, so once `close()` returns no delivery is in flight and none will
/// follow.
private nonisolated final class SampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func pass(_ deliver: () -> Void) {
        lock.withLock {
            guard open else { return }
            deliver()
        }
    }

    func close() {
        lock.withLock { open = false }
    }
}
