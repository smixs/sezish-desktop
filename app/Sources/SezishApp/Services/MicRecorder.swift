@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import SezishCore

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

/// Captures the mic with `AVAudioEngine`, resampling every buffer to 16 kHz mono
/// Float32 on the fly. A fresh engine is built on each `start()` and fully retired on
/// `stop()` (stop + reset) — the FluidVoice pattern that avoids the input node sticking.
/// `nonisolated` + a lock because the tap callback runs on a realtime audio thread while
/// `stop()` reads the buffer from a background executor.
nonisolated final class MicRecorder: MicCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
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

    /// `deviceID` is the input this recorder must open — the meeting path, where the
    /// mic has to be the device the call app listens to. nil leaves the engine on
    /// whatever it picks itself, which is all dictation ever wants.
    init(
        deviceID: AudioDeviceID? = nil,
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onSamples16k: (@Sendable ([Float]) -> Void)? = nil,
        keepsBuffer: Bool? = nil
    ) {
        self.pinnedDeviceID = deviceID
        self.onLevel = onLevel
        self.onSamples16k = onSamples16k
        self.keepsBuffer = keepsBuffer ?? (onSamples16k == nil)
    }

    /// The dictation path, and the `MicCapture` seam: the engine's own default.
    func start() throws {
        try start(deviceID: nil)
    }

    /// `deviceID` pins the engine to one input device — the meeting path, where the
    /// mic has to be the device the call app listens to. nil keeps whatever the
    /// system default is, which is all dictation ever wants. A device that cannot
    /// be opened fails the start with its cause: falling back to the default would
    /// silently record the room instead of the call.
    func start(deviceID: AudioDeviceID?) throws {
        try ensurePermission()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        try pinInputDevice(deviceID, on: input)
        let (inputFormat, outputFormat, converter) = try Self.formats(for: input)

        lock.withLock {
            samples = []
            self.engine = engine
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let converted = AudioResampler.resample(buffer, using: converter, to: outputFormat)
            guard !converted.isEmpty else { return }
            self.onSamples16k?(converted)
            if self.keepsBuffer {
                self.lock.withLock { self.samples.append(contentsOf: converted) }
            }
            self.onLevel?(AudioLevel.rms(converted))
        }

        engine.prepare()
        try engine.start()
    }

    func stop() async throws -> [Float] {
        let (engine, captured): (AVAudioEngine?, [Float]) = lock.withLock {
            let engine = self.engine
            let captured = samples
            self.engine = nil
            samples = []
            return (engine, captured)
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        return captured
    }

    // MARK: - Permission

    /// The device's own input format, followed by the 16 kHz mono converter built
    /// from it.
    private static func formats(
        for input: AVAudioInputNode
    ) throws -> (AVAudioFormat, AVAudioFormat, AVAudioConverter) {
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw MicError.formatUnavailable
        }
        return (inputFormat, outputFormat, converter)
    }

    /// Pin the engine's input to `deviceID`; nil leaves the engine on the system
    /// default, which is what dictation records from. `AUAudioUnit.setDeviceID` is
    /// the only way to do that on an `AVAudioEngine`, and it has to happen before
    /// the format is read and the tap installed — the format follows the device.
    private func pinInputDevice(_ deviceID: AudioDeviceID?, on input: AVAudioInputNode) throws {
        guard let deviceID else { return }
        do {
            try input.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw MicError.deviceUnavailable(error)
        }
    }

    private func ensurePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // Can't block a synchronous `start()` on the async prompt: fire it so the OS
            // dialog appears, and fail this attempt. The next hold will be authorized.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw MicError.permissionPending
        default:
            throw MicError.permissionDenied
        }
    }

}
