import AVFoundation
import AudioToolbox
import Foundation
import SezishCore
import os

// Captures system audio via a Core Audio process tap: the call app's own
// processes when one is known, the global mixdown otherwise.
// Adapted from insidegui/AudioCap (https://github.com/insidegui/AudioCap,
// BSD-2-Clause license). The first `start()` triggers the system's
// "System Audio Recording" TCC prompt (usage string is in Info.plist).

/// Every rebuild of the aggregate, every refused one and every abandoned stop: the
/// incident of 06.10.2026 had 43 rebuilds in the system log and not one line of ours.
private nonisolated let tapLog = Logger(subsystem: "com.smixs.sezish", category: "system-tap")

enum SystemAudioTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case formatUnavailable
    case aggregateFailed(OSStatus)
    case ioProcFailed(OSStatus)
    /// An earlier stop never came back: this tap's queue may be stuck for good.
    case abandoned

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): "Process tap creation failed (\(s))"
        case .formatUnavailable: "No usable tap audio format"
        case .aggregateFailed(let s): "Aggregate device creation failed (\(s))"
        case .ioProcFailed(let s): "Audio IO proc failed (\(s))"
        case .abandoned: "System audio capture was abandoned after a stop that never returned"
        }
    }
}

/// The meeting recorder's system-audio track. A seam, like the mic factory: the
/// recorder's stop logic is tested against fakes, the tap's own threading against a
/// fake CoreAudio.
nonisolated protocol SystemCapture: AnyObject, Sendable {
    func start(coverage: TapCoverage) throws
    /// Never blocks its caller: answers `.abandoned` when the stop has not returned
    /// within `timeout`.
    func stop(timeout: TimeInterval) async -> CaptureStopResult
    /// A device change left the track without an aggregate at least once.
    var lostDuringRecording: Bool { get }
}

