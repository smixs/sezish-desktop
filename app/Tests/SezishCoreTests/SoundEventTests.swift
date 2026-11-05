import Foundation
import Testing
@testable import SezishCore

/// One brand sound per event; a dictation's ending picks its own.
struct SoundEventTests {
    @Test func everyEventHasItsOwnResource() {
        let names = SoundEvent.allCases.map(\.resourceName)
        #expect(names == ["sound-start", "sound-stop", "sound-done", "sound-cancel",
                          "sound-error", "sound-meeting-start", "sound-meeting-stop"])
    }

    @Test func aDictationEndingSoundsByItsOutcome() {
        #expect(SoundEvent.after(.inserted) == .done)
        #expect(SoundEvent.after(.insertFailed("⌘V")) == .error)
        #expect(SoundEvent.after(.noText) == .error)
        #expect(SoundEvent.after(.failed) == .error)
        #expect(SoundEvent.after(.ignored) == nil)
    }

    @Test func volumeDefaultsToHalfAndStaysInRange() {
        let defaults = UserDefaults(suiteName: "sound-volume-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.soundVolume == 0.5)
        settings.soundVolume = 0.2
        #expect(settings.soundVolume == 0.2)
        settings.soundVolume = 3
        #expect(settings.soundVolume == 1)
        settings.soundVolume = -1
        #expect(settings.soundVolume == 0)
    }
}
