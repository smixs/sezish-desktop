import Foundation
import Testing
@testable import SezishCore

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sezish-store-\(UUID().uuidString)", isDirectory: true)
}

private let fixtureFiles = [
    ModelFile(name: "weights.bin", size: 8),
    ModelFile(name: "vocab.txt", size: 3),
]

@Suite struct ModelStoreTests {
    @Test func emptyDirectoryIsNotComplete() {
        let store = ModelStore(root: tmpDir(), files: fixtureFiles)
        #expect(store.isComplete == false)
        #expect(store.missingFiles == fixtureFiles)
    }

    @Test func fullDirectoryIsComplete() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8).write(to: dir.appendingPathComponent("weights.bin"))
        try Data(repeating: 0, count: 3).write(to: dir.appendingPathComponent("vocab.txt"))

        let store = ModelStore(root: dir, files: fixtureFiles)
        #expect(store.isComplete == true)
        #expect(store.missingFiles.isEmpty)
    }

    @Test func wrongSizeCountsAsMissing() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 7).write(to: dir.appendingPathComponent("weights.bin")) // 7 != 8
        try Data(repeating: 0, count: 3).write(to: dir.appendingPathComponent("vocab.txt"))

        let store = ModelStore(root: dir, files: fixtureFiles)
        #expect(store.isComplete == false)
        #expect(store.missingFiles == [fixtureFiles[0]])
    }

    @Test func urlsAreDerivedFromNames() {
        let store = ModelStore(root: URL(fileURLWithPath: "/tmp/models"), files: fixtureFiles)
        #expect(store.localURL(for: fixtureFiles[0]).path == "/tmp/models/weights.bin")
        #expect(
            store.remoteURL(for: fixtureFiles[0]).absoluteString ==
            "https://huggingface.co/istupakov/gigaam-multilingual-ctc-onnx/resolve/main/weights.bin"
        )
    }

    @Test func eachModelHasItsOwnFilesAndSource() {
        let root = URL(fileURLWithPath: "/tmp/models")
        let multilingual = ModelStore(model: .multilingual, root: root)
        let punctuated = ModelStore(model: .ruEnPunctuated, root: root)

        #expect(multilingual.files == ModelStore.gigaamFiles)
        #expect(multilingual.remoteBase == ModelStore.defaultRemoteBase)
        #expect(punctuated.remoteBase.absoluteString == "https://dl.sezi.sh/models/")
        #expect(Set(multilingual.files.map(\.name)).isDisjoint(with: punctuated.files.map(\.name)))

        for model in AsrModel.allCases {
            #expect(model.files.filter { $0.name.hasSuffix(".onnx") } == [model.onnxFile])
            #expect(model.files.contains(model.vocabFile))
            #expect(model.downloadBytes == model.files.reduce(0) { $0 + $1.size })
        }
    }

    @Test func removeDeletesFilesAndPartsAndIsIdempotent() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8).write(to: dir.appendingPathComponent("weights.bin"))
        try Data(repeating: 0, count: 2).write(to: dir.appendingPathComponent("vocab.txt.part"))
        try Data(repeating: 0, count: 1).write(to: dir.appendingPathComponent("other.bin"))

        let store = ModelStore(root: dir, files: fixtureFiles)
        try store.remove()
        try store.remove()

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["other.bin"])
        #expect(store.missingFiles == fixtureFiles)
    }
}
