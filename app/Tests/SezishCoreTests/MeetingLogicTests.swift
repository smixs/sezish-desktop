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
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 0, stopReason: .manual))
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 59.9, stopReason: .manual))
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 60, stopReason: .manual))
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 3600, stopReason: .manual))
    }

    /// The window the stop watch waited out is not meeting time: eleven minutes
    /// of recording that ended in the ten-minute silence window is one minute of
    /// meeting — and without the discount no auto-stop could ever be short.
    @Test func theStopWatchSilenceIsNotMeetingTime() {
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 660, stopReason: .silence(600)))
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 650, stopReason: .silence(600)))
    }

    /// The detector's stop window is quiet too — the debounce's ten seconds.
    @Test func theDebounceWindowIsNotMeetingTime() {
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 70, stopReason: .callEnded(10)))
        #expect(!MeetingTranscriptionRule.shouldTranscribe(duration: 69, stopReason: .callEnded(10)))
    }

    /// A manual stop and the ceiling discount nothing: every second of those
    /// recordings is time somebody asked for.
    @Test func manualAndCeilingStopsDiscountNothing() {
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 60, stopReason: .manual))
        #expect(MeetingTranscriptionRule.shouldTranscribe(duration: 60, stopReason: .ceiling(18_000)))
    }
}

struct MeetingAutoStopTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    @Test func tenMinutesOfSilenceEndAnAutoStartedRecording() {
        var stop = MeetingAutoStop(startedAt: t0, isAuto: true)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 599) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 600) == .silence(600))
    }

    /// A silent mic is not a silent room: the other side of the call is a voice,
    /// and any sound restarts the window.
    @Test func aTrackThatIsStillTalkingKeepsTheRecordingAlive() {
        var stop = MeetingAutoStop(startedAt: t0, isAuto: true)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: true, at: t0 + 300) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 600) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 1_199) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 1_200) == .silence(600))
    }

    @Test func theCeilingEndsAnAutoStartedRecording() {
        var stop = MeetingAutoStop(startedAt: t0, isAuto: true)
        #expect(stop.tick(micLoud: true, systemLoud: true, at: t0 + 5 * 3_600 - 1) == nil)
        #expect(
            stop.tick(micLoud: true, systemLoud: true, at: t0 + 5 * 3_600)
                == .ceiling(5 * 3_600)
        )
    }

    /// A manual recording is the user's own: silence never ends it, but the
    /// ceiling does — an eight-hour take is a bug, whoever started it.
    @Test func aManualRecordingIgnoresSilenceButNotTheCeiling() {
        var stop = MeetingAutoStop(startedAt: t0, isAuto: false)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 600) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 4 * 3_600) == nil)
        #expect(
            stop.tick(micLoud: false, systemLoud: false, at: t0 + 5 * 3_600)
                == .ceiling(5 * 3_600)
        )
    }

    /// The thresholds are hidden settings, and a stop that carries its own window
    /// is what the short-recording rule discounts.
    @Test func customThresholdsReplaceTheDefaults() {
        var stop = MeetingAutoStop(startedAt: t0, isAuto: true, silenceAfter: 60, maxDuration: 120)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0) == nil)
        #expect(stop.tick(micLoud: false, systemLoud: false, at: t0 + 60) == .silence(60))
    }
}

struct MeetingLoudnessMeterTests {
    private let loud = [Float](repeating: 0.05, count: 1_600)
    private let roomTone = [Float](repeating: 0.005, count: 1_600)

    @Test func aLoudFrameMarksTheTrackLoud() {
        var meter = MeetingLoudnessMeter()
        let loudFrame = meter.append(loud)
        #expect(loudFrame)
    }

    @Test func roomToneAndEmptyBuffersAreNotSpeech() {
        var meter = MeetingLoudnessMeter()
        let roomToneFrame = meter.append(roomTone)
        let nothing = meter.append([])
        #expect(!roomToneFrame)
        #expect(!nothing)
    }

