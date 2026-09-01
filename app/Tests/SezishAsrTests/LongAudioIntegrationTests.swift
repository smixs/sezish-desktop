import Foundation
import SezishCore
import Testing

@testable import SezishAsr

/// The two routes a long recording can take, against the real model and the real endpoint.
///
/// Both self-skip unless the environment points them at something, so a plain `swift test`
/// never touches the network or a 200 MB model:
///
///     SEZISH_LONG_WAV=<16 kHz mono wav> \
///     SEZISH_LOCAL_MODEL=<gigaam ctc onnx> \
///     SEZISH_LOCAL_VOCAB=<its token table, omitted for the bundled multilingual one> \
///     SEZISH_GEMINI_KEY=<key> swift test --filter LongAudio
@Suite struct LongAudioIntegrationTests {
    private func samples() throws -> [Float]? {
        guard let path = ProcessInfo.processInfo.environment["SEZISH_LONG_WAV"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        let reader = try PCMSpoolReader(url: URL(fileURLWithPath: path))
        var samples: [Float] = []
        samples.reserveCapacity(reader.frameCount)
        while let chunk = try reader.readChunk(maxFrames: 65_536) {
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// The bug: one tensor with more than 200 s in it throws inside ORT, and the user reads
    /// «Текст не распознался». Chunked, the same audio comes back as text.
    @Test func theLocalModelSwallowsARecordingPastTheAttentionCeiling() async throws {
        guard let samples = try samples(),
              let model = ProcessInfo.processInfo.environment["SEZISH_LOCAL_MODEL"],
              FileManager.default.fileExists(atPath: model) else { return }
        // Every model ships its own token table; the bundled one only fits the multilingual set.
        let vocab = try ProcessInfo.processInfo.environment["SEZISH_LOCAL_VOCAB"]
            .map { try Vocab(contentsOf: URL(fileURLWithPath: $0)) } ?? Vocab.bundled()
        let transcriber = GigaAmTranscriber(modelURL: URL(fileURLWithPath: model), vocab: vocab)

        let clock = ContinuousClock()
        let start = clock.now
        let text = try await transcriber.transcribe(samples)

        print("[LongAudio] local: \(samples.count / 16_000) s in \(clock.now - start), "
            + "\(text.count) chars\n\(text.prefix(200))")
        #expect(!text.isEmpty)
        #expect(text.count > 1_000) // a whole take, not the first chunk alone
    }

    /// The point of streaming: the same recording fed in at the mic's cadence has to come back
    /// as the text the batch pass produces, with the wait paid while it was still being spoken.
    @Test func theStreamingPathMatchesTheBatchPass() async throws {
        guard let samples = try samples(),
              let model = ProcessInfo.processInfo.environment["SEZISH_LOCAL_MODEL"],
              FileManager.default.fileExists(atPath: model) else { return }
        let vocab = try ProcessInfo.processInfo.environment["SEZISH_LOCAL_VOCAB"]
            .map { try Vocab(contentsOf: URL(fileURLWithPath: $0)) } ?? Vocab.bundled()
        let transcriber = GigaAmTranscriber(modelURL: URL(fileURLWithPath: model), vocab: vocab)

        await transcriber.startStream()
        for start in stride(from: 0, to: samples.count, by: 1_600) { // 100 ms per feed
            transcriber.feed(Array(samples[start..<min(start + 1_600, samples.count)]))
            await Task.yield() // let the actor drain what is ready, as it would live
        }
        let clock = ContinuousClock()
        let released = clock.now
        let streamed = try await transcriber.finishStream()
        let tail = clock.now - released
        let batch = try await transcriber.transcribe(samples)

        print("[LongAudio] streamed: \(samples.count / 16_000) s, tail took \(tail), "
            + "\(streamed.count) chars\n\(streamed.prefix(200))")
        #expect(!streamed.isEmpty)
        #expect(streamed == batch)
    }

    /// The other half of the bug: the same audio poured into the Live socket gets the session
    /// killed with «Resource has been exhausted». Over the batch endpoint it comes back whole.
    @Test func theBatchRouteTranscribesTheSameRecording() async throws {
        guard let samples = try samples(),
              let key = ProcessInfo.processInfo.environment["SEZISH_GEMINI_KEY"] else { return }
        let transcriber = GeminiLiveTranscriber(apiKey: key, mode: .smart)

        let clock = ContinuousClock()
        let start = clock.now
        let text = try await transcriber.transcribe(samples)

        print("[LongAudio] batch: \(samples.count / 16_000) s in \(clock.now - start), "
            + "\(text.count) chars\n\(text.prefix(200))")
        #expect(!text.isEmpty)
        #expect(text.count > 1_000)
    }
}
