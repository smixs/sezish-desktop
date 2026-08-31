import Foundation
import Testing
@testable import SezishCore

struct MeetingDebounceTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func startsOnlyAfterSustainedSignal() {
        var d = MeetingDebounce(startAfter: 2, stopAfter: 10)
        #expect(d.tick(externalMicActive: true, at: t0) == nil)
        #expect(d.tick(externalMicActive: true, at: t0 + 1) == nil)
        #expect(d.tick(externalMicActive: true, at: t0 + 2) == .start)
        #expect(d.tick(externalMicActive: true, at: t0 + 3) == nil) // no repeat
    }

    @Test func flappingNeverStarts() {
        var d = MeetingDebounce(startAfter: 2, stopAfter: 10)
        #expect(d.tick(externalMicActive: true, at: t0) == nil)
        #expect(d.tick(externalMicActive: false, at: t0 + 1) == nil) // reset
        #expect(d.tick(externalMicActive: true, at: t0 + 2) == nil)  // candidate anew
        #expect(d.tick(externalMicActive: true, at: t0 + 3) == nil)  // only 1s held
    }

    @Test func stopsAfterSilenceWindow() {
        var d = MeetingDebounce(startAfter: 2, stopAfter: 10)
        d.tick(externalMicActive: true, at: t0)
        d.tick(externalMicActive: true, at: t0 + 2)
        #expect(d.tick(externalMicActive: false, at: t0 + 5) == nil)
        #expect(d.tick(externalMicActive: false, at: t0 + 10) == nil) // 5s of silence
        #expect(d.tick(externalMicActive: false, at: t0 + 15) == .stop)
    }

    @Test func dropoutShorterThanWindowKeepsRecording() {
        var d = MeetingDebounce(startAfter: 2, stopAfter: 10)
        d.tick(externalMicActive: true, at: t0)
        d.tick(externalMicActive: true, at: t0 + 2)
        #expect(d.tick(externalMicActive: false, at: t0 + 5) == nil)  // AirPods blip
        #expect(d.tick(externalMicActive: true, at: t0 + 8) == nil)   // back — no new .start
        #expect(d.tick(externalMicActive: false, at: t0 + 20) == nil)
        #expect(d.tick(externalMicActive: false, at: t0 + 31) == .stop)
    }
}

struct MeetingDetectionPolicyTests {
    private let policy = MeetingDetectionPolicy(ownBundleID: "com.smixs.sezish")

    @Test func anyBrowserHelperIsACall() {
        // Dia ships Arc's helper ids; Chrome/Safari helpers differ in case from
        // their main app. None of that matters any more: a full-duplex helper is a call.
        #expect(policy.classify("company.thebrowser.browser.helper") == .record)
        #expect(policy.classify("com.google.Chrome.helper") == .record)
        #expect(policy.classify("com.apple.WebKit.GPU") == .record)
    }

    @Test func callAppsAndUnknownAppsRecord() {
        #expect(policy.classify("us.zoom.xos") == .record)
        #expect(policy.classify("ru.keepcoder.Telegram") == .record)
        #expect(policy.classify("ai.some-new-call-tool.app") == .record)
    }

    @Test func dictationAndOwnProcessAreDenied() {
        #expect(policy.classify("com.smixs.sezish") == .deny)
        #expect(policy.classify("COM.SMIXS.SEZISH.helper") == .deny)
        #expect(policy.classify("com.electron.wispr-flow") == .deny)
        #expect(policy.classify("com.superduper.superwhisper") == .deny)
        #expect(policy.classify("com.fluidvoice.FluidVoice") == .deny)
        #expect(policy.classify("com.raycast.macos") == .deny)
        #expect(policy.classify("com.todesktop.230313mzl4w4u92") == .deny)
    }

    @Test func recordersAndDAWsAreDenied() {
        #expect(policy.classify("com.obsproject.obs-studio") == .deny)
        #expect(policy.classify("com.loom.desktop") == .deny)
        #expect(policy.classify("com.apple.logic10") == .deny)
        #expect(policy.classify("com.ableton.live") == .deny)
        #expect(policy.classify("com.cockos.reaper") == .deny)
    }

