import Foundation
import Testing

@testable import SezishAsr

/// Dictation transcribes the take chunk by chunk while it is still being spoken, so the
/// streaming cutter has to land its boundaries exactly where `AudioChunker.split` lands them
/// over the finished recording: a boundary that moved would make the live transcript differ
/// from a retry of the same audio out of history.
@Suite("StreamCutter")
struct StreamCutterTests {
    private let limit = 100_000
    private let searchWindow = 20_000

    /// Loud enough that no probe window reads as silence, with two pauses to cut in.
    private func recording() -> [Float] {
        var samples = (0..<250_000).map {
            Float(0.4 * sin(2.0 * Double.pi * 220.0 * Double($0) / 16_000.0))
        }
        for gap in [85_000..<91_000, 178_000..<184_000] {
            for index in gap { samples[index] = 0 }
        }
        return samples
    }

    /// Pours the recording in `pieces` at a time, the way the mic tap does.
    private func fed(_ samples: [Float], pieces: Int) -> (chunks: [[Float]], rest: [Float]) {
        var cutter = StreamCutter(limit: limit, searchWindow: searchWindow)
        var chunks: [[Float]] = []
        for start in stride(from: 0, to: samples.count, by: pieces) {
            cutter.append(Array(samples[start..<min(start + pieces, samples.count)]))
            while let chunk = cutter.nextChunk() { chunks.append(chunk) }
        }
        return (chunks, cutter.takeRest())
    }

    @Test func streamedBoundariesMatchTheBatchSplit() {
        let samples = recording()

        let (chunks, rest) = fed(samples, pieces: 1_600) // 100 ms at 16 kHz

        let batch = AudioChunker.split(samples, limit: limit, searchWindow: searchWindow)
        #expect((chunks + [rest]).map(\.count) == batch.map(\.count))
    }

    /// Feed size must not matter: it never lines up with a boundary in the first place.
    @Test func everySampleComesOutOnceInOrder() {
        let samples = recording()

        let (chunks, rest) = fed(samples, pieces: 4_099)

        #expect(chunks.flatMap { $0 } + rest == samples)
    }

    /// A buffer that still fits one chunk can grow into the boundary, so nothing leaves yet.
    @Test func nothingIsHandedOverUntilTheLimitIsPassed() {
        var cutter = StreamCutter(limit: limit, searchWindow: searchWindow)

        cutter.append(Array(recording()[0..<limit]))

        #expect(cutter.nextChunk() == nil)
        #expect(cutter.takeRest().count == limit)
    }
}
