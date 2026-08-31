import AVFoundation
import Foundation
import Testing

@testable import SezishAsr

@Suite("CloudTranscriber AAC encoding")
struct CloudTranscriberTests {
    /// 1 s of 440 Hz sine at 16 kHz.
    private var tone: [Float] {
        (0..<16_000).map { sin(Float($0) * 2 * .pi * 440 / 16_000) * 0.5 }
    }

    @Test func encodesCompactAdtsStream() throws {
        let data = try CloudTranscriber.aacData(tone)
        // ADTS sync word at stream start.
        #expect(data[0] == 0xFF)
        #expect(data[1] & 0xF0 == 0xF0)
        // 32 kbps × 1 s ≈ 4 KB (+ headers); WAV would be 32 KB, AVAudioFile m4a ~26 KB.
        #expect(data.count > 500 && data.count < 10_000)
    }

    @Test func roundTripsThroughAVAudioFile() throws {
        let data = try CloudTranscriber.aacData(tone)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("aac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 1.0) < 0.2) // AAC priming/padding shifts length slightly
    }
}
