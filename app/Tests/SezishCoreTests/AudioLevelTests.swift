import Foundation
import Testing
@testable import SezishCore

struct AudioLevelTests {
    @Test func rmsOfSilenceIsZero() {
        #expect(AudioLevel.rms([]) == 0)
        #expect(AudioLevel.rms([0, 0, 0, 0]) == 0)
    }

    @Test func rmsOfFullScaleSineIsRootHalf() {
        let sine = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        #expect(abs(AudioLevel.rms(sine) - 0.7071) < 0.001)
    }

    @Test func normalizeClampsAndIsMonotonic() {
        #expect(AudioLevel.normalize(rms: 0) == 0)
        #expect(AudioLevel.normalize(rms: 1) == 1) // 0 dBFS sits above the -10 dB window top
        #expect(AudioLevel.normalize(rms: -1) == 0)
        #expect(AudioLevel.normalize(rms: 0.005) < AudioLevel.normalize(rms: 0.1))
    }

    @Test func normalizeSurvivesNonFiniteInput() {
        #expect(AudioLevel.normalize(rms: .nan) == 0)
        #expect(AudioLevel.normalize(rms: .infinity) == 0)
    }

    @Test func smootherAttacksFasterThanItReleases() {
        var rising = LevelSmoother()
        let risen = rising.step(target: 1, dt: 0.05)

        var falling = LevelSmoother()
        falling.step(target: 1, dt: 10) // saturate first
        let after = falling.step(target: 0, dt: 0.05)

        #expect(risen > 1 - after) // rise over 50 ms outpaces fall over the same 50 ms
    }

    @Test func smootherConvergesAndIgnoresZeroDt() {
        var s = LevelSmoother()
        s.step(target: 0.8, dt: 5)
        #expect(abs(s.value - 0.8) < 0.01)

        let before = s.value
        s.step(target: 0, dt: 0)
        #expect(s.value == before)
    }

    @Test func smootherClampsGarbageTargets() {
        var s = LevelSmoother()
        s.step(target: .nan, dt: 0.1)
        #expect(s.value.isFinite)
        s.step(target: 5, dt: 10)
        #expect(s.value <= 1)
    }
}
