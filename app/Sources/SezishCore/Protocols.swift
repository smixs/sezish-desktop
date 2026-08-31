import Foundation

// The three dependencies below are `Sendable`: the MainActor `DictationCoordinator`
// invokes their nonisolated `async` methods, which crosses concurrency domains.

/// Turns 16 kHz mono PCM samples into text. Real impl (whisper/onnx) arrives in stage 2.
public protocol Transcriber: Sendable {
    func transcribe(_ samples16k: [Float]) async throws -> String
    /// Optional: called when recording starts, so init/connection costs are paid
    /// while the user is still speaking (ONNX session init, TLS + container wake).
    func warmup() async throws
}

public extension Transcriber {
    func warmup() async throws {}
}

/// Transcriber that consumes audio while recording is in progress.
/// `cancelStream()` can arrive before `startStream()` has returned and must be survived;
/// `finishStream()` only ever arrives after `startStream()` returned.
public protocol StreamingTranscriber: Transcriber {
    /// Called on begin(): opens the session. Errors surface from finishStream().
    func startStream() async
    /// Realtime audio thread, must not block. Samples fed before the session is
    /// open are buffered inside the implementation.
    func feed(_ samples16k: [Float])
    /// Called on end(): flushes, signals end of speech, returns the full transcript.
    func finishStream() async throws -> String
    /// Esc: drop the session, nothing returned.
    func cancelStream() async
}

/// Microphone capture. Real impl (AVAudioEngine) arrives in stage 2.
public protocol MicCapture: Sendable {
    func start() throws
    func stop() async throws -> [Float]
}

/// Inserts text at the current cursor. Real impl (CGEvent/Accessibility) arrives in stage 2.
public protocol TextInserter: Sendable {
    func insert(_ text: String) async throws
}

/// Dictation hotkey. Emits raw press/release edges; what they mean (hold vs toggle) is the
/// `HotkeyModeInterpreter`'s business. Real impl (CGEventTap) lives in the app layer.
public protocol HotkeyMonitor: AnyObject {
    var onPressed: (() -> Void)? { get set }
    var onReleased: (() -> Void)? { get set }
    func startMonitoring() throws
    func stopMonitoring()
}
