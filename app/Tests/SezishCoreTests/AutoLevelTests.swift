import Foundation
import Testing
@testable import SezishCore

/// The auto level reads the speaker's recent peak as full and the room as silent,
/// so a quiet laptop microphone moves the wave as much as a close studio one.
struct AutoLevelTests {
    /// Speaks `seconds` of alternating syllables at `peak` dBFS over a room at
    /// `room` dBFS, ~12 Hz like the mic tap, and returns every level it produced.
    private func speak(_ auto: inout AutoLevel, peak: Float, room: Float, seconds: Float) -> [Float] {
        let dt: Float = 1.0 / 12
        var levels: [Float] = []
        var t: Float = 0
        while t < seconds {
            let syllable = Int(t * 4) % 2 == 0
            levels.append(auto.step(loudness: syllable ? peak : room, dt: dt))
            t += dt
        }
        return levels
    }

    @Test func aQuietAndALoudMicrophoneBothReachFull() {
        var quiet = AutoLevel()
        let quietLevels = speak(&quiet, peak: -40, room: -68, seconds: 3) // a quiet laptop mic; below ~-44 dB hex reads as noise
        var loud = AutoLevel()
        let loudLevels = speak(&loud, peak: -12, room: -50, seconds: 3)

        #expect(quietLevels.suffix(12).max()! > 0.9)
        #expect(loudLevels.suffix(12).max()! > 0.9)
    }

    @Test func theRoomReadsAsSilence() {
        var auto = AutoLevel()
        _ = speak(&auto, peak: -30, room: -55, seconds: 3)
        #expect(auto.level(loudness: -55) < 0.05)
    }

    @Test func thePeakReleasesSoAQuieterVoiceFillsAgain() {
        var auto = AutoLevel()
        _ = speak(&auto, peak: -10, room: -55, seconds: 2) // a shout first
        let right = auto.level(loudness: -30)
        _ = speak(&auto, peak: -30, room: -55, seconds: 6) // then normal talk
        let later = auto.level(loudness: -30)

        #expect(later > right + 0.3)
        #expect(later > 0.85)
    }

    @Test func silenceAndGarbageStayAtZero() {
        var auto = AutoLevel()
        #expect(auto.step(loudness: -.infinity, dt: 0.1) == 0)
        #expect(auto.step(loudness: .nan, dt: 0.1) == 0)
        #expect(auto.level(loudness: -120) == 0)
    }

    @Test func zeroDtLearnsNothing() {
        var auto = AutoLevel()
        let before = auto.level(loudness: -30)
        _ = auto.step(loudness: 0, dt: 0)
        #expect(auto.level(loudness: -30) == before)
    }

    @Test func rmsConvertsToDecibels() {
        #expect(AudioLevel.decibels(rms: 1) == 0)
        #expect(abs(AudioLevel.decibels(rms: 0.1) + 20) < 0.001)
        #expect(AudioLevel.decibels(rms: 0) == -120)
        #expect(AudioLevel.decibels(rms: .nan) == -120)
    }
}
