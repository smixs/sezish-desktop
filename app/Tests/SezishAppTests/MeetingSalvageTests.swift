import Foundation
import SezishCore
import Testing
@testable import SezishApp

/// Answers by loudness, not by content: the two stems are fed at different
/// amplitudes, so the returned line says which track the chunk came from. That
/// is what makes the speaker labels assertable without an on-device model.
private struct LoudnessTranscriber: Transcriber {
    /// Halfway between the 0.3 mic tone and the 0.6 system tone.
    private static let threshold: Float = 0.45

    func transcribe(_ samples16k: [Float]) async throws -> String {
        let peak = samples16k.map(abs).max() ?? 0
        return peak < Self.threshold ? "мой текст" : "их текст"
    }
}

/// Never gets a chunk through: every retry attempt ends with no text at all.
private struct AlwaysFailingTranscriber: Transcriber {
    func transcribe(_ samples16k: [Float]) async throws -> String {
        throw CancellationError()
    }
}

/// Fails on every odd call and answers by loudness on the even ones, so the
/// transcript comes back with a hole in it.
private final class OddCallFailingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func transcribe(_ samples16k: [Float]) async throws -> String {
        let index: Int = lock.withLock {
            calls += 1
            return calls
        }
        if index % 2 == 1 { throw CancellationError() }
        return (samples16k.map(abs).max() ?? 0) < 0.45 ? "мой текст" : "их текст"
    }
}

/// Covers the launch-time rescue of `.rec-` dirs a crash left behind: the whole
/// point is that an hour-long call survives the app dying, so every case asserts
/// that audio lands on disk before the spool is allowed to disappear.
///
/// `@MainActor` only so `Strings.ru` reads synchronously (the app target is
/// MainActor-by-default); `salvage` itself is nonisolated and runs off it.
@MainActor
@Suite struct MeetingSalvageTests {
    // MARK: - Fixtures

    private func makeMeetingsDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("salvage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tone rather than a constant: the mixer soft-clips, and a DC block would
    /// hide a stem accidentally mixed in twice.
    private func tone(frames: Int, amplitude: Float = 0.3) -> [Float] {
        (0..<frames).map { amplitude * sinf(2 * .pi * 440 * Float($0) / 16_000) }
    }

    // Inner scope so ARC releases the spool: its FileHandle deinit closes the fd
    // without patching the header — exactly what a crash leaves behind.
    private func dropStemWithoutFinalize(url: URL, samples: [Float]) throws {
        let spool = try PCMSpoolFile(url: url)
        try spool.append(samples)
    }

    @discardableResult
    private func makeOrphan(in dir: URL, mic: [Float]?, system: [Float]?) throws -> URL {
        let orphan = dir.appendingPathComponent(".rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        if let mic {
            try dropStemWithoutFinalize(url: orphan.appendingPathComponent("mic.wav"), samples: mic)
        }
        if let system {
            try dropStemWithoutFinalize(
                url: orphan.appendingPathComponent("system.wav"), samples: system)
        }
        return orphan
    }

    private func audioExists(in dir: URL, base: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(base + ".m4a").path)
            || fm.fileExists(atPath: dir.appendingPathComponent(base + ".wav").path)
    }

    /// A finished stem: the recorder patches the header in stop(), so stashed
    /// stems are always consistent, unlike the ones a crash leaves behind.
    private func writeStem(url: URL, samples: [Float]) throws {
        let spool = try PCMSpoolFile(url: url)
        try spool.append(samples)
        try spool.finalize()
    }

    /// `system.wav` is written even in a mic-only recording, so `system: []`
    /// (an empty header, not a missing file) is the realistic mic-only fixture.
    @discardableResult
    private func makeStems(
        in dir: URL, base: String, mic: [Float]?, system: [Float]?
    ) throws -> URL {
        let stems = dir.appendingPathComponent(".stems-\(base)", isDirectory: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        if let mic { try writeStem(url: stems.appendingPathComponent("mic.wav"), samples: mic) }
        if let system {
            try writeStem(url: stems.appendingPathComponent("system.wav"), samples: system)
        }
        return stems
    }

    /// Room tone: real frames on disk, but quiet enough that the pipeline's
    /// speech gate drops every chunk before inference.
    private func roomTone(frames: Int) -> [Float] {
        [Float](repeating: 0.0005, count: frames)
    }

    // MARK: - Discovery

    @Test func discoversOnlyRecDirectoriesSortedByName() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: dir.appendingPathComponent(".rec-b"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent(".rec-a"), withIntermediateDirectories: true)
        // A stray file wearing the prefix must not be mistaken for a spool dir…
        try Data("junk".utf8).write(to: dir.appendingPathComponent(".rec-c.txt"))
        // …and a finished meeting's own folder must be left alone.
        try fm.createDirectory(
            at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)

        let orphans = MeetingSalvage.discoverOrphans(in: dir)
        #expect(orphans.map(\.lastPathComponent) == [".rec-a", ".rec-b"])
    }

