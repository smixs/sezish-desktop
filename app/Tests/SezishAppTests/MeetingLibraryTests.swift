import Foundation
import SezishCore
import Testing
@testable import SezishApp

/// The list behind the History tab: what the meetings folder holds, in the order
/// a human expects, and which of those takes can still be recognised again.
@Suite struct MeetingLibraryTests {
    private func makeMeetingsDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMeeting(in dir: URL, base: String) throws {
        try "# \(base)".write(
            to: dir.appendingPathComponent(base + ".md"), atomically: true, encoding: .utf8)
    }

    private func makeStems(in dir: URL, base: String) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".stems-" + base), withIntermediateDirectories: true)
    }

    @Test func entriesSortedNewestFirstWithNeedsRetryFlag() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Written oldest last, so a directory listing alone cannot pass this.
        try writeMeeting(in: dir, base: "call-2026-07-14-09-05")
        try writeMeeting(in: dir, base: "call-2026-07-13-21-33")
        try makeStems(in: dir, base: "call-2026-07-13-21-33")
        // Neither the audio nor a stray file is a meeting.
        try Data("m4a".utf8).write(to: dir.appendingPathComponent("call-2026-07-13-21-33.m4a"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let entries = MeetingLibrary.entries(in: dir)

        #expect(entries.map(\.base) == ["call-2026-07-14-09-05", "call-2026-07-13-21-33"])
        #expect(entries.map(\.needsRetry) == [false, true])
        #expect(entries.map(\.hasMarkdown) == [true, true])
        #expect(entries.first?.mdURL == dir.appendingPathComponent("call-2026-07-14-09-05.md"))
        #expect(entries.first?.id == entries.first?.base)
    }

    @Test func listsStemsThatHaveNoMarkdownYet() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeStems(in: dir, base: "call-2026-07-13-21-33")

        let entry = try #require(MeetingLibrary.entries(in: dir).first)

        // The menu counts this take, so the list must show it too.
        #expect(entry.base == "call-2026-07-13-21-33")
        #expect(entry.needsRetry)
        #expect(!entry.hasMarkdown)
        #expect(entry.mdURL == dir.appendingPathComponent("call-2026-07-13-21-33.md"))
    }

    @Test func dateParsedFromBaseName() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMeeting(in: dir, base: "call-2026-07-13-21-33")

        let entry = try #require(MeetingLibrary.entries(in: dir).first)
        // The name, not the .md creation date: write(atomically:) makes a new
        // inode, so a retranscribed meeting would otherwise jump to the top.
        let expected = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 21, minute: 33)))
        #expect(entry.date == expected)

        // A file the app did not name still gets a usable date.
        try writeMeeting(in: dir, base: "заметки со звонка")
        let renamed = try #require(
            MeetingLibrary.entries(in: dir).first { $0.base == "заметки со звонка" })
        #expect(abs(renamed.date.timeIntervalSinceNow) < 60)
    }

    @Test func stemsURLPointsAtTheParkedFolder() throws {
        let dir = try makeMeetingsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMeeting(in: dir, base: "call-2026-07-14-09-05")
        try writeMeeting(in: dir, base: "call-2026-07-13-21-33")
        try makeStems(in: dir, base: "call-2026-07-13-21-33")

        let entries = MeetingLibrary.entries(in: dir)

        // The retry reads a stems directory, so the row carries the path itself
        // instead of letting the view guess the hidden name.
        #expect(entries.first?.stemsURL == nil)
        #expect(entries.last?.stemsURL
            == dir.appendingPathComponent(".stems-call-2026-07-13-21-33", isDirectory: true))
    }
}
