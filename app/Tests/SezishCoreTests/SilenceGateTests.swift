import Foundation
import Testing
@testable import SezishCore

/// A take whose loudest 30 ms stays under -50 dBFS is not sent to the engine:
/// engines invent "thank you" on silence.
struct SilenceGateTests {
    private func tone(_ count: Int, amplitude: Float, offset: Float = 0) -> [Float] {
        (0..<count).map { offset + amplitude * sin(2 * .pi * 300 * Float($0) / 16_000) }
    }

    @Test func zerosAndAQuietRoomAreSilent() {
        #expect(SilenceGate.isNearSilent([Float](repeating: 0, count: 16_000)))
        #expect(SilenceGate.isNearSilent(tone(16_000, amplitude: 0.001))) // ≈ -63 dBFS
        #expect(SilenceGate.isNearSilent([]))
    }

    @Test func aWhisperIsNotSilent() {
        #expect(!SilenceGate.isNearSilent(tone(16_000, amplitude: 0.01))) // ≈ -43 dBFS
    }

    @Test func aMicrophoneOffsetIsNotSound() {
        #expect(SilenceGate.isNearSilent(tone(16_000, amplitude: 0.001, offset: 0.3)))
    }

    @Test func oneLoudWindowAnywhereCounts() {
        var take = [Float](repeating: 0, count: 32_000)
        let word = tone(480, amplitude: 0.02)
        take.replaceSubrange(20_000..<20_480, with: word)
        #expect(!SilenceGate.isNearSilent(take))
        #expect(SilenceGate.loudestWindowDBFS(take) > -40)
    }
}