    // MARK: - Salvage

    @Test func salvagesCrashedStemsIntoARecoveredMeeting() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two amplitudes so the fake transcriber can tell the stems apart; both
        // are orders of magnitude above the pipeline's silence gate.
        let orphan = try makeOrphan(
            in: dir,
            mic: tone(frames: 16_000, amplitude: 0.3),
            system: tone(frames: 8_000, amplitude: 0.6)
        )

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .recovered(let mdURL) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        let base = mdURL.deletingPathExtension().lastPathComponent
        #expect(audioExists(in: dir, base: base))

        let md = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(md.contains(Strings.ru.meetingDocRecovered))
        #expect(md.contains(Strings.ru.meetingDocEngine))
        // Both tracks were on disk, so the salvaged transcript is diarized too —
        // a recovered meeting must read exactly like a normally saved one.
        #expect(md.contains("\(Strings.ru.meetingSpeakerMe): мой текст"))
        #expect(md.contains("\(Strings.ru.meetingSpeakerThem): их текст"))

        // The spool is expendable only once the artifacts exist — and then the
        // next launch must find nothing left to retry.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(MeetingSalvage.discoverOrphans(in: dir).isEmpty)
    }

    @Test func discardsOrphanWithoutASingleFrame() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = try makeOrphan(in: dir, mic: [], system: [])

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan, meetingsDir: dir, transcriber: nil, strings: .ru, language: .ru
        )

        guard case .discarded = outcome else {
            Issue.record("expected .discarded, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // Proven garbage produces no artifacts at all, not even an empty .md.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func keepsAudioWhenTheLocalModelIsNotOnDisk() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = try makeOrphan(in: dir, mic: tone(frames: 16_000), system: nil)

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan, meetingsDir: dir, transcriber: nil, strings: .ru, language: .ru
        )

        guard case .recovered(let mdURL) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        let base = mdURL.deletingPathExtension().lastPathComponent
        #expect(audioExists(in: dir, base: base))

        // Nothing was recognised, so the stems move next to the meeting instead
        // of dying: this take is the one a retry will read.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(".stems-" + base).path))
        #expect(MeetingSalvage.discoverStems(in: dir).map(\.lastPathComponent)
            == [".stems-" + base])
        #expect(MeetingSalvage.discoverOrphans(in: dir).isEmpty)

        let md = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(md.contains(Strings.ru.meetingDocRecovered))
        // No transcript, so nothing to claim about where it was recognised —
        // nor anyone to name.
        #expect(!md.contains(Strings.ru.meetingDocEngine))
        #expect(!md.contains("\(Strings.ru.meetingSpeakerMe):"))
    }

    @Test func salvagesMicOnlyOrphanWithNoSystemStem() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The system tap was denied, so start() never created system.wav.
        let orphan = try makeOrphan(in: dir, mic: tone(frames: 16_000), system: nil)

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .recovered(let mdURL) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        #expect(audioExists(in: dir, base: mdURL.deletingPathExtension().lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))

        // One track is nobody to diarize against: the transcript is there, but
        // labelling it would invent a second party that was never recorded.
        let md = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(md.contains("мой текст"))
        #expect(!md.contains("\(Strings.ru.meetingSpeakerMe):"))
    }

    // MARK: - Stems kept for a retry

    @Test func discoverStemsFindsOnlyStemsDirectories() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: dir.appendingPathComponent(".stems-b"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent(".stems-a"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent(".rec-x"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent(".stems-c.txt"))

        #expect(MeetingSalvage.discoverStems(in: dir).map(\.lastPathComponent)
            == [".stems-a", ".stems-b"])
        // The launch-time cleaner must keep ignoring them, or a take waiting for
        // a retry would be salvaged into a second meeting.
        #expect(MeetingSalvage.discoverOrphans(in: dir).map(\.lastPathComponent) == [".rec-x"])
    }

    @Test func stashMovesStemsNextToTheMeeting() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
            .appendingPathComponent(".rec-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try writeStem(url: temp.appendingPathComponent("mic.wav"), samples: tone(frames: 1_000))

        let stashed = try MeetingSalvage.stash(
            stems: temp, base: "call-2026-07-13-21-33", in: dir)

        #expect(stashed.lastPathComponent == ".stems-call-2026-07-13-21-33")
        #expect(fm.fileExists(atPath: stashed.appendingPathComponent("mic.wav").path))
        #expect(!fm.fileExists(atPath: temp.path))
    }

    // MARK: - Retry

    @Test func transcribeReportsAStemItCannotOpen() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let stems = try makeStems(
            in: dir, base: "call-2026-07-13-21-33", mic: tone(frames: 16_000), system: nil)
        let micURL = stems.appendingPathComponent("mic.wav")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: micURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: micURL.path) }

        let result = await MeetingSalvage.transcribe(
            transcriber: LoudnessTranscriber(), micURL: micURL, systemURL: nil, strings: .ru)

        // Audio that never reached the model is not a model that found nothing:
        // the caller needs the difference to decide whether to keep the stems.
        #expect(result.readFailed)
        #expect(result.text == nil)
        #expect(result.failedChunks == 0)
    }

    @Test func salvageStashesStemsWhenAStemCannotBeRead() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let orphan = try makeOrphan(
            in: dir, mic: tone(frames: 16_000), system: tone(frames: 8_000, amplitude: 0.6))
        let systemURL = orphan.appendingPathComponent("system.wav")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: systemURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: systemURL.path) }

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .recovered(let mdURL) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        // Half the call never got read, so the take is kept for a retry even
        // though the other half produced a transcript.
        let base = mdURL.deletingPathExtension().lastPathComponent
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(".stems-" + base).path))
        #expect(try String(contentsOf: mdURL, encoding: .utf8).contains("мой текст"))
    }

    @Test func stashOverExistingDirectoryThrowsAndKeepsTemp() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let base = "call-2026-07-13-21-33"
        try fm.createDirectory(
            at: dir.appendingPathComponent(".stems-" + base), withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory
            .appendingPathComponent(".rec-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try writeStem(url: temp.appendingPathComponent("mic.wav"), samples: tone(frames: 1_000))

        // The name is taken, so the move must fail loudly instead of merging or
        // clobbering an older take that is still waiting for its retry.
        #expect(throws: (any Error).self) {
            try MeetingSalvage.stash(stems: temp, base: base, in: dir)
        }
        #expect(fm.fileExists(atPath: temp.appendingPathComponent("mic.wav").path))
    }

    @Test func salvageStashesUnderAFreeNameWhenTheStemsNameIsTaken() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let orphan = try makeOrphan(in: dir, mic: tone(frames: 16_000), system: nil)
        // The base name comes from mic.wav's creation date, so read it off the
        // file instead of the clock: no flake on a minute boundary.
        let created = try #require(
            try orphan.appendingPathComponent("mic.wav")
                .resourceValues(forKeys: [.creationDateKey]).creationDate)
        let taken = MeetingFileNamer.baseName(for: created)
        try fm.createDirectory(
            at: dir.appendingPathComponent(".stems-" + taken), withIntermediateDirectories: true)

        let outcome = await MeetingSalvage.salvage(
            orphan: orphan, meetingsDir: dir, transcriber: nil, strings: .ru, language: .ru
        )

        guard case .recovered(let mdURL) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        // A hidden stems dir is a taken name like any other artifact.
        #expect(mdURL.deletingPathExtension().lastPathComponent == taken + "-2")
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(".stems-" + taken + "-2").path))
    }

    @Test func retranscribeRewritesMarkdownAndRemovesStems() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(in: dir, base: base, mic: tone(frames: 16_000), system: [])
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)
        try Data("m4a".utf8).write(to: dir.appendingPathComponent(base + ".m4a"))

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .retranscribed(let md) = outcome else {
            Issue.record("expected .retranscribed, got \(outcome)")
            return
        }
        #expect(md == mdURL)
        let text = try String(contentsOf: md, encoding: .utf8)
        #expect(text.contains("мой текст"))
        #expect(!text.contains("старый текст"))
        #expect(text.contains(base + ".m4a")) // the audio link points at the file on disk
        // A retry produces a normal meeting, not a rescued one.
        #expect(!text.contains(Strings.ru.meetingDocRecovered))
        // An empty system.wav is not a second party, so nothing is labelled.
        #expect(!text.contains("\(Strings.ru.meetingSpeakerMe):"))

        #expect(!FileManager.default.fileExists(atPath: stems.path))
        #expect(MeetingSalvage.discoverStems(in: dir).isEmpty)
    }

    @Test func retranscribeKeepsStemsWhenTranscriberFails() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(in: dir, base: base, mic: tone(frames: 16_000), system: [])
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: AlwaysFailingTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        // Nothing recognised: the .md keeps what it said and the audio waits for
        // the next attempt.
        #expect(try String(contentsOf: mdURL, encoding: .utf8) == "старый текст")
        #expect(FileManager.default.fileExists(atPath: stems.path))
    }

    @Test func retranscribeKeepsStemsOnPartialTranscript() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = "call-2026-07-13-21-33"
        // 16 000 and 8 000 frames against the default 30 s chunk: neither track
        // reaches a cut, so the run is exactly two chunks, the mic tail and then
        // the system tail. The transcriber throws on the first and answers the
        // second, so the transcript comes back with a hole. Do not grow this
        // fixture: the chunk count is the point of the test.
        let stems = try makeStems(
            in: dir,
            base: base,
            mic: tone(frames: 16_000, amplitude: 0.3),
            system: tone(frames: 8_000, amplitude: 0.6)
        )
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: OddCallFailingTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .partial = outcome else {
            Issue.record("expected .partial, got \(outcome)")
            return
        }
        // What was recognised is written down...
        let text = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(text.contains("\(Strings.ru.meetingSpeakerThem): их текст"))
        #expect(!text.contains("мой текст"))
        #expect(!text.contains("старый текст"))
        // ...and the stems stay, because the hole can still be filled later.
        #expect(FileManager.default.fileExists(atPath: stems.path))
    }

    @Test func retranscribeKeepsStemsWhenAStemCannotBeRead() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(in: dir, base: base, mic: tone(frames: 16_000), system: [])
        let micURL = stems.appendingPathComponent("mic.wav")
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)
        // A whole call behind a permission we cannot open. Unreadable is not
        // silence, and the difference decides whether the take survives.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: micURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: micURL.path) }

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(try String(contentsOf: mdURL, encoding: .utf8) == "старый текст")
        #expect(fm.fileExists(atPath: stems.path))
    }

    @Test func retranscribeReadsAStemItCannotRepair() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(in: dir, base: base, mic: tone(frames: 16_000), system: [])
        let micURL = stems.appendingPathComponent("mic.wav")
        try "старый текст".write(
            to: dir.appendingPathComponent(base + ".md"), atomically: true, encoding: .utf8)
        // Read-only, but perfectly readable: header repair needs write access and
        // must not be the thing that decides the stem is empty.
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: micURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: micURL.path) }

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .retranscribed(let md) = outcome else {
            Issue.record("expected .retranscribed, got \(outcome)")
            return
        }
        #expect(try String(contentsOf: md, encoding: .utf8).contains("мой текст"))
        #expect(!fm.fileExists(atPath: stems.path))
    }

    @Test func retranscribeUsesTheReadableStemWhenTheOtherIsBroken() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(
            in: dir,
            base: base,
            mic: tone(frames: 16_000, amplitude: 0.3),
            system: tone(frames: 8_000, amplitude: 0.6)
        )
        let systemURL = stems.appendingPathComponent("system.wav")
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: systemURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: systemURL.path) }

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .partial = outcome else {
            Issue.record("expected .partial, got \(outcome)")
            return
        }
        // One broken stem must not cost the user the half that still reads.
        let text = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(text.contains("мой текст"))
        #expect(!text.contains("старый текст"))
        #expect(fm.fileExists(atPath: stems.path))
    }

    @Test func retranscribeSilenceRemovesStemsWithoutTouchingMarkdown() async throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = "call-2026-07-13-21-33"
        let stems = try makeStems(in: dir, base: base, mic: roomTone(frames: 16_000), system: [])
        let mdURL = dir.appendingPathComponent(base + ".md")
        try "старый текст".write(to: mdURL, atomically: true, encoding: .utf8)

        let outcome = await MeetingSalvage.retranscribe(
            stems: stems,
            meetingsDir: dir,
            transcriber: LoudnessTranscriber(),
            strings: .ru,
            language: .ru
        )

        guard case .nothingToRecover = outcome else {
            Issue.record("expected .nothingToRecover, got \(outcome)")
            return
        }
        // Nothing failed, there is simply nothing said: retrying forever would be
        // the bug, so the stems go and the .md stays as it was.
        #expect(try String(contentsOf: mdURL, encoding: .utf8) == "старый текст")
        #expect(!FileManager.default.fileExists(atPath: stems.path))
    }
}