    /// Realtime buffers are shorter than a frame: half a frame is not a verdict.
    @Test func framesAccumulateAcrossBuffers() {
        var meter = MeetingLoudnessMeter()
        let half = meter.append(Array(loud[..<800]))
        #expect(!half)
        let secondHalf = meter.append(Array(loud[800...]))
        #expect(secondHalf)
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

struct MeetingFileNamerAppTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var date: Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8, minute: 32))!
    }

    @Test func telegramSlugRoundTrip() {
        let base = MeetingFileNamer.baseName(for: date, app: "Telegram", calendar: utc)
        #expect(base == "call-2026-09-16-08-32-telegram")
        #expect(MeetingFileNamer.date(fromBaseName: base, calendar: utc) == date)
    }

    @Test func zoomBundleIDSlugRoundTrip() {
        let base = MeetingFileNamer.baseName(for: date, app: "zoom.us", calendar: utc)
        #expect(base == "call-2026-09-16-08-32-zoomus")
        #expect(MeetingFileNamer.date(fromBaseName: base, calendar: utc) == date)
    }

    @Test func chromeSlugRoundTrip() {
        let base = MeetingFileNamer.baseName(for: date, app: "Google Chrome", calendar: utc)
        #expect(base == "call-2026-09-16-08-32-googlechrome")
        #expect(MeetingFileNamer.date(fromBaseName: base, calendar: utc) == date)
    }

    @Test func cyrillicNameGetsNoSuffix() {
        let base = MeetingFileNamer.baseName(for: date, app: "Яндекс Браузер", calendar: utc)
        #expect(base == "call-2026-09-16-08-32")
        #expect(MeetingFileNamer.date(fromBaseName: base, calendar: utc) == date)
    }

    @Test func digitsOnlyNameGetsNoSuffix() {
        let base = MeetingFileNamer.baseName(for: date, app: "2026", calendar: utc)
        #expect(base == "call-2026-09-16-08-32")
        #expect(MeetingFileNamer.date(fromBaseName: base, calendar: utc) == date)
    }

    @Test func slugTruncatesToSixteenAsciiChars() {
        #expect(MeetingFileNamer.appSlug(from: "SomeVeryLongApplicationName") == "someverylongappl")
        #expect(MeetingFileNamer.appSlug(from: "Яндекс Браузер") == nil)
        #expect(MeetingFileNamer.appSlug(from: "2026") == nil)
    }

    @Test func collisionSuffixGoesAfterSlug() {
        let dated = "call-2026-09-16-08-32-telegram"
        let taken: Set<String> = [dated, dated + "-2"]
        let name = MeetingFileNamer.uniqueBaseName(for: date, app: "Telegram", calendar: utc) {
            taken.contains($0)
        }
        #expect(name == dated + "-3")
        #expect(MeetingFileNamer.date(fromBaseName: name, calendar: utc) == date)
    }

    @Test func refusesSlugGarbage() {
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-09-16-08-32-Telegram", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-09-16-08-32-telegram-2-3", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "call-2026-09-16-08-32-2-telegram", calendar: utc) == nil)
        #expect(MeetingFileNamer.date(fromBaseName: "standup-2026-09-16-08-32", calendar: utc) == nil)
    }
}

struct CallAppFamilyTests {
    /// Every anchor the spec names, spelled out: a helper folds into the app it
    /// serves, an id without a `.helper` segment is its own family. Exact answers,
    /// not a round trip — a round trip holds for any prefix, including an empty one.
    @Test func anchorsResolveToTheirOwnFamily() {
        let anchors: [(id: String, family: String)] = [
            ("com.google.Chrome.helper.Renderer", "com.google.chrome"),
            ("com.google.Chrome.helper", "com.google.chrome"),
            ("us.zoom.xos", "us.zoom.xos"),
            ("ru.keepcoder.Telegram", "ru.keepcoder.telegram"),
            ("org.telegram.desktop", "org.telegram.desktop"),
            ("com.tdesktop.Telegram", "com.tdesktop.telegram"),
            ("com.apple.WebKit.GPU", "com.apple.webkit.gpu"),
        ]
        for anchor in anchors {
            #expect(CallAppFamily.of(anchor.id) == anchor.family)
            #expect(CallAppFamily.belongs(anchor.id, to: anchor.family))
        }
        // The empty id is the empty family — nobody's, not everybody's.
        #expect(CallAppFamily.of("") == "")
        #expect(!CallAppFamily.belongs("", to: ""))
    }

    /// `.helper` folds an id only as a whole segment: a second segment that merely
    /// starts with those letters belongs to the app's own name.
    @Test func aHelperMarkerInsideASegmentIsNotAMarker() {
        #expect(CallAppFamily.of("com.helperbot.app") == "com.helperbot.app")
        #expect(CallAppFamily.of("A.helper.B") == "a")
    }

