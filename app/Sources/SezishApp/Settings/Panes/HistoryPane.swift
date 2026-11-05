import AppKit
import SwiftUI
import SezishCore

/// Dictations, newest first, grouped by day, with a search over the text. Meetings
/// have their own section now. A row copies on hover; a failed take keeps its
/// reason and can be recognised again; any take with audio can be heard.
struct HistoryPane: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var player: NSSound?
    @State private var playing: UUID?

    private var s: SettingsStrings { .forLanguage(appState.language) }
    private var locale: Locale { Locale(identifier: appState.language == .uz ? "uz" : "ru") }

    var body: some View {
        let found = appState.dictations.filter { TextSearch.matches(query, in: [$0.text, $0.error ?? ""]) }
        let groups = DayGrouping.group(found, date: \.date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsPageTitle(title: appState.strings.paneHistory)
                Spacer()
                if let dir = AppState.historyDirectory {
                    Button(appState.strings.openFolder) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help(appState.strings.openFolderHelp)
                }
            }
            SettingsSearchField(prompt: s.search, text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty {
                        Text(appState.dictations.isEmpty ? appState.strings.emptyYet : s.nothingFound)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(groups, id: \.day) { group in
                        DayHeader(day: group.day, strings: s, locale: locale)
                        SettingsCard {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, record in
                                DictationRow(record: record, strings: s,
                                             playing: playing == record.id,
                                             divider: index < group.items.count - 1,
                                             onPlay: { play(record) })
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(20)
        .background(Brand.bg)
        .onDisappear { player?.stop() }
    }

    /// Plays the take's WAV; a second click on the same row stops it.
    private func play(_ record: DictationRecord) {
        player?.stop()
        guard playing != record.id, let url = record.audioURL, let sound = NSSound(contentsOf: url, byReference: true)
        else { playing = nil; return }
        player = sound
        playing = record.id
        sound.play()
        let duration = sound.duration
        let id = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            if playing == id { playing = nil }
        }
    }
}

private struct DictationRow: View {
    @Environment(AppState.self) private var appState
    let record: DictationRecord
    let strings: SettingsStrings
    let playing: Bool
    let divider: Bool
    let onPlay: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Brand.muted)
                    .frame(width: 38, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.needsTranscript ? appState.strings.noTextRow : record.text)
                        .font(.system(size: 13))
                        .foregroundStyle(record.needsTranscript ? Brand.muted : Brand.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if let reason = failureReason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.red)
                            .lineLimit(2)
                            .help(reason)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            if divider { BrandDivider().padding(.leading, 62) }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if record.needsTranscript {
                icon(appState.retryingDictation == record.id ? nil : "arrow.clockwise",
                     help: appState.strings.retryTranscription) { appState.retranscribe(record) }
                    .disabled(appState.retryingDictation != nil || record.audioURL == nil)
            } else if hovering || copied {
                icon(copied ? "checkmark" : "doc.on.doc", help: copied ? strings.copied : strings.copy) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(record.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            }
            if hovering || playing, record.audioURL != nil {
                icon(playing ? "stop.fill" : "play.fill", help: strings.listen, action: onPlay)
            }
            if hovering {
                icon("trash", help: appState.strings.delete) { appState.deleteDictation(record) }
                    .disabled(appState.retryingDictation == record.id)
            }
        }
        .frame(minWidth: 60, alignment: .trailing)
    }

    /// nil symbol draws a spinner in its place.
    private func icon(_ symbol: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(Brand.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// `nil` when the take succeeded, or when the failure has no words in it.
    private var failureReason: String? {
        guard let error = record.error,
              error != DictationCoordinator.emptyTranscriptReason,
              error != DictationCoordinator.unknownFailureReason
        else { return nil }
        return error
    }
}
