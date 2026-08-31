import Foundation

/// The on-device recognition models the user can pick between. Each one is a
/// self-contained set of files: exactly one `.onnx` plus its token table.
public enum AsrModel: String, Sendable, CaseIterable {
    /// Russian, Uzbek, Kazakh, Kyrgyz. Character-level output, no punctuation.
    /// The model every install already has, hence the default.
    case multilingual = "multilingual"
    /// Russian and English with punctuation, casing and normalized numbers.
    case ruEnPunctuated = "ru-en-punctuated"

    public static let `default`: AsrModel = .multilingual

    public var files: [ModelFile] {
        switch self {
        case .multilingual:
            return ModelStore.gigaamFiles
        case .ruEnPunctuated:
            // No config.json here: the app never reads it, and the multilingual set
            // already owns that file name in the shared directory.
            return [
                ModelFile(name: "v3_e2e_ctc.int8.onnx", size: 224_893_347),
                ModelFile(name: "v3_e2e_ctc_vocab.txt", size: 2_007),
            ]
        }
    }

    /// Where the files are fetched from; the file name is appended.
    public var remoteBase: URL {
        switch self {
        case .multilingual: return ModelStore.defaultRemoteBase
        case .ruEnPunctuated: return URL(string: "https://dl.sezi.sh/models/")!
        }
    }

    public var onnxFile: ModelFile {
        files.first { $0.name.hasSuffix(".onnx") }!
    }

    public var vocabFile: ModelFile {
        files.first { $0.name.hasSuffix("vocab.txt") }!
    }

    /// Total bytes the user downloads for this model.
    public var downloadBytes: Int {
        files.reduce(0) { $0 + $1.size }
    }
}
