@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// One `AVAudioEngine` capturing the mic, behind a seam so `MicRecorder`'s restart
/// logic can be tested without a device. Every call may block on the HAL:
/// `MicRecorder` decides which queue each one runs on.
nonisolated protocol MicEngine: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// Opens `deviceID` instead of whatever the engine picked itself.
    func pinInput(to deviceID: AudioDeviceID) throws
    /// Reads the input format as it is now, builds the 16 kHz mono converter from it
    /// and installs the tap, which hands over resampled chunks. The format follows the
    /// device (24 kHz on a Bluetooth headset in call mode, 48 kHz otherwise), so this
    /// comes after the pin. Returns the input sample rate, for the log.
    func installTap(_ deliver: @escaping @Sendable ([Float]) -> Void) throws -> Double
    func start() throws
    /// `AVAudioEngineConfigurationChange` for this engine, delivered on whatever
    /// thread AVFoundation posts it from.
    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void)
    /// Drops the observer, removes the tap, stops and resets. The engine is not used
    /// again afterwards.
    func retire()
}

/// What `MicRecorder` needs from AVFoundation and CoreAudio besides the engine.
nonisolated protocol MicEngineBackend: Sendable {
    func ensurePermission() throws
    func makeEngine() -> any MicEngine
    /// `kAudioDevicePropertyDeviceIsAlive`: false once a headset is gone.
    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool
}

/// Schedules a restart check: after `delay`, run `work` on `queue`. Injected so tests
/// fire it by hand and never wait on the wall clock.
typealias MicRestartScheduler = @Sendable (
    _ delay: TimeInterval, _ queue: DispatchQueue, _ work: @escaping @Sendable () -> Void
) -> Void

/// The real AVFoundation.
nonisolated struct AVMicEngineBackend: MicEngineBackend {
    func ensurePermission() throws {
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

    func makeEngine() -> any MicEngine {
        AVMicEngine()
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        (try? deviceID.read(kAudioDevicePropertyDeviceIsAlive, defaultValue: UInt32(0))) == 1
    }
}

/// A fresh `AVAudioEngine` per instance, fully retired at the end (stop + reset): the
/// FluidVoice pattern that avoids the input node sticking.
nonisolated final class AVMicEngine: MicEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine.isRunning }

    /// `AUAudioUnit.setDeviceID` is the only way to pin an `AVAudioEngine`'s input,
    /// and it has to happen before the format is read and the tap installed.
    func pinInput(to deviceID: AudioDeviceID) throws {
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw MicError.deviceUnavailable(error)
        }
    }

    func installTap(_ deliver: @escaping @Sendable ([Float]) -> Void) throws -> Double {
        let input = engine.inputNode
        let (inputFormat, outputFormat, converter) = try Self.formats(for: input)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let converted = AudioResampler.resample(buffer, using: converter, to: outputFormat)
            guard !converted.isEmpty else { return }
            deliver(converted)
        }
        return inputFormat.sampleRate
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in handler() }
        lock.withLock { observer = token }
    }

    func retire() {
        let token: NSObjectProtocol? = lock.withLock {
            let taken = observer
            observer = nil
            return taken
        }
        if let token { NotificationCenter.default.removeObserver(token) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

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
}
