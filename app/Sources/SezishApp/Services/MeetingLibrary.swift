import Foundation
import SezishCore

/// One meeting on disk, as the History tab lists it.
nonisolated struct MeetingEntry: Identifiable, Sendable {
    let base: String
    /// Where the meeting's .md is, or would be: a take whose transcript never
    /// got written has a name and an audio file but no document yet.
    let mdURL: URL
    let date: Date
    /// Where the stems of this take are parked, when they are: the retry takes
    /// that directory, so the row carries it instead of the view rebuilding the
    /// hidden name from the base.
    let stemsURL: URL?
    let hasMarkdown: Bool

    var id: String { base }

    /// Stems are still parked next to it, so this take can be recognised again.
    var needsRetry: Bool { stemsURL != nil }
}

/// Reads the meetings folder into a list, newest first.
nonisolated enum MeetingLibrary {
    static func entries(in dir: URL) -> [MeetingEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix = MeetingSalvage.stemsPrefix
        let waiting = Dictionary(
            uniqueKeysWithValues: MeetingSalvage.discoverStems(in: dir)
                .map { (String($0.lastPathComponent.dropFirst(prefix.count)), $0) }
        )
        let written = Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
        // Union, not just the documents: a take whose .md never landed is still a
        // meeting the menu counts, and a list that hides it contradicts the menu.
        return written.union(waiting.keys)
            .map { base in
                let url = dir.appendingPathComponent(base + ".md")
                // The date comes from the name, not from the file: write(atomically:)
                // makes a new inode, so a retranscribed meeting would jump to the
                // top of the list. Renamed by hand: the file's own date will do.
                let date = MeetingFileNamer.date(fromBaseName: base)
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                return MeetingEntry(
                    base: base,
                    mdURL: url,
                    date: date,
                    stemsURL: waiting[base],
                    hasMarkdown: written.contains(base)
                )
            }
            // Names carry only the minute, so two meetings can tie: order them by
            // name to keep the list from reshuffling between reads.
            .sorted { $0.date == $1.date ? $0.base > $1.base : $0.date > $1.date }
    }
}
