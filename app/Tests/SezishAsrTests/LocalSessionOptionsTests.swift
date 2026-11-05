import Testing

@testable import SezishAsr

/// The engine repacks the int8 weights into its own layout on load: ~300 MB more for the
/// whole life of the app, and a 20-minute meeting ran at the same speed without it
/// (51 s vs 51–53 s, .scratch/reports/memory-2026-11-05.md).
@Suite struct LocalSessionOptionsTests {
    @Test func weightsAreNotRepackedOnLoad() {
        #expect(GigaAmTranscriber.sessionConfig["session.disable_prepacking"] == "1")
    }
}
