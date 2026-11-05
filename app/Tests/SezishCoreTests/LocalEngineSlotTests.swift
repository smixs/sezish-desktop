import Testing

@testable import SezishCore

/// One loaded copy of the local model for the whole app (specs/tla/LocalEngine.tla).
/// A copy is ~600 MB, so every second one is the memory the user saw «выжирает».
@Suite struct LocalEngineSlotTests {
    final class Engine {
        let key: String
        init(_ key: String) { self.key = key }
    }

    /// Counts loads, so a second copy shows up as a second call.
    final class Loader {
        var loads: [String] = []
        func load(_ key: String) -> Engine? {
            loads.append(key)
            return Engine(key)
        }
    }

    @Test func dictationAndMeetingShareOneCopy() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        let dictation = slot.engine(for: "ru") { loader.load("ru") }
        let rebuilt = slot.engine(for: "ru") { loader.load("ru") } // language, smart mode…
        let meeting = slot.pin(for: "ru") { loader.load("ru") }

        #expect(loader.loads == ["ru"])
        #expect(dictation === rebuilt)
        #expect(dictation === meeting)
    }

    @Test func anotherModelReplacesTheCopy() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        _ = slot.engine(for: "ru") { loader.load("ru") }
        let multi = slot.engine(for: "multi") { loader.load("multi") }

        #expect(loader.loads == ["ru", "multi"])
        #expect(slot.loadedKey == "multi")
        #expect(multi?.key == "multi")
    }

    /// The TLC counterexample: model there and back while a meeting runs on the first one.
    @Test func aMeetingsCopyIsReusedAfterSwitchingBack() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        let meeting = slot.pin(for: "ru") { loader.load("ru") }
        _ = slot.engine(for: "multi") { loader.load("multi") }
        let back = slot.engine(for: "ru") { loader.load("ru") }

        #expect(loader.loads == ["ru", "multi"])
        #expect(back === meeting)
    }

    @Test func cloudDictationLetsTheCopyGoAfterTheMeeting() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        _ = slot.pin(for: "ru") { loader.load("ru") }
        slot.releaseIfIdle(dictationIsLocal: false)
        #expect(slot.loadedKey == "ru") // the meeting still runs on it

        slot.unpin(dictationIsLocal: false)
        #expect(slot.loadedKey == nil)
    }

    @Test func localDictationKeepsTheCopy() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        _ = slot.engine(for: "ru") { loader.load("ru") }
        _ = slot.pin(for: "ru") { loader.load("ru") }
        slot.unpin(dictationIsLocal: true)
        slot.releaseIfIdle(dictationIsLocal: true)

        #expect(slot.loadedKey == "ru")
        #expect(loader.loads == ["ru"])
    }

    @Test func twoMeetingJobsHoldUntilBothEnd() {
        var slot = LocalEngineSlot<String, Engine>()
        let loader = Loader()

        _ = slot.pin(for: "ru") { loader.load("ru") } // live meeting
        _ = slot.pin(for: "ru") { loader.load("ru") } // retry of an older one
        slot.unpin(dictationIsLocal: false)
        #expect(slot.loadedKey == "ru")

        slot.unpin(dictationIsLocal: false)
        #expect(slot.loadedKey == nil)
        #expect(loader.loads == ["ru"])
    }

    @Test func aFailedLoadCachesNothing() {
        var slot = LocalEngineSlot<String, Engine>()
        var tries = 0

        #expect(slot.engine(for: "ru") { tries += 1; return nil } == nil)
        #expect(slot.engine(for: "ru") { tries += 1; return nil } == nil)

        #expect(tries == 2)
        #expect(slot.loadedKey == nil)
    }

    @Test func releaseWithoutMeetingInCloudModeFreesAtOnce() {
        var slot = LocalEngineSlot<String, Engine>()
        _ = slot.engine(for: "ru") { Engine("ru") }

        slot.releaseIfIdle(dictationIsLocal: false)

        #expect(slot.loadedKey == nil)
    }
}
