import Foundation

public enum PCMSpoolError: Error, Equatable {
    case cannotOpen
    case badFormat
}

/// Incremental 16-bit mono WAV writer: header with zero sizes at open, chunk
/// appends, size patch on finalize. Keeps hour-long recording stems on disk
/// (~115 MB/h) instead of in RAM.
public final class PCMSpoolFile {
    private let handle: FileHandle
    private let sampleRate: Int
    private var frames = 0
    private var finalized = false

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw PCMSpoolError.cannotOpen
        }
        self.handle = handle
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    public func append(_ samples: [Float]) throws {
        guard !finalized, !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * Float(Int16.max)).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        frames += samples.count
    }

    /// Patches the RIFF/data sizes and closes the file. Returns total frames.
    @discardableResult
    public func finalize() throws -> Int {
        guard !finalized else { return frames }
        finalized = true
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: frames * 2))
        try handle.close()
        return frames
    }

    /// Rewrites the header of a spool orphaned by a crash. Sizes are patched
    /// only in `finalize()`, so a crash leaves intact PCM behind a header that
    /// claims `dataBytes = 0` and readers see an empty file — yet the sizes are
    /// recoverable from the file size alone. Returns the frame count, or nil if
    /// the file is unreadable or not one of our spools (then left untouched).
    /// Best-effort salvage path: never throws, never mutates on doubt.
    public static func repairHeader(url: URL) -> Int? {
        guard let handle = FileHandle(forUpdatingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        do {
            let fileSize = Int(try handle.seekToEnd())
            guard fileSize >= 44 else { return nil }
            try handle.seek(toOffset: 0)
            // Same strict layout checks as PCMSpoolReader: refuse to touch
            // anything we did not write ourselves.
            guard let header = try handle.read(upToCount: 44), header.count == 44,
                  header[0..<4].elementsEqual("RIFF".utf8),
                  header[8..<12].elementsEqual("WAVE".utf8),
                  header[12..<16].elementsEqual("fmt ".utf8),
                  header[20..<22].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 1,
                  header[22..<24].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 1,
                  header[34..<36].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 16,
                  header[36..<40].elementsEqual("data".utf8)
            else {
                return nil
            }
            // Carry the recorded rate over: spools are not always 16 kHz.
            let sampleRate = Int(header[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let storedBytes = Int(header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            // A crash can tear the trailing Int16 in half; half a sample is noise.
            let dataBytes = (fileSize - 44) & ~1
            guard storedBytes != dataBytes else { return dataBytes / 2 } // already consistent
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
            return dataBytes / 2
        } catch {
            return nil
        }
    }

    /// Standard 44-byte PCM16 mono WAV header.
    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: 44)
        func str(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)                     // PCM, mono
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)    // byte rate, block align, bits
        str("data"); u32(dataBytes)
        return data
    }
}

/// Reader for spools written by `PCMSpoolFile` (strict fixed 44-byte layout).
public final class PCMSpoolReader {
    private let handle: FileHandle
    public let frameCount: Int
    private var framesRead = 0

    public init(url: URL) throws {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw PCMSpoolError.cannotOpen
        }
        self.handle = handle
        guard let header = try handle.read(upToCount: 44), header.count == 44,
              header[0..<4].elementsEqual("RIFF".utf8),
              header[8..<12].elementsEqual("WAVE".utf8),
              header[12..<16].elementsEqual("fmt ".utf8),
              header[20..<22].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 1,
              header[22..<24].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 1,
              header[34..<36].withUnsafeBytes({ $0.loadUnaligned(as: UInt16.self) }).littleEndian == 16,
              header[36..<40].elementsEqual("data".utf8)
        else {
            throw PCMSpoolError.badFormat
        }
        let dataBytes = header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        frameCount = Int(dataBytes) / 2
    }

    /// Next chunk of frames as Float32 in [-1, 1]; nil at EOF.
    public func readChunk(maxFrames: Int) throws -> [Float]? {
        guard framesRead < frameCount else { return nil }
        let want = min(maxFrames, frameCount - framesRead)
        guard let data = try handle.read(upToCount: want * 2), !data.isEmpty else { return nil }
        let frames = data.count / 2
        framesRead += frames
        var out = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian
                out[i] = Float(v) / Float(Int16.max)
            }
        }
        return out
    }
}
