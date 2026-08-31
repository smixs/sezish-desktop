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
public actor GigaAmTranscriber: Transcriber {
    private let modelURL: URL
    private let vocab: Vocab

    private var env: ORTEnv?
    private var preprocessor: ORTSession?
    private var acousticModel: ORTSession?

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
