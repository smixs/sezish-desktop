import Foundation
import Testing
@testable import SezishCore

@Suite struct SummaryPromptBuilderTests {
    private static let meetingPath = "/Users/x/Notes/sezish/call-2026-07-30-14-32.md"
    private static let notesPath = "/Users/x/Notes"

    private func prompt(_ language: AppLanguage) -> String {
        SummaryPromptBuilder.build(
            outputLanguage: language,
            meetingMdPath: Self.meetingPath,
            notesFolderPath: Self.notesPath
        )
    }

    @Test func promptCarriesBothPaths() {
        let text = prompt(.ru)
        #expect(text.contains(Self.meetingPath))
        #expect(text.contains(Self.notesPath))
    }

    @Test func promptNamesTheOutputLanguage() {
        // English instructions, but the cards the user reads must be in their language.
        #expect(prompt(.ru).contains("Russian"))
        #expect(!prompt(.ru).contains("Uzbek"))
        #expect(prompt(.uz).contains("Uzbek"))
        #expect(!prompt(.uz).contains("Russian"))
    }

    @Test func promptSpellsOutTheVaultLayout() {
        let text = prompt(.ru)
        let root = SummaryVault.subdirectory
        // Asserted through the constants so the template cannot drift away from the
        // paths the app itself will create and read.
        #expect(text.contains("\(root)/\(SummaryVault.meetingsDir)/"))
        #expect(text.contains("\(root)/\(SummaryVault.peopleDir)/"))
        #expect(text.contains("\(root)/\(SummaryVault.projectsDir)/"))
        #expect(text.contains("\(root)/\(SummaryVault.decisionsDir)/"))
        #expect(text.contains("\(root)/\(SummaryVault.hubFile)"))
    }

    @Test func promptKeepsTheProtocolLandmarks() {
        let text = prompt(.uz)
        #expect(text.contains("LOOKUP"))    // search before writing, no near-duplicates
        #expect(text.contains("SUPERSEDE")) // contradictions rewrite + archive, never coexist
        #expect(text.contains("## Related"))
    }

    @Test func promptFencesTheAgentIntoTheVault() {
        #expect(prompt(.ru).contains("Modify files ONLY inside the vault"))
    }

    @Test func promptNeverTeachesTheMarker() {
        // The app stamps the marker after a successful run. If the agent learned the
        // syntax it could stamp a summary it never wrote, and the next run would skip.
        #expect(!prompt(.ru).contains("sezish-summary"))
        #expect(!prompt(.uz).contains("sezish-summary"))
    }
}

@Suite struct SummaryMarkerTests {
    @Test func lineIsACommentAroundAnISOTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_785_000_000)
        let line = SummaryMarker.line(date: date)

        #expect(line.hasPrefix("<!-- sezish-summary: "))
        #expect(line.hasSuffix(" -->"))

        // The middle must be a real ISO8601 stamp, not free-form text.
        let stamp = line
            .replacingOccurrences(of: "<!-- sezish-summary: ", with: "")
            .replacingOccurrences(of: " -->", with: "")
        let parsed = try #require(ISO8601DateFormatter().date(from: stamp))
        #expect(abs(parsed.timeIntervalSince(date)) < 1)
    }

    @Test func isPresentSeesOnlyTheMarker() {
        #expect(SummaryMarker.isPresent(in: "# Meeting\n\nsome text") == false)
        #expect(SummaryMarker.isPresent(in: "") == false)
        #expect(SummaryMarker.isPresent(in: "text\n<!-- sezish-summary: 2026-07-30T10:00:00Z -->"))
    }

    @Test func appendAddsOneLineAndTouchesNothingBefore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sezish-marker-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = "# Call\n\n[0:01] Я: привет"
        try original.write(to: url, atomically: true, encoding: .utf8)
        #expect(SummaryMarker.isPresent(in: original) == false)

        let date = Date()
        try SummaryMarker.append(to: url, date: date)

        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.hasPrefix(original)) // prior bytes survive verbatim
        #expect(after == original + "\n" + SummaryMarker.line(date: date))
        #expect(SummaryMarker.isPresent(in: after))
        #expect(after.components(separatedBy: "<!-- sezish-summary:").count - 1 == 1)
    }

    @Test func appendIsDumbSoTheCallerMustGuard() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sezish-marker-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try "# Call".write(to: url, atomically: true, encoding: .utf8)
        try SummaryMarker.append(to: url, date: Date())
        try SummaryMarker.append(to: url, date: Date())

        // Two markers: append never inspects the file. `isPresent` is the guard.
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.components(separatedBy: "<!-- sezish-summary:").count - 1 == 2)
    }
}
