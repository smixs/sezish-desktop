import Foundation
import os
import SezishCore
import OnnxRuntimeBindings

// SwiftPM's generated Bundle.module only checks the .app root and the dev .build
// path, but the app bundle ships resource bundles in Contents/Resources — look
// there first or resource lookup traps on any machine but the dev's.
//
// Files sit in a `Bundled` subdirectory, not `Resources`: a resource bundle with a
// top-level `Resources/` folder reads to iOS `codesign` as an old-style macOS bundle
// and fails to sign ("bundle format unrecognized"), which breaks the whole app build.
private let moduleResources: Bundle =
    Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("sezish_SezishAsr.bundle")) }
    ?? .module

public enum SezishAsrError: Error {
    case resourceMissing(String)
    case badVocabLine(String)
    case unexpectedOutput(String)
}

/// Native GigaAM multilingual CTC transcriber.
///
/// Runs a two-stage ONNX pipeline: a bundled preprocessor (waveform → log-mel features)
/// feeds the main CTC acoustic model (features → per-frame log-probabilities), whose output
/// is greedily CTC-decoded to text.
///
/// The acoustic model is large and injected by URL (never downloaded here). ORT sessions are
/// created lazily on the first `transcribe`/`warmup`. Being an `actor`, only one inference
/// runs at a time and the non-`Sendable` ORT objects stay confined to this instance.
///
/// Audio longer than `AudioChunker.defaultLimit` is cut and run piece by piece: the export's
/// attention mask is fixed at 200 s and one tensor with more than that in it throws.
///
/// Dictation drives it as a `StreamingTranscriber`: every chunk is transcribed while the user
/// is still speaking, so releasing the key costs the tail alone instead of the whole take.
public actor GigaAmTranscriber: StreamingTranscriber {
    private let modelURL: URL
    private let vocab: Vocab

    private var env: ORTEnv?
    private var preprocessor: ORTSession?
    private var acousticModel: ORTSession?

    /// Filled from the realtime audio thread by `feed`, emptied on the actor.
    private nonisolated let inbox = SampleBuffer()
    /// Samples taken off the inbox that are not yet a whole chunk.
    private var cutter = StreamCutter()
    private var streamParts: [String] = []
    /// The first chunk that failed. It fails the whole take: half a transcript silently
    /// missing its middle is worse than none, and the coordinator keeps the audio and the
    /// reason so the user can run it again.
    private var streamFailure: Error?
    private var streaming = false

    /// The local engine failed silently until this existed: `.notice` and `.error` survive on
    /// disk, so `log show --predicate 'subsystem == "com.smixs.sezish"'` can say what happened.
    private nonisolated let logger = Logger(subsystem: "com.smixs.sezish", category: "asr.local")

    /// - Parameter modelURL: path to the main `multilingual_ctc*.onnx` acoustic model.
    /// Model weights plus the token table they were trained with.
    public init(modelURL: URL, vocab: Vocab) {
        self.modelURL = modelURL
        self.vocab = vocab
    }

    /// Weights with the token table shipped in the module bundle.
    public init(modelURL: URL) throws {
        self.init(modelURL: modelURL, vocab: try Vocab.bundled())
    }

    /// Runs a short buffer of silence to pay session-init/JIT costs up front.
    public func warmup() async throws {
        _ = try await transcribe([Float](repeating: 0, count: 8_000)) // 0.5 s @ 16 kHz
    }

    public func transcribe(_ samples16k: [Float]) async throws -> String {
        guard !samples16k.isEmpty else { return "" }
        let chunks = AudioChunker.split(samples16k)
        logger.notice("transcribe \(samples16k.count / 16_000) s in \(chunks.count) chunk(s)")

        var parts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let text: String
            do {
                text = try run(Array(samples16k[chunk]))
            } catch {
                // ORT's message is the whole diagnosis ("Attempting to broadcast an axis..."),
                // and it never reaches the user: the coordinator stores `unknown` for it.
                logger.error(
                    "chunk \(index + 1)/\(chunks.count) failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - StreamingTranscriber

    /// Clean slate plus the ONNX session, so the first chunk of the take does not pay for it.
    ///
    /// The inbox is deliberately left alone: `begin()` starts the mic and this in parallel, so
    /// the first tap can land before the take is marked open, and those samples are the
    /// beginning of the speech. Whatever the previous take left was taken by its own
    /// `finishStream` or dropped by its `cancelStream`.
    public func startStream() async {
        resetTake()
        streaming = true
        try? await warmup()
    }

    /// Realtime audio thread. Appending under the lock is all that happens here; the
    /// transcription is picked up on the actor by the task this hands off to.
    public nonisolated func feed(_ samples16k: [Float]) {
        guard !samples16k.isEmpty else { return }
        inbox.append(samples16k)
        Task { await self.transcribeReadyChunks() }
    }

    public func finishStream() async throws -> String {
        // Drains queued by `feed` may still be waiting for the actor. Everything they would
        // have taken is taken here, and they find the take closed and do nothing.
        streaming = false
        cutter.append(inbox.takeAll())
        let parts = streamParts
        let failure = streamFailure
        let rest = cutter.takeRest()
        resetTake()

        if let failure { throw failure }
        // Normally one chunk at most; more when the drains never got the actor, and `transcribe`
        // cuts that the same way this would have.
        let tail = try await transcribe(rest)
        return (parts + [tail]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func cancelStream() async {
        streaming = false
        inbox.reset()
        resetTake()
    }

    /// Transcribes every chunk the stream has completed so far. No `await` inside, so the
    /// actor runs it to the end in one go: however the queued drains are scheduled, each one
    /// takes the oldest samples and appends its text before the next one starts, and the
    /// parts stay in the order they were spoken.
    private func transcribeReadyChunks() {
        guard streaming, streamFailure == nil else { return }
        cutter.append(inbox.takeAll())
        while let chunk = cutter.nextChunk() {
            do {
                let text = try run(chunk)
                if !text.isEmpty { streamParts.append(text) }
            } catch {
                logger.error(
                    "stream chunk failed: \(error.localizedDescription, privacy: .public)")
                streamFailure = error
                return
            }
        }
    }

    private func resetTake() {
        cutter = StreamCutter()
        streamParts = []
        streamFailure = nil
    }

    /// One pass through the ONNX pipeline. The caller guarantees the buffer fits the model.
    private func run(_ samples16k: [Float]) throws -> String {
        let (preprocessor, acousticModel) = try sessions()

        let sampleCount = samples16k.count
        let waveforms = try Self.floatTensor(samples16k, shape: [1, sampleCount])
        let waveformLengths = try Self.int64Tensor([Int64(sampleCount)], shape: [1])

        let features = try preprocessor.run(
            withInputs: ["waveforms": waveforms, "waveforms_lens": waveformLengths],
            outputNames: ["features", "features_lens"],
            runOptions: nil
        )
        guard let featureTensor = features["features"],
              let featureLengths = features["features_lens"] else {
            throw SezishAsrError.unexpectedOutput("preprocessor")
        }

        let logits = try acousticModel.run(
            withInputs: ["features": featureTensor, "feature_lengths": featureLengths],
            outputNames: ["log_probs"],
            runOptions: nil
        )
        guard let logProbs = logits["log_probs"] else {
            throw SezishAsrError.unexpectedOutput("log_probs")
        }

        let frames = try Self.frames(from: logProbs)
        return CtcDecoder.decode(frames: frames, tokens: vocab.tokens, blankId: vocab.blankId)
    }

    // MARK: - Lazy session setup

    private func sessions() throws -> (ORTSession, ORTSession) {
        if let preprocessor, let acousticModel { return (preprocessor, acousticModel) }

        let env = try self.env ?? ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        let preprocessorURL = try Self.bundledResource("gigaam_v3_conv", "onnx")

        let preprocessor = try ORTSession(
            env: env, modelPath: preprocessorURL.path, sessionOptions: options)
        let acousticModel = try ORTSession(
            env: env, modelPath: modelURL.path, sessionOptions: options)

        self.env = env
        self.preprocessor = preprocessor
        self.acousticModel = acousticModel
        return (preprocessor, acousticModel)
    }

    // MARK: - Tensor helpers

    private static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(
            tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func int64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(
            tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    /// Reshapes the `[1, T, vocab]` float log-prob tensor into `T` rows.
    private static func frames(from tensor: ORTValue) throws -> [[Float]] {
        let info = try tensor.tensorTypeAndShapeInfo()
        let dims = info.shape.map(\.intValue)
        guard dims.count == 3 else {
            throw SezishAsrError.unexpectedOutput("log_probs shape \(dims)")
        }
        let timeSteps = dims[1]
        let vocabSize = dims[2]

        let data = try tensor.tensorData() as Data
        let flat: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard flat.count >= timeSteps * vocabSize else {
            throw SezishAsrError.unexpectedOutput("log_probs data \(flat.count)")
        }

        var frames: [[Float]] = []
        frames.reserveCapacity(timeSteps)
        for step in 0..<timeSteps {
            let start = step * vocabSize
            frames.append(Array(flat[start..<start + vocabSize]))
        }
        return frames
    }

    private static func bundledResource(_ name: String, _ ext: String) throws -> URL {
        guard let url = moduleResources.url(
            forResource: name, withExtension: ext, subdirectory: "Bundled") else {
            throw SezishAsrError.resourceMissing("\(name).\(ext)")
        }
        return url
    }
}

extension Vocab {
    /// Loads the vocab shipped in the module bundle.
    static func bundled() throws -> Vocab {
        guard let url = moduleResources.url(
            forResource: "multilingual_vocab", withExtension: "txt", subdirectory: "Bundled") else {
            throw SezishAsrError.resourceMissing("multilingual_vocab.txt")
        }
        return try Vocab(contentsOf: url)
    }
}