    @Test func extraDenySilencesAnything() {
        let p = MeetingDetectionPolicy(
            ownBundleID: "com.smixs.sezish", extraDenyPrefixes: ["com.slack.Slack"])
        #expect(p.classify("com.slack.Slack") == .deny)
        #expect(p.classify("com.slack.slack.helper") == .deny)
    }

    @Test func candidateSkipsDenyHolders() {
        let ids = ["com.electron.wispr-flow", "com.google.Chrome.helper", "us.zoom.xos"]
        #expect(policy.candidate(among: ids)?.bundleID == "com.google.Chrome.helper")
    }

    @Test func denyOnlyHoldersYieldNoCandidate() {
        #expect(policy.candidate(among: ["com.smixs.sezish", "com.electron.wispr-flow"]) == nil)
        #expect(policy.candidate(among: []) == nil)
    }
}

struct MeetingTranscriptionRuleTests {
    @Test func shortRecordingsAreNotTranscribed() {
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 0))
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 59.9))
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 60))
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 3600))
    }
}

struct AudioMixdownTests {
    @Test func lengthIsMaxAndShorterIsPadded() {
        let mixed = AudioMixdown.mix([0.1, 0.1, 0.1][...], [0.2][...])
        #expect(mixed.count == 3)
        #expect(abs(mixed[1] - AudioMixdown.softClip(0.1)) < 1e-6)
    }

    @Test func outputAlwaysWithinBounds() {
        // tanh is mathematically < 1, but Float rounding lands exactly on 1.0
        // for large inputs — the guarantee that matters is no overshoot.
        let mixed = AudioMixdown.mix([1.0, -1.0, 5.0][...], [1.0, -1.0, 5.0][...])
        #expect(mixed.allSatisfy { abs($0) <= 1 })
    }

    @Test func silencePlusSignalIsTransparentAtSpeechLevels() {
        let mixed = AudioMixdown.mix([0.1][...], [0][...])
        #expect(abs(mixed[0] - 0.1) < 0.001) // tanh(0.1) ≈ 0.0997
    }

    @Test func softClipIsMonotonic() {
        let xs: [Float] = [-2, -1, -0.5, 0, 0.5, 1, 2]
        let ys = xs.map(AudioMixdown.softClip)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
    }
}

struct PCMSpoolFileTests {
    @Test func roundTripsChunksThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let spool = try PCMSpoolFile(url: url)
        try spool.append([0.5, -0.5])
        try spool.append([0.25])
        #expect(try spool.finalize() == 3)

