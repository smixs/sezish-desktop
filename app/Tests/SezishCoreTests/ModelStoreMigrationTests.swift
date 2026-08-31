import Foundation
import Testing
@testable import SezishCore

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sezish-migration-\(UUID().uuidString)", isDirectory: true)
}

private func write(_ byte: UInt8, count: Int, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(repeating: byte, count: count).write(to: url)
}

private func bytes(at url: URL) -> Data? {
    try? Data(contentsOf: url)
}

@Suite struct ModelStoreMigrationTests {
    @Test func oldOnlyMovesEverythingAndRemovesOld() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try write(1, count: 8, to: old.appendingPathComponent("weights.bin"))
        try write(2, count: 3, to: old.appendingPathComponent("vocab.txt"))

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(bytes(at: new.appendingPathComponent("weights.bin")) == Data(repeating: 1, count: 8))
        #expect(bytes(at: new.appendingPathComponent("vocab.txt")) == Data(repeating: 2, count: 3))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func newOnlyIsLeftUntouched() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try write(1, count: 8, to: new.appendingPathComponent("weights.bin"))

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(bytes(at: new.appendingPathComponent("weights.bin")) == Data(repeating: 1, count: 8))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func bothExistKeepsNewFillsGapsAndIsIdempotent() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try write(9, count: 5, to: old.appendingPathComponent("weights.bin")) // stale copy
        try write(7, count: 4, to: old.appendingPathComponent("vocab.txt"))   // missing in new
        try write(1, count: 8, to: new.appendingPathComponent("weights.bin")) // wins

        ModelStore.migrateLegacyDirectory(from: old, to: new)
        ModelStore.migrateLegacyDirectory(from: old, to: new) // second run: no-op, no crash

        #expect(bytes(at: new.appendingPathComponent("weights.bin")) == Data(repeating: 1, count: 8))
        #expect(bytes(at: new.appendingPathComponent("vocab.txt")) == Data(repeating: 7, count: 4))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func neitherExistsIsANoOp() {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    /// An upgrade in the middle of a download must carry the `.part` file over —
    /// otherwise the downloader restarts the 225 MB fetch from zero.
    @Test func partialDownloadSurvivesTheMove() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try write(3, count: 12, to: old.appendingPathComponent("multilingual_ctc.int8.onnx.part"))
        try write(2, count: 3, to: old.appendingPathComponent("vocab.txt"))

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(
            bytes(at: new.appendingPathComponent("multilingual_ctc.int8.onnx.part"))
                == Data(repeating: 3, count: 12)
        )
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// Some users relocate the model onto an external disk and leave a symlink
    /// behind. Whatever the move does with the link itself, the files must stay
    /// readable through the new path.
    @Test func symlinkedLegacyDirectoryStaysReadable() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = base.appendingPathComponent("elsewhere", isDirectory: true)
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try write(1, count: 8, to: real.appendingPathComponent("weights.bin"))
        try fm.createSymbolicLink(at: old, withDestinationURL: real)

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(bytes(at: new.appendingPathComponent("weights.bin")) == Data(repeating: 1, count: 8))
    }

    /// A legacy symlink whose target is gone must not abort or resurrect anything:
    /// the store simply downloads into the new directory.
    @Test func danglingLegacySymlinkIsIgnored() throws {
        let base = tmpDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let old = base.appendingPathComponent("Models", isDirectory: true)
        let new = base.appendingPathComponent(".models", isDirectory: true)
        try fm.createSymbolicLink(at: old, withDestinationURL: base.appendingPathComponent("gone"))

        ModelStore.migrateLegacyDirectory(from: old, to: new)

        #expect(!fm.fileExists(atPath: new.path))
    }

    @Test func defaultDirectoryIsHiddenNextToLegacyOne() {
        #expect(ModelStore.defaultDirectory.lastPathComponent == ".models")
        #expect(ModelStore.legacyDirectory.lastPathComponent == "Models")
        #expect(
            ModelStore.defaultDirectory.deletingLastPathComponent().path ==
            ModelStore.legacyDirectory.deletingLastPathComponent().path
        )
    }
}
