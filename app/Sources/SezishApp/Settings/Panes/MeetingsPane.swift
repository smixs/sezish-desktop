import AppKit
import SwiftUI
import SezishCore

/// hex's Meetings page: "Recordings / Settings" in the header, a recording in
/// progress beside them; the list by day with a search on the left, the meeting
/// card on the right. No delete, by Serge's call.
struct MeetingsPane: View {
    @Environment(AppState.self) private var appState
    @State private var tab = Tab.recordings
    @State private var query = ""
    @State private var selection: String?

    enum Tab { case recordings, settings }

    private var s: SettingsStrings { .forLanguage(appState.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch tab {
            case .recordings: recordings
            case .settings: SummaryPane().scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
        .background(Brand.bg)
        // Meetings are files, not app state: read them when the page appears.
        .task { appState.refreshMeetings() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SettingsPageTitle(title: appState.strings.historyMeetings)
            Picker("", selection: $tab) {
                Text(s.recordings).tag(Tab.recordings)
                Text(s.meetingSettings).tag(Tab.settings)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            if appState.isRecordingMeeting { recordingBadge }
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(Brand.red).frame(width: 7, height: 7)
            if let start = appState.meetingStartDate {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Brand.text)
            }
            Button(appState.strings.stopMeeting) { appState.toggleMeetingRecording() }
                .buttonStyle(BrandSecondaryButtonStyle())
        }
    }

    // MARK: - Recordings

    private var recordings: some View {
        let found = appState.meetings.filter {
            TextSearch.matches(query, in: [$0.base, MeetingTitles.shared.head(for: $0)?.title ?? ""])
        }
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                SettingsSearchField(prompt: s.search, text: $query)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if found.isEmpty {
                            Text(appState.meetings.isEmpty ? appState.strings.emptyYet : s.nothingFound)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.muted)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(DayGrouping.group(found, date: \.date), id: \.day) { group in
                            DayHeader(day: group.day, strings: s, locale: locale)
                            ForEach(group.items) { entry in
                                let head = MeetingTitles.shared.head(for: entry)
                                MeetingListRow(entry: entry,
                                               title: head?.title ?? appState.strings.meetingDocTitle,
                                               duration: head?.duration,
                                               selected: selection == entry.id,
                                               retrying: appState.retryingMeeting == entry.stemsURL
                                                   && entry.stemsURL != nil,
                                               strings: s) { selection = entry.id }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 240)

            Group {
                if let entry = appState.meetings.first(where: { $0.id == selection }) {
                    MeetingCard(entry: entry, strings: s, locale: locale)
                        .id(entry.id)
                } else {
                    Text(s.pickMeeting)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: Brand.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.small).strokeBorder(Brand.faint, lineWidth: 1))
            .padding(.bottom, 20)
        }
        .onAppear { if selection == nil { selection = appState.meetings.first?.id } }
    }

    private var locale: Locale { Locale(identifier: appState.language == .uz ? "uz" : "ru") }

}

/// The heading and duration from the top of a meeting file, read once per file
/// version so typing in the search stays cheap. The list shows these, not the
/// file name ("call-2026-11-04-14-00" tells a person nothing).
@MainActor
final class MeetingTitles {
    struct Head { let title: String?; let duration: Int? }
    static let shared = MeetingTitles()
    private var cache: [URL: (Date, Head)] = [:]

    func head(for entry: MeetingEntry) -> Head? {
        guard entry.hasMarkdown else { return nil }
        let modified = (try? entry.mdURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let (stamp, head) = cache[entry.mdURL], stamp == modified { return head }
        let text = (try? FileHandle(forReadingFrom: entry.mdURL))
            .flatMap { handle in defer { try? handle.close() }; return try? handle.read(upToCount: 512) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        // Only the lines above the transcript: a cut multibyte tail cannot matter.
        let top = text.components(separatedBy: "\n").prefix(5).joined(separator: "\n")
        let doc = MeetingDocument(markdown: top, speakers: [])
        let head = Head(title: doc.title, duration: doc.duration)
        cache[entry.mdURL] = (modified, head)
        return head
    }
}

private struct MeetingListRow: View {
    let entry: MeetingEntry
    let title: String
    let duration: Int?
    let selected: Bool
    let retrying: Bool
    let strings: SettingsStrings
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.text)
                        .lineLimit(1)
                    if entry.needsRetry {
                        Text(strings.noTranscript).font(.system(size: 11)).foregroundStyle(Brand.red)
                    } else if let duration {
                        Text(duration >= 60 ? "\(duration / 60) \(strings.minutes)" : "<1 \(strings.minutes)")
                            .font(.system(size: 11)).foregroundStyle(Brand.muted)
                    }
                }
                Spacer(minLength: 6)
                if retrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Brand.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Brand.hover : hovering ? Brand.hover.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Brand.Radius.tiny))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Card

private struct MeetingCard: View {
    @Environment(AppState.self) private var appState
    let entry: MeetingEntry
    let strings: SettingsStrings
    let locale: Locale
    @State private var document: MeetingDocument?
    @State private var summary: (lead: String, url: URL)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(document?.title ?? appState.strings.meetingDocTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.text)
                        .textSelection(.enabled)
                    Text(meta).font(.system(size: 11)).foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 8)
                toolbar
            }
            .padding(16)
            BrandDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary { summaryBlock(summary) }
                    transcriptBlock
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: entry.mdURL) { await load() }
    }

    private var meta: String {
        var parts = [entry.date.formatted(.dateTime.day().month(.wide).hour().minute().locale(locale))]
        if let duration = document?.duration {
            parts.append(duration >= 60 ? "\(duration / 60) \(strings.minutes)" : "<1 \(strings.minutes)")
        }
        return parts.joined(separator: " · ")
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            tool(copied ? "checkmark" : "doc.on.doc", help: strings.copyTranscript) {
                guard let text = document?.plainTranscript, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .disabled(document?.lines.isEmpty ?? true)
            tool("folder", help: strings.showInFinder) {
                let audio = document?.audioFile.map { entry.mdURL.deletingLastPathComponent().appendingPathComponent($0) }
                let target = entry.hasMarkdown ? entry.mdURL : audio ?? entry.mdURL.deletingLastPathComponent()
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            // A take without text is recognised again from its parked stems; one
            // with text can only have its summary run again.
            if let stems = entry.stemsURL {
                tool("arrow.clockwise", help: strings.retryTranscript) {
                    appState.retryPendingMeetings(only: stems)
                }
                .disabled(appState.isRetryingMeetings || appState.status != .idle)
            } else if entry.hasMarkdown, appState.settings.summaryEnabled {
                tool("sparkles", help: strings.retrySummary) {
                    appState.retrySummary(meetingMd: entry.mdURL)
                }
            }
        }
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(Brand.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func summaryBlock(_ summary: (lead: String, url: URL)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strings.summary).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.muted)
                Spacer()
                Button(strings.openSummary) { NSWorkspace.shared.open(summary.url) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Text(summary.lead)
                .font(.system(size: 13))
                .foregroundStyle(Brand.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.transcript).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.muted)
            if let document, !document.lines.isEmpty {
                ForEach(Array(document.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let speaker = line.speaker {
                                Text(speaker).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isMe(speaker) ? Brand.accent : Brand.text)
                            }
                            Text(line.time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Brand.muted)
                        }
                        Text(line.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if document != nil || !entry.hasMarkdown {
                Text(strings.noTranscript).font(.system(size: 12)).foregroundStyle(Brand.muted)
            }
        }
    }

    private func isMe(_ speaker: String) -> Bool {
        speaker == Strings.ru.meetingSpeakerMe || speaker == Strings.uz.meetingSpeakerMe
    }

    /// The file and the summary card are read off the main thread.
    private func load() async {
        let md = entry.mdURL
        let base = entry.base
        let notes = appState.settings.notesFolder
        let speakers = [Strings.ru.meetingSpeakerMe, Strings.ru.meetingSpeakerThem,
                        Strings.uz.meetingSpeakerMe, Strings.uz.meetingSpeakerThem]
        let loaded = await Task.detached(priority: .userInitiated) { () -> (MeetingDocument?, (String, URL)?) in
            let doc = (try? String(contentsOf: md, encoding: .utf8)).map {
                MeetingDocument(markdown: $0, speakers: speakers)
            }
            let card = notes?.appendingPathComponent(SummaryVault.subdirectory)
                .appendingPathComponent(SummaryVault.meetingsDir)
                .appendingPathComponent(base + ".md")
            let lead = card.flatMap { url in
                (try? String(contentsOf: url, encoding: .utf8))
                    .flatMap(SummaryLead.firstParagraph(of:)).map { ($0, url) }
            }
            return (doc, lead)
        }.value
        document = loaded.0
        summary = loaded.1.map { (lead: $0.0, url: $0.1) }
    }
}
