import Foundation

/// Drives one push-to-talk dictation over the injected protocols:
/// Idle → Recording → Processing → Idle. MainActor-isolated because it is driven
/// straight from UI / hotkey callbacks and mutates observable state.
@MainActor
public final class DictationCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case processing
    }

    /// What one `end()` produced, so the caller can give the user feedback.
    public enum Outcome: Sendable, Equatable {
        /// Nothing to do: not recording, or the clip was too short to be speech.
        case ignored
        /// Transcribed, stored to history, and inserted at the cursor.
        case inserted
        /// Transcribed and stored to history, but insertion failed. Carries a
        /// user-facing message (e.g. secure input → "paste manually with ⌘V"); the
        /// text is on the pasteboard when the inserter staged it before failing.
        case insertFailed(String)
        /// Transcription produced nothing (error or empty result). The AUDIO is kept
        /// in history with an empty text so the take is never lost.
        case noText
        /// Mic capture failed — nothing was recorded, so nothing could be kept.
        case failed
    }

    /// What one `retranscribe()` produced.
    public enum RetryOutcome: Sendable, Equatable {
        /// Transcribed on the second try; the record now carries this text.
        case done(String)
        /// Still nothing: the audio and a fresh reason stay in history.
        case noText
        /// A take or another retry is in flight; nothing was touched.
        case busy
    }

    public private(set) var state: State = .idle

    /// Stored as the reason when the transcriber returns an empty string: no error was
    /// thrown, so there is no message to keep.
    public static let emptyTranscriptReason = "empty"
    /// Stored when the failure carries no user-facing message.
    public static let unknownFailureReason = "unknown"

    /// Sample rate the mic delivers and the transcriber expects.
    public static let sampleRate = 16_000
    /// Shortest recording we keep. Anything under 0.3 s is a stray key-tap: dropped
    /// without transcribing, inserting, or storing.
    public static let minimumSamples = Int(0.3 * Double(sampleRate)) // 4800

    private let mic: MicCapture
    private let transcriber: Transcriber
    /// The same object as `transcriber` when it eats audio while recording. Resolved
    /// once here, so the hot paths branch on a stored value instead of a cast.
    private let streaming: StreamingTranscriber?
    /// The `startStream()` launched by `begin()`. Only the flush waits on it, so
    /// `finishStream()` cannot overtake the opening; Esc and the drop paths forget it
    /// instead — waiting there would hang the take on a stuck connection.
    private var streamStart: Task<Void, Never>?
    /// Which engine `transcriber` is — "cloud" or "local/<model>". Stamped onto every history
    /// record so a transcript can be attributed after the fact; the coordinator is rebuilt
    /// whenever the mode changes, so one value per instance is exact.
    private let engine: String
    private let inserter: TextInserter
    private let history: DictationHistory

    public init(
        mic: MicCapture, transcriber: Transcriber, engine: String,
        inserter: TextInserter, history: DictationHistory
    ) {
        self.mic = mic
        self.transcriber = transcriber
        self.streaming = transcriber as? StreamingTranscriber
        self.engine = engine
        self.inserter = inserter
        self.history = history
    }

    /// Hotkey pressed. Only starts from Idle, so repeats during Recording/Processing are ignored.
    public func begin() {
        guard state == .idle else { return }
        do {
            try mic.start()
            state = .recording
            if let streaming {
                // The session IS the warmup here: it has to be open for the app layer
                // to feed samples into it while the user is still speaking.
                streamStart = Task.detached { await streaming.startStream() }
            } else {
                // Pay transcriber startup (ONNX init / TLS + cloud container wake) while
                // the user is speaking, so `end()` sees a warm path.
                let transcriber = transcriber
                Task.detached { try? await transcriber.warmup() }
            }
        } catch {
            state = .idle
        }
    }

    /// Hotkey released. Captures, transcribes, stores, then inserts. Always returns to Idle.
    ///
    /// The transcript is written to history *before* the insertion is attempted, so a paste
    /// failure (e.g. secure input) never discards successfully transcribed text. Insertion is
    /// caught on its own so such a failure is reported (`.insertFailed`) rather than swallowed.
    @discardableResult
    public func end() async -> Outcome {
        guard state == .recording else { return .ignored }
        state = .processing
        defer { state = .idle }
        let samples: [Float]
        do {
            samples = try await mic.stop()
        } catch {
            // Nothing was captured, nothing to keep — but an open session would hang
            // on the wire, so drop it too.
            streamStart = nil
            await streaming?.cancelStream()
            return .failed
        }
        guard samples.count >= Self.minimumSamples else {
            streamStart = nil
            await streaming?.cancelStream() // too short to be speech — drop it, do not flush
            return .ignored
        }
        let text: String
        do {
            if let streaming {
                await streamStart?.value // the session must be open before it can be flushed
                streamStart = nil
                text = try await streaming.finishStream()
            } else {
                text = try await transcriber.transcribe(samples)
            }
        } catch {
            // The take must never be lost: keep the audio, the engine and the reason,
            // so the user can read what happened and run it again.
            _ = try? history.add(
                text: "", samples16k: samples, engine: engine, error: Self.reason(for: error))
            return .noText
        }
        guard !text.isEmpty else {
            _ = try? history.add(
                text: "", samples16k: samples, engine: engine, error: Self.emptyTranscriptReason)
            return .noText
        }
        // Persist first: from here the transcript survives even if insertion fails.
        _ = try? history.add(text: text, samples16k: samples, engine: engine)
        do {
            try await inserter.insert(text)
        } catch {
            return .insertFailed(error.localizedDescription)
        }
        return .inserted
    }

    /// Runs a stored take through the transcriber again and writes the result back onto
    /// the same record. Nothing is typed into the active window: the caller decides what
    /// to do with the text. Holds Processing for the whole retry, so the hotkey cannot
    /// start a take on top of it.
    public func retranscribe(_ record: DictationRecord) async -> RetryOutcome {
        guard state == .idle else { return .busy }
        state = .processing
        defer { state = .idle }
        let text: String
        do {
            let samples = try history.samples(of: record)
            text = try await transcriber.transcribe(samples)
        } catch {
            return failedRetry(record, reason: Self.reason(for: error))
        }
        guard !text.isEmpty else {
            return failedRetry(record, reason: Self.emptyTranscriptReason)
        }
        do {
            try history.update(id: record.id, text: text, engine: engine, error: nil)
        } catch {
            return .noText // record deleted mid-retry, or the index could not be written
        }
        return .done(text)
    }

    /// A retry that produced nothing. A take that already has a transcript keeps it
    /// untouched: the stored text is still the best one we have.
    ///
    /// The engine and the reason stay as they were written when the take failed. Overwriting
    /// them with the current engine's answer erases the only evidence of what actually broke —
    /// the retry runs on whatever engine is selected now, which may not be the one that lost
    /// the take.
    private func failedRetry(_ record: DictationRecord, reason: String) -> RetryOutcome {
        if record.needsTranscript {
            try? history.update(
                id: record.id, text: "", engine: record.engine ?? engine,
                error: Self.reason(original: record.error, retry: reason))
        }
        return .noText
    }

    /// Separates the original failure from the latest retry's. Language-neutral on purpose:
    /// the two halves come from the transcribers and are not localized.
    static let retrySeparator = " → "

    /// Original first, latest retry after it. Repeated retries replace their own half instead
    /// of stacking, so the line stays the two facts worth reading. `empty` and `unknown` are
    /// markers for the code, never worth half of a line the user reads.
    static func reason(original: String?, retry: String) -> String {
        let first = original?.components(separatedBy: retrySeparator).first ?? ""
        guard isReadable(first) else { return retry }
        guard isReadable(retry), retry != first else { return first }
        return first + retrySeparator + retry
    }

    private static func isReadable(_ text: String) -> Bool {
        !text.isEmpty && text != emptyTranscriptReason && text != unknownFailureReason
    }

    /// Only a LocalizedError carries a message meant for people. `String(describing:)`
    /// would leak type and file names into the UI.
    private static func reason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? Self.unknownFailureReason
    }

    /// Esc pressed during recording: stop the mic and discard the take entirely — no
    /// transcription, no insertion, no history entry. No-op unless recording.
    public func cancel() async {
        guard state == .recording else { return }
        state = .processing // blocks begin()/end() re-entry across the await
        defer { state = .idle }
        _ = try? await mic.stop() // samples deliberately discarded
        streamStart = nil // Esc must not wait out an opening that may never finish
        await streaming?.cancelStream()
    }
}
