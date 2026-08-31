import Foundation

/// One file of a model: its remote name and the exact byte size we expect on disk.
public struct ModelFile: Sendable, Equatable, Hashable {
    public let name: String
    public let size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// Where the model lives on disk and where its files come from.
///
/// Default directory is `~/Library/Application Support/sezish/.models`; `root` is injected
/// in tests. `files` defaults to the GigaAM multilingual CTC int8 model but is overridable
/// so tests can use tiny fixtures instead of the real 224 MB weights. `remoteBase` is
/// injected too: the Mac app pulls the weights from HuggingFace, the iOS app from our own
/// `dl.sezi.sh` — same file, but our box is markedly faster from Uzbekistan, where the
/// app's users are.
public struct ModelStore: Sendable, Equatable {
    /// Directory that holds the model files.
    public let directory: URL
    /// Files that make up the model.
    public let files: [ModelFile]
    /// Download source; the file name is appended to it.
    public let remoteBase: URL

    /// HuggingFace resolve endpoint — the default source.
    public static let defaultRemoteBase = URL(
        string: "https://huggingface.co/istupakov/gigaam-multilingual-ctc-onnx/resolve/main/")!

    /// GigaAM multilingual CTC, int8 quantized (ONNX).
    public static let gigaamFiles: [ModelFile] = [
        ModelFile(name: "multilingual_ctc.int8.onnx", size: 224_762_204),
        ModelFile(name: "multilingual_vocab.txt", size: 393),
        ModelFile(name: "config.json", size: 152),
    ]

    public init(
        root: URL? = nil,
        files: [ModelFile] = ModelStore.gigaamFiles,
        remoteBase: URL = ModelStore.defaultRemoteBase
    ) {
        if root == nil { Self.migrateDefaultDirectoryOnce() }
        self.directory = root ?? Self.defaultDirectory
        self.files = files
        self.remoteBase = remoteBase
    }

    /// Store for one selectable model: its files and download source.
    public init(model: AsrModel, root: URL? = nil) {
        self.init(root: root, files: model.files, remoteBase: model.remoteBase)
    }

    /// `~/Library/Application Support/sezish/.models` — dot-prefixed so Finder hides it
    /// next to the user-facing `DictationHistory/` and `Meetings/` folders.
    public static var defaultDirectory: URL {
        supportDirectory.appendingPathComponent(".models", isDirectory: true)
    }

    /// Pre-`.models` location, kept only as the source of the one-time move.
    public static var legacyDirectory: URL {
        supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sezish", isDirectory: true)
    }

    /// Moves an already-downloaded model from the old visible directory into the hidden one
    /// so upgrading users don't refetch ~225 MB. Same volume, so the whole folder is a rename
    /// (instant); if that fails it falls back to moving files one by one, never overwriting
    /// what the new directory already has. Idempotent, and errors are swallowed — the worst
    /// case is a re-download, never a crash.
    public static func migrateLegacyDirectory(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }

        if !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: old, to: new)
                return
            } catch {
                // Rename refused (e.g. a race with another instance) — merge file by file below.
            }
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        }

        // Both directories exist: `new` wins, `old` only fills its gaps and is then dropped.
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let target = new.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: old.appendingPathComponent(name), to: target)
        }
        try? fm.removeItem(at: old)
    }

    /// Runs the migration for the default paths once per process — a lazy static is
    /// initialized exactly once and thread-safely by the runtime.
    private static let defaultDirectoryMigration: Void = {
        migrateLegacyDirectory(from: legacyDirectory, to: defaultDirectory)
    }()

    private static func migrateDefaultDirectoryOnce() {
        _ = defaultDirectoryMigration
    }

    /// On-disk location of `file`.
    public func localURL(for file: ModelFile) -> URL {
        directory.appendingPathComponent(file.name)
    }

    /// Download source for `file`.
    public func remoteURL(for file: ModelFile) -> URL {
        remoteBase.appendingPathComponent(file.name)
    }

    /// True when `file` is present with exactly the expected byte size.
    public func isComplete(_ file: ModelFile) -> Bool {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: localURL(for: file).path),
            let size = attrs[.size] as? Int
        else { return false }
        return size == file.size
    }

    /// Files still missing or the wrong size — the set the downloader must fetch.
    public var missingFiles: [ModelFile] {
        files.filter { !isComplete($0) }
    }

    /// True when every file is present with the expected size.
    public var isComplete: Bool {
        missingFiles.isEmpty
    }

    /// Deletes this store's files and any half-downloaded `.part` next to them.
    /// Files that are already gone are not an error, so this is safe to repeat.
    public func remove() throws {
        let fm = FileManager.default
        for file in files {
            let url = localURL(for: file)
            for candidate in [url, url.appendingPathExtension("part")]
            where fm.fileExists(atPath: candidate.path) {
                try fm.removeItem(at: candidate)
            }
        }
    }
}
