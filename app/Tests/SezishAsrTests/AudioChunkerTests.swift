import Foundation
import Testing

@testable import SezishAsr

@Suite("AudioChunker")
struct AudioChunkerTests {
    /// Loud enough that no probe window reads as silence.
    private func speech(_ count: Int) -> [Float] {
        (0..<count).map { Float(0.4 * sin(2.0 * Double.pi * 220.0 * Double($0) / 16_000.0)) }
    }

    // MARK: - Boundaries

    @Test func emptyAudioProducesNoChunks() {
        #expect(AudioChunker.split([], limit: 1_000).isEmpty)
    }

    @Test func audioShorterThanTheLimitIsNotSplit() {
        let samples = speech(99_999)
        #expect(AudioChunker.split(samples, limit: 100_000) == [0..<99_999])
    }

    @Test func exactlyTheLimitIsNotSplit() {
        let samples = speech(100_000)
        #expect(AudioChunker.split(samples, limit: 100_000) == [0..<100_000])
    }

    @Test func oneSamplePastTheLimitIsSplit() {
        let samples = speech(100_001)
        let chunks = AudioChunker.split(samples, limit: 100_000, searchWindow: 20_000)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        #expect(chunks.last?.upperBound == 100_001)
    }

    // MARK: - Invariants

    @Test(arguments: [
        (0, 1_000), (1, 1_000), (999, 1_000), (1_000, 1_000), (1_001, 1_000),
        (7, 3), (250_000, 100_000), (1_000_000, 100_000), (333_333, 40_000),
        (2, 1), (100_000, 7),
    ])
    func chunksCoverEverySampleOnceInOrder(count: Int, limit: Int) {
        let samples = speech(count)
        let chunks = AudioChunker.split(samples, limit: limit, searchWindow: limit / 4)

        #expect(chunks.allSatisfy { $0.count <= limit })
        #expect(chunks.allSatisfy { !$0.isEmpty })
        // Contiguous from the first sample to the last: nothing dropped, nothing heard twice,
        // nothing reordered.
        #expect((chunks.first?.lowerBound ?? 0) == 0)
        #expect((chunks.last?.upperBound ?? 0) == count)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }

    // MARK: - Where the cut lands

    @Test func theCutLandsInTheSilenceBeforeTheLimit() throws {
        var samples = speech(250_000)
        let gap = 85_000..<91_000
        for index in gap { samples[index] = 0 }

        let chunks = AudioChunker.split(samples, limit: 100_000, searchWindow: 20_000)

        let cut = try #require(chunks.first?.upperBound)
        #expect(gap.contains(cut))
    }

    @Test func uninterruptedSpeechIsCutAtTheLimit() {
        let samples = speech(250_000)
        let chunks = AudioChunker.split(samples, limit: 100_000, searchWindow: 20_000)
        #expect(chunks.first?.upperBound == 100_000)
    }

    /// Silence outside the search window is not worth a chunk 40% shorter than it could be.
    @Test func silenceTooFarBackIsIgnored() {
        var samples = speech(250_000)
        for index in 40_000..<46_000 { samples[index] = 0 }

        let chunks = AudioChunker.split(samples, limit: 100_000, searchWindow: 20_000)

        #expect(chunks.first?.upperBound == 100_000)
    }

    /// Every boundary of a long recording gets its own quiet spot, not just the first one.
    @Test func everyBoundaryLooksForItsOwnSilence() {
        var samples = speech(300_000)
        let gaps = [88_000..<92_000, 186_000..<190_000]
        for gap in gaps { for index in gap { samples[index] = 0 } }

        let chunks = AudioChunker.split(samples, limit: 100_000, searchWindow: 20_000)

        #expect(chunks.count >= 3)
        #expect(gaps[0].contains(chunks[0].upperBound))
        #expect(gaps[1].contains(chunks[1].upperBound))
    }

    /// The shipped numbers: 180 s of audio per chunk, well under the 200 s the ONNX
    /// attention mask is baked for.
    @Test func theDefaultLimitStaysUnderTheModelCeiling() {
        #expect(AudioChunker.defaultLimit == 180 * 16_000)
        let chunks = AudioChunker.split(speech(16_000 * 200))
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= 200 * 16_000 })
    }
}
