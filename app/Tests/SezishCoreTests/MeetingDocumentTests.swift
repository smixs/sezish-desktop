import Foundation
import Testing
@testable import SezishCore

/// The meetings screen reads the app's own .md back: heading, duration, audio
/// link and the "[3:12] Я: …" lines.
struct MeetingDocumentTests {
    private let sample = """
    # Звонок в Telegram - 4 ноября 2026 г. в 14:00

    Длительность: 39:22
    Распознано локально на устройстве
    Audio: [call-2026-11-04-14-00.m4a](call-2026-11-04-14-00.m4a)

    [0:00] Я: Если вдруг у тебя будут дистры,
    я бы с радостью.

    [0:28] Они: Давай.

    [1:03:12] Я: Последнее.

    [1:04:00] без метки
    """

    @Test func readsTheHeadingDurationAndAudio() {
        let doc = MeetingDocument(markdown: sample, speakers: ["Я", "Они"])
        #expect(doc.heading == "Звонок в Telegram - 4 ноября 2026 г. в 14:00")
        #expect(doc.title == "Звонок в Telegram")
        #expect(doc.duration == 39 * 60 + 22)
        #expect(doc.audioFile == "call-2026-11-04-14-00.m4a")
    }

    @Test func readsTheLinesWithSpeakersAndTimes() {
        let doc = MeetingDocument(markdown: sample, speakers: ["Я", "Они"])
        #expect(doc.lines.count == 4)
        #expect(doc.lines[0] == MeetingLine(time: "0:00", seconds: 0, speaker: "Я",
                                            text: "Если вдруг у тебя будут дистры, я бы с радостью."))
        #expect(doc.lines[1].speaker == "Они")
        #expect(doc.lines[2].seconds == 3792)
        #expect(doc.lines[3].speaker == nil)
        #expect(doc.lines[3].text == "без метки")
        #expect(doc.plainTranscript.hasPrefix("[0:00] Я: Если вдруг"))
    }

    @Test func aDocumentWithoutTranscriptHasNoLines() {
        let doc = MeetingDocument(markdown: """
        # Запись звонка - 1 ноября 2026 г. в 9:00

        Длительность: 1:02:03
        Audio: [a.m4a](a.m4a)

        _Текст не распознался_
        """, speakers: ["Я", "Они"])
        #expect(doc.lines.isEmpty)
        #expect(doc.duration == 3723)
        #expect(doc.title == "Запись звонка")
    }

    @Test func renameKeepsTheDateStampAndEverythingElse() {
        let renamed = MeetingDocument.renamed(sample, to: "  Запуск с Азизом ")
        #expect(renamed == "# Запуск с Азизом - 4 ноября 2026 г. в 14:00" + sample.drop { $0 != "\n" })
        #expect(MeetingDocument(markdown: renamed ?? "", speakers: ["Я"]).title == "Запуск с Азизом")
    }

    @Test func renameRefusesBlankTitlesAndFilesWithoutAHeading() {
        #expect(MeetingDocument.renamed(sample, to: "   ") == nil)
        #expect(MeetingDocument.renamed("просто текст", to: "Новое") == nil)
        #expect(MeetingDocument.renamed(sample, to: "две\nстроки") == "# две строки - 4 ноября 2026 г. в 14:00"
            + sample.drop { $0 != "\n" })
    }

    @Test func aHandWrittenFileStillReads() {
        let doc = MeetingDocument(markdown: "просто текст", speakers: ["Я"])
        #expect(doc.heading == nil)
        #expect(doc.title == nil)
        #expect(doc.duration == nil)
        #expect(doc.lines.isEmpty)
    }
}

/// The summary card's first paragraph is what the meeting card shows.
struct SummaryLeadTests {
    @Test func skipsFrontmatterAndHeadingsAndUnwrapsLinks() {
        let card = """
        ---
        type: meeting
        date: 2026-11-04
        ---
        # Встреча с [[people/aziz|Азизом]]

        Обсудили запуск в [[projects/sezish]] и сроки
        до пятницы.

        ## Related
        - [[sezish/_index]]
        """
        #expect(SummaryLead.firstParagraph(of: card) == "Обсудили запуск в sezish и сроки до пятницы.")
    }

    @Test func nothingProseMeansNil() {
        #expect(SummaryLead.firstParagraph(of: "---\na: b\n---\n# Title\n- item\n") == nil)
        #expect(SummaryLead.firstParagraph(of: "") == nil)
    }
}

/// History and meetings are listed by day, newest first, with a search that
/// ignores case and the ё/е difference.
struct DayGroupingTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return c
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func groupsByDayNewestFirst() {
        let items = [date(3, 9), date(5, 8), date(5, 12), date(4, 23)]
        let groups = DayGrouping.group(items, date: { $0 }, calendar: calendar)
        #expect(groups.map(\.items) == [[date(5, 12), date(5, 8)], [date(4, 23)], [date(3, 9)]])
        #expect(groups[0].day == calendar.startOfDay(for: date(5, 1)))
    }

    @Test func namesTodayAndYesterday() {
        let now = date(5, 10)
        #expect(DayGrouping.relative(calendar.startOfDay(for: now), now: now, calendar: calendar) == .today)
        #expect(DayGrouping.relative(calendar.startOfDay(for: date(4, 1)), now: now, calendar: calendar) == .yesterday)
        #expect(DayGrouping.relative(calendar.startOfDay(for: date(1, 1)), now: now, calendar: calendar) == .earlier)
    }

    @Test func searchFoldsCaseAndYo() {
        #expect(TextSearch.matches("ЁЛКА", in: ["купили елку"]) == false)
        #expect(TextSearch.matches("ёлка", in: ["Купили Елка"]))
        #expect(TextSearch.matches("  ", in: ["что угодно"]))
        #expect(TextSearch.matches("telegram", in: ["Звонок в Telegram", ""]))
        #expect(!TextSearch.matches("zoom", in: ["Звонок в Telegram"]))
    }
}
