import Foundation
import Testing
@testable import SezishCore

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sezish-history-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct DictationHistoryTests {
    @Test func emptyHistoryStartsEmpty() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        #expect(history.records.isEmpty)
    }

    @Test func addAppendsRecordAndWritesWav() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let rec = try history.add(text: "привет", samples16k: [0.1, 0.2, 0.3])
        #expect(history.records.count == 1)
        #expect(rec.text == "привет")
        let wav = try #require(rec.audioURL)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func fifoEvictsOldestAndDeletesWavFromDisk() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        var first: DictationRecord?
        for i in 0..<11 {
            let r = try history.add(text: "rec\(i)", samples16k: [Float(i) * 0.01, 0.0])
            if i == 0 { first = r }
        }
        #expect(history.records.count == 10)
        #expect(history.records.first?.text == "rec1")
        #expect(history.records.last?.text == "rec10")
        let evictedWav = try #require(first?.audioURL)
        #expect(!FileManager.default.fileExists(atPath: evictedWav.path))
    }

    @Test func persistenceReloadsFromDisk() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let writer = try DictationHistory(directory: dir)
            try writer.add(text: "persisted", samples16k: [0.5, -0.5])
        }
        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.count == 1)
        #expect(reopened.records.first?.text == "persisted")
    }

    // MARK: - Engine provenance

    @Test func engineIsStoredAndReloadsFromDisk() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let writer = try DictationHistory(directory: dir)
            try writer.add(text: "с сервера", samples16k: [0.5, -0.5], engine: "cloud")
        }
        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.first?.engine == "cloud")
    }

    @Test func addWithoutEngineRoundTripsAsNil() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let rec = try history.add(text: "без движка", samples16k: [0.1, 0.2])
        #expect(rec.engine == nil)
        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.first?.engine == nil)
    }

    /// An index.json written before the field existed must still load: the key is simply
    /// absent, so it decodes to nil and the rest of the record survives untouched.
    @Test func indexWrittenWithoutEngineStillDecodes() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original: DictationRecord
        do {
            let writer = try DictationHistory(directory: dir)
            original = try writer.add(text: "старая запись", samples16k: [0.5, -0.5], engine: "cloud")
        }
        // Strip the key from what we just encoded — cheaper and truer than hand-writing JSON.
        let indexURL = dir.appendingPathComponent("index.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: indexURL))
        var entries = try #require(raw as? [[String: Any]])
        for i in entries.indices { entries[i].removeValue(forKey: "engine") }
        try JSONSerialization.data(withJSONObject: entries).write(to: indexURL, options: .atomic)

        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.count == 1)
        let restored = try #require(reopened.records.first)
        #expect(restored.engine == nil)
        #expect(restored.text == "старая запись")
        #expect(abs(restored.date.timeIntervalSince(original.date)) < 0.001)
    }

    // MARK: - Failure reason

    @Test func errorRoundTripsThroughIndex() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let writer = try DictationHistory(directory: dir)
            try writer.add(text: "", samples16k: [0.1, 0.2], engine: "cloud", error: "сеть недоступна")
        }
        let reopened = try DictationHistory(directory: dir)
        let restored = try #require(reopened.records.first)
        #expect(restored.error == "сеть недоступна")
        #expect(restored.needsTranscript)
    }

    /// Same trick as the engine test: an index.json written before the field existed
    /// simply has no key, so it must decode with error == nil.
    @Test func indexWithoutErrorStillDecodes() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let writer = try DictationHistory(directory: dir)
            try writer.add(text: "старая запись", samples16k: [0.5, -0.5], engine: "cloud", error: "boom")
        }
        let indexURL = dir.appendingPathComponent("index.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: indexURL))
        var entries = try #require(raw as? [[String: Any]])
        #expect(entries.first?["error"] as? String == "boom") // the key must be there to strip
        for i in entries.indices { entries[i].removeValue(forKey: "error") }
        try JSONSerialization.data(withJSONObject: entries).write(to: indexURL, options: .atomic)

        let reopened = try DictationHistory(directory: dir)
        let restored = try #require(reopened.records.first)
        #expect(restored.error == nil)
        #expect(restored.text == "старая запись")
        #expect(!restored.needsTranscript)
    }

    // MARK: - Update

    @Test func updateReplacesTextEngineErrorAndPersists() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let rec = try history.add(text: "", samples16k: [0.1, 0.2], engine: "cloud", error: "сеть недоступна")

        try history.update(id: rec.id, text: "готово", engine: "local", error: nil)

        let updated = try #require(history.records.first)
        #expect(history.records.count == 1)
        #expect(updated.id == rec.id)
        #expect(updated.text == "готово")
        #expect(updated.engine == "local")
        #expect(updated.error == nil)
        #expect(updated.audioURL == rec.audioURL)
        #expect(abs(updated.date.timeIntervalSince(rec.date)) < 0.001)
        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.first?.text == "готово")
    }

    @Test func updateUnknownIdThrows() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        #expect(throws: DictationHistoryError.unknownRecord) {
            try history.update(id: UUID(), text: "готово", engine: nil, error: nil)
        }
    }

    // MARK: - Remove

    @Test func removeDeletesWavAndRecord() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let kept = try history.add(text: "остаётся", samples16k: [0.1, 0.2])
        let doomed = try history.add(text: "удаляется", samples16k: [0.3, 0.4])
        let wav = try #require(doomed.audioURL)

        try history.remove(id: doomed.id)

        #expect(history.records.map(\.id) == [kept.id])
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        let reopened = try DictationHistory(directory: dir)
        #expect(reopened.records.map(\.id) == [kept.id])
        #expect(throws: DictationHistoryError.unknownRecord) {
            try history.remove(id: doomed.id)
        }
    }

    @Test func removeIsFineWhenWavAlreadyGone() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let rec = try history.add(text: "без аудио", samples16k: [0.1, 0.2])
        try FileManager.default.removeItem(at: try #require(rec.audioURL))

        try history.remove(id: rec.id)
        #expect(history.records.isEmpty)
    }

    // MARK: - Samples

    /// Property: what goes into the WAV comes back out, within one 16-bit step.
    /// Anchors next to it: silence of the exact minimum length, and an empty take.
    @Test func samplesRoundTripThroughWav() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        var rng = SplitMix64(seed: 0x5E21_5170)

        var noisy = [Float]()
        for _ in 0..<200_000 { noisy.append(Float.random(in: -1...1, using: &rng)) }
        let step = 1.0 / 32767.0

        for original in [noisy, [Float](repeating: 0, count: 4_800), []] {
            let rec = try history.add(text: "x", samples16k: original)
            let restored = try history.samples(of: rec)
            #expect(restored.count == original.count)
            var worst = 0.0
            for (a, b) in zip(original, restored) { worst = max(worst, abs(Double(a) - Double(b))) }
            #expect(worst <= step)
        }
    }

    @Test func samplesWithoutAudioThrows() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let record = DictationRecord(text: "нет файла", audioURL: nil)
        #expect(throws: DictationHistoryError.noAudio) {
            _ = try history.samples(of: record)
        }
    }

    // MARK: - Eviction with failed takes

    @Test func evictionSkipsRecordsWithoutText() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        var failed: [DictationRecord] = []
        for i in 0..<2 {
            failed.append(try history.add(text: "", samples16k: [Float(i) * 0.01, 0.0], error: "boom"))
        }
        for i in 0..<11 {
            try history.add(text: "rec\(i)", samples16k: [Float(i) * 0.01, 0.0])
        }

        #expect(history.records.count == 12)
        #expect(history.records.prefix(2).map(\.id) == failed.map(\.id))
        #expect(history.records.dropFirst(2).map(\.text) == (1...10).map { "rec\($0)" })
        for record in failed {
            let wav = try #require(record.audioURL)
            #expect(FileManager.default.fileExists(atPath: wav.path))
        }
    }

    /// The record being updated must not evict itself: it is the oldest one with text
    /// the moment it gets some, and taking its WAV away would defeat the retry.
    @Test func updateDoesNotEvictTheUpdatedRecord() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = try DictationHistory(directory: dir)
        let failed = try history.add(text: "", samples16k: [0.1, 0.2], error: "boom")
        for i in 0..<10 {
            try history.add(text: "rec\(i)", samples16k: [Float(i) * 0.01, 0.0])
        }

        try history.update(id: failed.id, text: "перегнали", engine: "local", error: nil)

        #expect(history.records.count == 11)
        #expect(history.records.first?.id == failed.id)
        let failedWav = try #require(failed.audioURL)
        #expect(FileManager.default.fileExists(atPath: failedWav.path))

        // Now it is an ordinary record: the next add pushes it out like any other, and the
        // cap it was held above is enforced again (11 with text + 1 new → back to 10).
        try history.add(text: "новая", samples16k: [0.5, 0.5])
        #expect(history.records.count == 10)
        #expect(history.records.map(\.text) == (1...9).map { "rec\($0)" } + ["новая"])
        #expect(!history.records.contains { $0.id == failed.id })
        #expect(!FileManager.default.fileExists(atPath: failedWav.path))
    }
}

/// Seeded so a failing sample is reproducible; the generator in SezishAsrTests is
/// private to that target, and 10 lines are cheaper than sharing one.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
