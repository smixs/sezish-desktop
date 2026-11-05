import Foundation
import Testing
@testable import SezishCore

struct WaveIntensityTests {
    @Test func defaultsToLivelyAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.waveIntensity == .lively)
        settings.waveIntensity = .bold
        #expect(AppSettings(defaults: defaults).waveIntensity == .bold)
        defaults.set("garbage", forKey: "waveIntensity")
        #expect(AppSettings(defaults: defaults).waveIntensity == .lively)
    }

    /// Each step up swings further, moves faster with the voice and reacts sooner.
    @Test func eachStepIsStrongerThanTheOneBelow() {
        let steps = WaveIntensity.allCases
        #expect(steps == [.calm, .lively, .bold])
        for (lower, higher) in zip(steps, steps.dropFirst()) {
            #expect(higher.swing > lower.swing)
            #expect(higher.speedGain > lower.speedGain)
            #expect(higher.attack < lower.attack)
        }
    }

    /// Bold doubles the tallest capsule at full voice; nothing collapses below a stub.
    @Test func boldReachesDoubleHeightAndNothingCollapses() {
        #expect(abs(WaveIntensity.bold.capsuleScale(level: 1, oscillation: 1) - 2) < 0.001)
        for intensity in WaveIntensity.allCases {
            #expect(intensity.capsuleScale(level: 1, oscillation: -1) >= 0.25)
            #expect(intensity.capsuleScale(level: 0, oscillation: 1) == 1) // silence rests
        }
    }

    /// Speed rises with the voice: the wave runs faster when someone talks louder.
    @Test func speedFollowsTheVoice() {
        for intensity in WaveIntensity.allCases {
            #expect(intensity.frequency(level: 1) > intensity.frequency(level: 0))
        }
    }
}