        let reader = try PCMSpoolReader(url: url)
        #expect(reader.frameCount == 3)
        let first = try reader.readChunk(maxFrames: 2)
        #expect(first?.count == 2)
        #expect(abs(first![0] - 0.5) < 0.001)
        #expect(abs(first![1] + 0.5) < 0.001)
        let second = try reader.readChunk(maxFrames: 2)
        #expect(second?.count == 1)
        #expect(try reader.readChunk(maxFrames: 2) == nil) // EOF
    }

    @Test func rejectsGarbageFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).wav")
        try Data(repeating: 7, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PCMSpoolError.badFormat) { try PCMSpoolReader(url: url) }
    }

    // Inner scope so ARC releases the spool: its FileHandle deinit closes the
    // fd without patching the header — exactly what a crash leaves behind.
    private func dropSpoolWithoutFinalize(url: URL, samples: [Float]) throws {
        let spool = try PCMSpoolFile(url: url)
        try spool.append(samples)
    }

    @Test func repairsCrashedSpool() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashed-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try dropSpoolWithoutFinalize(url: url, samples: [Float](repeating: 0.5, count: 1000))

        #expect(try PCMSpoolReader(url: url).frameCount == 0) // header still says empty
        #expect(PCMSpoolFile.repairHeader(url: url) == 1000)

        let reader = try PCMSpoolReader(url: url)
        #expect(reader.frameCount == 1000)
        let chunk = try reader.readChunk(maxFrames: 1000)
        #expect(chunk?.count == 1000)
        #expect(abs(chunk![999] - 0.5) < 0.001)
    }

    @Test func repairIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashed-twice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try dropSpoolWithoutFinalize(url: url, samples: [Float](repeating: 0.5, count: 1000))

        #expect(PCMSpoolFile.repairHeader(url: url) == 1000)
        let after = try Data(contentsOf: url)
        #expect(PCMSpoolFile.repairHeader(url: url) == 1000)
        #expect(try Data(contentsOf: url) == after) // second pass writes nothing
    }

    @Test func repairLeavesFinalizedSpoolAlone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalized-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let spool = try PCMSpoolFile(url: url)
        try spool.append([Float](repeating: 0.25, count: 1000))
        #expect(try spool.finalize() == 1000)

        let before = try Data(contentsOf: url)
        #expect(PCMSpoolFile.repairHeader(url: url) == 1000)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func repairLeavesGarbageUntouched() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-repair-\(UUID().uuidString).wav")
        try Data(repeating: 7, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try Data(contentsOf: url)
        #expect(PCMSpoolFile.repairHeader(url: url) == nil)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func repairRejectsTooShortFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("short-\(UUID().uuidString).wav")
        try Data(repeating: 7, count: 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PCMSpoolFile.repairHeader(url: url) == nil)
    }

    @Test func repairsHeaderOnlySpool() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("header-only-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try dropSpoolWithoutFinalize(url: url, samples: [])

        #expect(try Data(contentsOf: url).count == 44)
        #expect(PCMSpoolFile.repairHeader(url: url) == 0)
    }

    @Test func repairTruncatesTornOddByte() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("torn-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try dropSpoolWithoutFinalize(url: url, samples: [Float](repeating: 0.5, count: 1000))

        // Half of an Int16 flushed before the crash: unreadable, drop it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7F]))
        try handle.close()

        #expect(PCMSpoolFile.repairHeader(url: url) == 1000)
        let reader = try PCMSpoolReader(url: url)
        #expect(reader.frameCount == 1000)
        #expect(try reader.readChunk(maxFrames: 2000)?.count == 1000)
    }
}

struct MeetingFileNamerTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // Round-trip through the same calendar: no hand-computed epoch math.
    private var date: Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 21, minute: 33))!
    }

    @Test func formatsAsciiName() {
        let name = MeetingFileNamer.baseName(for: date, calendar: utc)
        #expect(name == "call-2026-07-13-21-33")
        #expect(name.allSatisfy { $0.isASCII })
    }

    @Test func resolvesCollisions() {
        let taken: Set<String> = ["call-2026-07-13-21-33", "call-2026-07-13-21-33-2"]
        let name = MeetingFileNamer.uniqueBaseName(for: date, calendar: utc) { taken.contains($0) }
        #expect(name == "call-2026-07-13-21-33-3")
    }

    @Test func readsTheDateBackFromTheName() {
        #expect(MeetingFileNamer.baseName(for: date, calendar: utc) == "call-2026-07-13-21-33")
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-07-13-21-33", calendar: utc) == date)
        // A collision suffix names the same minute.
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-07-13-21-33-2", calendar: utc) == date)
    }

    @Test func refusesNamesItDidNotWrite() {
        #expect(MeetingFileNamer.date(fromBaseName: "notes", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-07-13", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-07-13-21-xx", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-07-13-21-33-2-3", calendar: utc) == nil)
        // Digits in the right places are not a date.
        #expect(MeetingFileNamer.date(fromBaseName: "call-9999-99-99-99-99", calendar: utc) == nil)
    }
}

struct PlaySoundsSettingTests {
    @Test func defaultsToTrueAndRoundTrips() {
        let suite = "PlaySoundsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.playSounds == true)
        settings.playSounds = false
        #expect(settings.playSounds == false)
    }
}