    @Test func caseIsIgnoredOnBothSides() {
        #expect(CallAppFamily.of("COM.Google.Chrome.HELPER.Renderer") == "com.google.chrome")
        #expect(CallAppFamily.belongs("COM.GOOGLE.CHROME.HELPER", to: "com.google.Chrome"))
    }

    /// Neighbours are not family: a Canary build is another app, `com.apple.Music`
    /// is not `com`, and a longer id is not a helper of a shorter one.
    @Test func neighboursAndPrefixesDoNotBelong() {
        #expect(!CallAppFamily.belongs("com.google.Chrome.canary", to: "com.google.chrome"))
        #expect(!CallAppFamily.belongs("com.apple.Music", to: "com"))
        #expect(!CallAppFamily.belongs("com.microsoft.teams2stuff", to: "com.microsoft.teams2"))
    }

    /// Garbage is not a crash, and a non-empty id never resolves to an empty
    /// family — an empty family would be a prefix of everything on the Mac.
    @Test func garbageNeverYieldsAnEmptyFamily() {
        let junk = [
            ".", "..", ".helper", "helper", "a.helper.b.helper.c", "🦊.helper.🦊", "com...", "HELPER.x",
        ]
        for id in junk {
            let family = CallAppFamily.of(id)
            #expect(!family.isEmpty)
            #expect(CallAppFamily.belongs(id, to: family))
        }
        #expect(CallAppFamily.of("") == "")
    }
}

struct MeetingCallAppResolverTests {
    private let policy = MeetingDetectionPolicy(ownBundleID: "com.smixs.sezish")

    /// The detector's id can be a helper: the family is what the tap records.
    @Test func autoTakesTheDetectorAppAndItsFamily() {
        let app = MeetingCallAppResolver.resolve(
            source: .auto(bundleID: "com.google.Chrome.helper.Renderer"),
            holders: [.init(bundleID: "com.google.Chrome.helper.Renderer", pid: 42, isRunningOutput: true)],
            policy: policy
        )
        #expect(app?.bundleID == "com.google.Chrome.helper.Renderer")
        #expect(app?.pid == 42)
        #expect(app?.family == "com.google.chrome")
        #expect(app?.scope == .family("com.google.chrome"))
    }

    /// A manual start has no detector answer: the first mic holder the policy
    /// would record is the call app, deny-listed ones skipped.
    @Test func manualTakesTheFirstMicHolderThatIsNotDenied() {
        let app = MeetingCallAppResolver.resolve(
            source: .manual,
            holders: [
                .init(bundleID: "com.electron.wispr-flow", pid: 7, isRunningOutput: true),
                .init(bundleID: "us.zoom.xos", pid: 8, isRunningOutput: true),
            ],
            policy: policy
        )
        #expect(app == MeetingCallApp(bundleID: "us.zoom.xos", pid: 8, family: "us.zoom.xos"))
    }

    /// A call is full-duplex: with several recordable holders on the mic, the one
    /// that is also playing audio is the call — the detector's own judgement.
    @Test func manualPrefersAHolderThatIsAlsoPlayingAudio() {
        let app = MeetingCallAppResolver.resolve(
            source: .manual,
            holders: [
                .init(bundleID: "com.apple.QuickTimePlayerX", pid: 7, isRunningOutput: false),
                .init(bundleID: "us.zoom.xos", pid: 8, isRunningOutput: true),
            ],
            policy: policy
        )
        #expect(app?.bundleID == "us.zoom.xos")
        #expect(app?.pid == 8)
    }

    /// Nothing is playing audio, so the input-only holder is the best answer there
    /// is: refusing to name an app would record no system audio at all.
    @Test func manualFallsBackToAnInputOnlyHolder() {
        let app = MeetingCallAppResolver.resolve(
            source: .manual,
            holders: [.init(bundleID: "com.apple.QuickTimePlayerX", pid: 7, isRunningOutput: false)],
            policy: policy
        )
        #expect(app?.bundleID == "com.apple.QuickTimePlayerX")
    }

    @Test func onlyAutoStartsAreAuto() {
        #expect(MeetingStartSource.auto(bundleID: "us.zoom.xos").isAuto)
        #expect(MeetingStartSource.auto(bundleID: nil).isAuto)
        #expect(!MeetingStartSource.manual.isAuto)
    }

    @Test func theScopeFollowsTheCallApp() {
        let app = MeetingCallApp(bundleID: "us.zoom.xos", pid: 8, family: "us.zoom.xos")
        #expect(MeetingAudioScope.forCallApp(app) == .family("us.zoom.xos"))
        #expect(MeetingAudioScope.forCallApp(nil) == .all)
    }