/// Two queues, because one queue was a deadlock (incident 06.10.2026). The HAL's IO
/// thread dispatches the IOProc block synchronously onto its queue while holding the
/// device mutex; `AudioDeviceStop` takes that same mutex. With the block and the
/// output-change listener on one queue, a listener inside `AudioDeviceStop` waited
/// for the IO thread, and the IO thread waited for the listener's queue.
///
/// - `ioQueue` runs the IOProc blocks and nothing else; they wait on nothing from
///   the HAL, only on short locks of the stem and the pipeline.
/// - `controlQueue` owns all other state: start, stop, the listener, every rebuild.
///
/// The stop flag and the abandoned flag live under a lock instead: they are set by
/// callers that must not wait for `controlQueue`.
nonisolated final class SystemAudioTap: SystemCapture, @unchecked Sendable {
    let controlQueue = DispatchQueue(label: "com.smixs.sezish.system-tap.control", qos: .userInitiated)
    let ioQueue = DispatchQueue(label: "com.smixs.sezish.system-tap.io", qos: .userInitiated)

    private let backend: any SystemTapBackend
    private let watchdog: StopWatchdog
    private let onSamples16k: @Sendable ([Float]) -> Void

    // controlQueue state
    private var tap: TapHandle?
    private var aggregate: AggregateHandle?
    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var rebuilds = 0

    // lock state
    private let flags = NSLock()
    private var stopRequested = false
    private var abandoned = false
    private var lost = false

    init(
        backend: any SystemTapBackend = CoreAudioTapBackend(),
        watchdog: @escaping StopWatchdog = GuardedStop.realWatchdog,
        onSamples16k: @escaping @Sendable ([Float]) -> Void
    ) {
        self.backend = backend
        self.watchdog = watchdog
        self.onSamples16k = onSamples16k
    }

    var isAbandoned: Bool { flags.withLock { abandoned } }
    var lostDuringRecording: Bool { flags.withLock { lost } }

    private var isStopRequested: Bool { flags.withLock { stopRequested } }

    /// Synchronous on `controlQueue`, as before; an abandoned tap refuses at once
    /// instead of queueing behind a stop that never returned.
    func start(coverage: TapCoverage) throws {
        let refused: Bool = flags.withLock {
            guard !abandoned else { return true }
            stopRequested = false
            return false
        }
        if refused { throw SystemAudioTapError.abandoned }
        try controlQueue.sync { try startOnQueue(coverage: coverage) }
    }

    /// The stop flag goes up first, under the lock, so every listener block already
    /// queued ahead of the stop finds it and does nothing: a storm of output changes
    /// cannot outlast the watchdog with rebuilds nobody needs. Then the teardown is
    /// queued behind them, raced by the watchdog.
    func stop(timeout: TimeInterval) async -> CaptureStopResult {
        let alreadyAbandoned: Bool = flags.withLock {
            stopRequested = true
            return abandoned
        }
        if alreadyAbandoned { return .abandoned }
        return await GuardedStop.run(
            on: controlQueue, timeout: timeout, watchdog: watchdog,
            onAbandon: { [self] in
                flags.withLock { abandoned = true }
                tapLog.error(
                    "system tap stop abandoned: no return within \(timeout, privacy: .public) s"
                )
            },
            body: { [self] in stopOnQueue() }
        )
    }

    // MARK: - On controlQueue

    private func startOnQueue(coverage: TapCoverage) throws {
        guard !running else { return }

        // 1. Mono mixdown tap over what the start decided (TCC prompt on first use).
        let newTap = try backend.createTap(coverage: coverage)
        tap = newTap

        // 2+3. Converter for the tap's native format, then the aggregate that
        //      hosts the tap. Any failure here has to tear the tap down again.
        do {
            try makeConverter(for: newTap)
            try buildAggregate()
        } catch {
            stopOnQueue()
            throw error
        }

        installDeviceChangeListener()
        running = true
    }

    /// The tap's native format and the 16 kHz mono converter built from it, kept for
    /// every aggregate of this recording: the IOProc blocks of the old and the new
    /// aggregate all run on the one serial `ioQueue`, so they never overlap.
    private func makeConverter(for tap: TapHandle) throws {
        var streamDescription = tap.format
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: output)
        else {
            throw SystemAudioTapError.formatUnavailable
        }
        tapFormat = format
        outputFormat = output
        self.converter = converter
    }

    private func stopOnQueue() {
        running = false
        removeDeviceChangeListener()
        tearDownAggregate()
        if let tap {
            backend.destroyTap(tap)
            self.tap = nil
        }
        converter = nil
        tapFormat = nil
        outputFormat = nil
    }

    /// Hosts the tap on an aggregate device clocked by the current default output.
    /// The IOProc block touches only the values captured here, never `self`.
    private func buildAggregate() throws {
        guard let tap, let tapFormat, let outputFormat, let converter else {
            throw SystemAudioTapError.formatUnavailable
        }
        let onSamples = onSamples16k
        aggregate = try backend.startAggregate(for: tap, ioQueue: ioQueue) { inInputData in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil
            ) else { return }
            let converted = AudioResampler.resample(buffer, using: converter, to: outputFormat)
            if !converted.isEmpty { onSamples(converted) }
        }
    }

    private func tearDownAggregate() {
        guard let aggregate else { return }
        backend.stopAggregate(aggregate)
        self.aggregate = nil
    }

    // MARK: - Output device changes (AirPods mid-call, etc.)

    private func installDeviceChangeListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on `controlQueue` (registered below).
            self?.outputDeviceChanged()
        }
        do {
            try backend.addOutputListener(on: controlQueue, listener)
            deviceListener = listener
        } catch {
            tapLog.error(
                "system tap: no output listener, device changes will not be followed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Rebuilds the aggregate on the new output. A block that finds the stop already
    /// asked for does nothing: the stop queued behind it tears everything down anyway.
    private func outputDeviceChanged() {
        guard running, !isStopRequested else { return }
        let old = aggregate?.output ?? "none"
        tearDownAggregate()
        guard !isStopRequested else { return }
        rebuilds += 1
        do {
            try buildAggregate()
            tapLog.notice(
                "system tap rebuild \(self.rebuilds, privacy: .public): \(old, privacy: .public) -> \(self.aggregate?.output ?? "?", privacy: .public)"
            )
        } catch {
            // The system track has no aggregate until the next device change: the
            // take must know, or its silence would read as a quiet call.
            flags.withLock { lost = true }
            tapLog.error(
                "system tap rebuild \(self.rebuilds, privacy: .public) failed after \(old, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func removeDeviceChangeListener() {
        guard let deviceListener else { return }
        backend.removeOutputListener(on: controlQueue, deviceListener)
        self.deviceListener = nil
    }
}
