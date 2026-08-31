import Foundation
import Testing
@testable import SezishAsr

/// Integration tests that exercise the real ONNX pipeline against the local HF cache.
/// They self-skip (return, no failure recorded) when the acoustic model is absent.
@Suite struct GigaAmIntegrationTests {
    static let modelPath =
        "/Users/shima/.cache/huggingface/hub/models--istupakov--gigaam-multilingual-ctc-onnx"
        + "/snapshots/458860e1983aef670dd9795fb6af603c82767d5d/multilingual_ctc.int8.onnx"

    /// Returns a transcriber, or `nil` when the cached model file is missing (test skipped).
    private func makeTranscriber() throws -> GigaAmTranscriber? {
        guard FileManager.default.fileExists(atPath: Self.modelPath) else {
            return nil // model not in HF cache: skip without recording an issue
        }
        return try GigaAmTranscriber(modelURL: URL(fileURLWithPath: Self.modelPath))
    }

    @Test func transcribesSilenceWithoutThrowing() async throws {
        guard let transcriber = try makeTranscriber() else { return }
        let silence = [Float](repeating: 0, count: 16_000) // 1 s @ 16 kHz

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await transcriber.transcribe(silence)
        let elapsed = clock.now - start

        print("[GigaAmIntegration] silence transcribe took \(elapsed), result=\"\(result)\"")
        // Pure silence should decode to (near-)empty text.
        #expect(result.count <= 4)
    }

    @Test func transcribesToneWithoutCrashing() async throws {
        guard let transcriber = try makeTranscriber() else { return }
        // 440 Hz sine wave, 1 s.
        let tone = (0..<16_000).map { i -> Float in
            Float(0.2 * sin(2.0 * Double.pi * 440.0 * Double(i) / 16_000.0))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await transcriber.transcribe(tone)
        let elapsed = clock.now - start

        print("[GigaAmIntegration] tone transcribe took \(elapsed), result=\"\(result)\"")
        // Only requirement: it ran end-to-end without crashing or throwing.
        #expect(result.count < 10_000)
    }

    @Test func warmupRunsWithoutThrowing() async throws {
        guard let transcriber = try makeTranscriber() else { return }
        let clock = ContinuousClock()
        let start = clock.now
        try await transcriber.warmup()
        print("[GigaAmIntegration] warmup took \(clock.now - start)")
    }
}