    @Test func noCallAppToNameMeansTheWholeSystem() {
        let noHolders = MeetingCallAppResolver.resolve(source: .manual, holders: [], policy: policy)
        #expect(noHolders == nil)
        #expect(MeetingAudioScope.forCallApp(noHolders) == .all)

        let deniedOnly = MeetingCallAppResolver.resolve(
            source: .manual,
            holders: [.init(bundleID: "com.smixs.sezish", pid: 1, isRunningOutput: true)],
            policy: policy
        )
        #expect(deniedOnly == nil)

        // The detector fires without a name when no holder matched its policy.
        #expect(MeetingCallAppResolver.resolve(source: .auto(bundleID: nil), holders: [], policy: policy) == nil)
    }
}

struct MeetingTapCoverageTests {
    /// The family's live processes are the tap; whatever else happens to be playing
    /// — and a process CoreAudio would not name — is not.
    @Test func aFamilyScopeCoversExactlyItsLiveProcesses() {
        let coverage = MeetingAudioScope.family("com.google.Chrome").coverage(live: [
            (id: 1, bundleID: "com.google.Chrome.helper.Renderer"),
            (id: 2, bundleID: "com.apple.Music"),
            (id: 3, bundleID: nil),
        ])
        #expect(coverage == .processes([1]))
    }

    /// Nothing of that family is running: the tap records everything, which is the
    /// one degradation this path allows. `.all` never had a list to begin with.
    @Test func aFamilyWithNothingLiveAndAllCoverTheWholeSystem() {
        #expect(
            MeetingAudioScope.family("us.zoom.xos").coverage(live: [(id: 2, bundleID: "com.apple.Music")])
                == .global
        )
        #expect(MeetingAudioScope.family("us.zoom.xos").coverage(live: []) == .global)
        #expect(MeetingAudioScope.all.coverage(live: [(id: 2, bundleID: "com.apple.Music")]) == .global)
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

struct MeetingCallAppDisplayNameTests {
    private let policy = MeetingDetectionPolicy(ownBundleID: "com.smixs.sezish")

    /// The AppKit lookup is the caller's input: whatever it returns lands in
    /// the app as is, so the name is snapshotted once while the process lives.
    @Test func displayNamePassesThroughAsIs() {
        let app = MeetingCallAppResolver.resolve(
            source: .auto(bundleID: "us.zoom.xos"),
            holders: [.init(bundleID: "us.zoom.xos", pid: 8, isRunningOutput: true)],
            policy: policy,
            displayName: { _ in "Telegram" }
        )
        #expect(app?.displayName == "Telegram")
    }

    @Test func vanishedProcessLeavesNoDisplayName() {
        let app = MeetingCallAppResolver.resolve(
            source: .manual,
            holders: [.init(bundleID: "us.zoom.xos", pid: 8, isRunningOutput: true)],
            policy: policy,
            displayName: { _ in nil }
        )
        #expect(app?.bundleID == "us.zoom.xos")
        #expect(app?.displayName == nil)
    }
}

struct MeetingMicRouteTests {
    private let headset = MicDevice(id: 42, name: "Zoom Headset", isVirtual: false)
    private let usb = MicDevice(id: 43, name: "USB Microphone", isVirtual: false)
    private let loopback = MicDevice(id: 57, name: "ZoomAudioDevice", isVirtual: true)
    private let aggregate = MicDevice(id: 58, name: "Aggregate", isVirtual: true)

    /// The first real device of the call app wins. A virtual one is not a microphone
    /// even when it comes first: Zoom's own loopback is always the first device of
    /// Zoom's process, and it hands the engine zero frames — a mic track that would be
    /// silence is the same defect as recording the room.
    @Test func aRealCallAppInputWinsOverAVirtualOne() {
        #expect(MeetingMicRoute.device(callAppInputs: [loopback, headset, usb]) == headset)
        #expect(MeetingMicRoute.device(callAppInputs: [aggregate, headset]) == headset)
    }

    /// Only virtual devices: nothing to record from, so the engine opens whatever it
    /// picks — exactly what dictation has always done.
    @Test func onlyVirtualCallAppInputsLeaveTheRouteToTheEngine() {
        #expect(MeetingMicRoute.device(callAppInputs: [loopback, aggregate]) == nil)
        #expect(MeetingMicRoute.device(callAppInputs: []) == nil)
    }
}
