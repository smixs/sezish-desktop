import SezishCore
import Testing
@testable import SezishApp

/// The App→Core seam: the format slots of `Strings` must reach the right cases
/// of `meetingStatusLine`. A slot swap in `Localization.swift` (e.g. candidate
/// wired to the denied format) must turn this red — no `AppState` needed.
@MainActor // `Strings.ru` reads synchronously: the app target is MainActor-by-default.
@Suite struct MeetingStatusLineTests {
    @Test func ruSlotsAreWiredToTheRightCases() {
        let t = Strings.ru.meetingStatusText
        #expect(meetingStatusLine(.candidate(name: "Telegram", seconds: 1), text: t)
            == "Telegram держит микрофон 1 с")
        #expect(meetingStatusLine(.denied(names: ["Handy"]), text: t)
            == "Микрофон занят: Handy — это не звонок")
    }
}
