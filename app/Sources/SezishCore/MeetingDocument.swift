import Foundation

/// One "[3:12] Я: text" line of a meeting transcript.
public struct MeetingLine: Sendable, Equatable {
    /// As written: "3:12" or "1:03:12".
    public let time: String
    public let seconds: Int
    /// nil when the take was not split into "me / them".
    public let speaker: String?
    public let text: String

    public init(time: String, seconds: Int, speaker: String?, text: String) {
        self.time = time
        self.seconds = seconds
        self.speaker = speaker
        self.text = text
    }
}

/// The app's own meeting .md read back for the meetings screen. Lenient: a
/// file edited by hand reads as far as it still looks like ours.
public struct MeetingDocument: Sendable {
    /// The first "# " line without the mark.
    public let heading: String?
    /// The heading without its " - <date>" stamp: "Звонок в Telegram".
    public let title: String?
    public let duration: Int?
    public let audioFile: String?
    public let lines: [MeetingLine]

    /// `speakers` are the "me / them" labels of both UI languages.
    public init(markdown: String, speakers: [String]) {
        var heading: String?
        var duration: Int?
        var audio: String?
        var lines: [MeetingLine] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if heading == nil, line.hasPrefix("# ") {
                heading = String(line.dropFirst(2))
            } else if let parsed = Self.transcriptLine(line, speakers: speakers) {
                lines.append(parsed)
            } else if !lines.isEmpty {
                // A wrapped continuation of the line above.
                let last = lines.removeLast()
                lines.append(MeetingLine(time: last.time, seconds: last.seconds,
                                         speaker: last.speaker, text: last.text + " " + line))
            } else if audio == nil, line.hasPrefix("Audio: ["), let end = line.firstIndex(of: "]") {
                audio = String(line[line.index(line.startIndex, offsetBy: 8)..<end])
            } else if duration == nil, let value = Self.durationLine(line) {
                duration = value
            }
        }
        self.heading = heading
        title = heading.map { h in
            h.range(of: " - ", options: .backwards).map { String(h[..<$0.lowerBound]) } ?? h
        }
        self.duration = duration
        audioFile = audio
        self.lines = lines
    }

    /// The same file with a new title in its heading; the " - <date>" stamp and
    /// every other byte stay. nil for a blank title or a file without a heading.
    /// One atomic write of this text renames the meeting: file names stay, so the
    /// audio link and the summary card in the vault keep pointing at it.
    public static func renamed(_ markdown: String, to newTitle: String) -> String? {
        let title = newTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let start = markdown.range(of: "# "),
              markdown[..<start.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
        let lineEnd = markdown[start.upperBound...].firstIndex(of: "\n") ?? markdown.endIndex
        let heading = markdown[start.upperBound..<lineEnd]
        let stamp = heading.range(of: " - ", options: .backwards).map { heading[$0.lowerBound...] } ?? ""
        return markdown[..<start.upperBound] + title + stamp + markdown[lineEnd...]
    }

    /// The transcript as text, one line per reply, for copying.
    public var plainTranscript: String {
        lines.map { line in
            line.speaker.map { "[\(line.time)] \($0): \(line.text)" } ?? "[\(line.time)] \(line.text)"
        }.joined(separator: "\n")
    }

    private static func transcriptLine(_ line: String, speakers: [String]) -> MeetingLine? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<close])
        guard let seconds = clockSeconds(time) else { return nil }
        var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        var speaker: String?
        for label in speakers where rest.hasPrefix(label + ":") {
            speaker = label
            rest = String(rest.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
            break
        }
        return MeetingLine(time: time, seconds: seconds, speaker: speaker, text: rest)
    }

    /// "Длительность: 39:22" in any language: a label, a colon, a clock.
    private static func durationLine(_ line: String) -> Int? {
        guard let colon = line.range(of: ": ") else { return nil }
        return clockSeconds(String(line[colon.upperBound...]))
    }

    /// "3:12" or "1:03:12" in seconds.
    private static func clockSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.dropFirst().allSatisfy({ $0.count == 2 }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }
}

/// The first prose paragraph of a summary card: after the frontmatter, not a
/// heading or a list, wikilinks shown by their label.
public enum SummaryLead {
    public static func firstParagraph(of card: String) -> String? {
        var lines = card.components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = lines[(end + 1)...]
            }
        }
        var paragraph: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let prose = !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("-")
                && !line.hasPrefix("*") && !line.hasPrefix("|") && !line.hasPrefix(">")
            if prose {
                paragraph.append(line)
            } else if !paragraph.isEmpty {
                break
            }
        }
        guard !paragraph.isEmpty else { return nil }
        return unwrapLinks(paragraph.joined(separator: " "))
    }

    /// "[[a|b]]" → "b", "[[path/name]]" → "name".
    private static func unwrapLinks(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            out += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            if let bar = inner.firstIndex(of: "|") {
                out += inner[inner.index(after: bar)...]
            } else {
                out += inner.split(separator: "/").last.map(String.init) ?? ""
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

/// Lists by day, newest first.
public enum DayGrouping {
    public struct Group<Item> {
        public let day: Date
        public let items: [Item]
    }

    public enum Relative: Sendable, Equatable {
        case today
        case yesterday
        case earlier
    }

    public static func group<Item>(_ items: [Item], date: (Item) -> Date,
                                   calendar: Calendar = .current) -> [Group<Item>] {
        let sorted = items.sorted { date($0) > date($1) }
        var groups: [Group<Item>] = []
        for item in sorted {
            let day = calendar.startOfDay(for: date(item))
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = Group(day: day, items: last.items + [item])
            } else {
                groups.append(Group(day: day, items: [item]))
            }
        }
        return groups
    }

    public static func relative(_ day: Date, now: Date, calendar: Calendar = .current) -> Relative {
        if calendar.isDate(day, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }
}

/// Search that ignores case, diacritics and the ё/е difference; a blank query
/// matches everything.
public enum TextSearch {
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        return fields.contains { fold($0).contains(needle) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }
}
