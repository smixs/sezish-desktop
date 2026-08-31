import Foundation

public enum DictationHistoryError: Error, Equatable {
    case unknownRecord
    case noAudio
}

/// FIFO store of the last `maxCount` dictations. Metadata lives in `index.json`;
/// each dictation's audio is a sibling `.wav`. Adding past the cap drops the oldest
/// record and deletes its `.wav` from disk. The directory is injected (temp dir in tests).
/// Takes without a transcript are outside the cap: they are the only ones still worth
/// recovering, so they stay until a retry succeeds or the user deletes them.
public final class DictationHistory {
    public private(set) var records: [DictationRecord] = []

    private let directory: URL
    private let maxCount: Int
    private let indexURL: URL

    public init(directory: URL, maxCount: Int = 10) throws {
        self.directory = directory
        self.maxCount = maxCount
        self.indexURL = directory.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.records = Self.load(from: indexURL)
    }

    @discardableResult
    public func add(
        text: String, samples16k: [Float], engine: String? = nil, error: String? = nil
    ) throws -> DictationRecord {
        let id = UUID()
        let audioURL = directory.appendingPathComponent("\(id.uuidString).wav")
        try WAVFile.write(samples16k, to: audioURL)
        let record = DictationRecord(
            id: id, date: Date(), text: text, audioURL: audioURL, engine: engine, error: error)
        records.append(record)
        try evictOverflow()
        try persist()
        return record
    }

    /// Replaces the transcript of a stored take, keeping its id, date and audio: after a
    /// retry it is the same take, only better known.
    public func update(id: UUID, text: String, engine: String?, error: String?) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw DictationHistoryError.unknownRecord
        }
        let old = records[index]
        records[index] = DictationRecord(
            id: old.id, date: old.date, text: text, audioURL: old.audioURL,
            engine: engine, error: error)
        // The updated record is the oldest one with text, so plain eviction would drop it
        // and its audio the moment the retry succeeded. The next add treats it normally.
        try evictOverflow(keeping: id)
        try persist()
    }

    /// Drops the record and its audio. A `.wav` that is already gone is not an error:
    /// what matters is that the entry is gone afterwards.
    public func remove(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw DictationHistoryError.unknownRecord
        }
        let removed = records.remove(at: index)
        if let url = removed.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        try persist()
    }

    /// The stored audio back as 16 kHz mono samples, ready to be transcribed again.
    public func samples(of record: DictationRecord) throws -> [Float] {
        guard let url = record.audioURL else { throw DictationHistoryError.noAudio }
        let reader = try PCMSpoolReader(url: url)
        var samples = [Float]()
        samples.reserveCapacity(reader.frameCount)
        while let chunk = try reader.readChunk(maxFrames: 65_536) {
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    private func evictOverflow(keeping protected: UUID? = nil) throws {
        func counts(_ record: DictationRecord) -> Bool {
            !record.needsTranscript && record.id != protected
        }
        while records.filter(counts).count > maxCount,
              let index = records.firstIndex(where: counts) {
            let evicted = records.remove(at: index)
            if let url = evicted.audioURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func load(from url: URL) -> [DictationRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DictationRecord].self, from: data)
        else { return [] }
        return decoded
    }
}

/// Minimal 16-bit PCM mono WAV encoder (16 kHz by default).
private enum WAVFile {
    static func write(_ samples: [Float], to url: URL, sampleRate: Int = 16_000) throws {
        let dataSize = samples.count * 2
        var out = Data(capacity: 44 + dataSize)
        out.append(ascii: "RIFF")
        out.append(uint32: UInt32(36 + dataSize))
        out.append(ascii: "WAVE")
        out.append(ascii: "fmt ")
        out.append(uint32: 16)                       // PCM subchunk size
        out.append(uint16: 1)                        // audio format: PCM
        out.append(uint16: 1)                        // channels: mono
        out.append(uint32: UInt32(sampleRate))
        out.append(uint32: UInt32(sampleRate * 2))   // byte rate
        out.append(uint16: 2)                        // block align
        out.append(uint16: 16)                       // bits per sample
        out.append(ascii: "data")
        out.append(uint32: UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * Float(Int16.max))
            out.append(uint16: UInt16(bitPattern: value))
        }
        try out.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
