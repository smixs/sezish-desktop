import AppKit
import SwiftUI
import SezishCore

/// Everything the app has recorded: dictations from its own history file and
/// meetings straight off the folder. The menu shows the last three takes; this
/// is where the rest of them live, together with the two things the menu has no
/// room for — the reason a take came out empty, and deleting one.
///
/// The window is 620 pt wide at most and the sidebar takes 175 of them, so every
/// row action is an icon with a `.help`, never a labelled button.
struct HistoryPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                if appState.dictations.isEmpty {
                    Text(appState.strings.emptyYet)
                        .foregroundStyle(.secondary)
                } else {
                    // Newest first, like the menu: the take just made is the one
                    // being looked for.
                    ForEach(appState.dictations.reversed()) { record in
                        dictationRow(record)
                    }
                }
            } header: {
                Text(appState.strings.dictations)
            } footer: {
                folderButton(
                    title: appState.strings.openFolder,
                    help: appState.strings.openFolderHelp,
                    url: AppState.historyDirectory
                )
            }

            Section {
                if appState.meetings.isEmpty {
                    Text(appState.strings.emptyYet)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.meetings) { entry in
                        meetingRow(entry)
                    }
                }
            } header: {
                Text(appState.strings.historyMeetings)
            } footer: {
                // No `.help`: the label already says where the button leads.
                folderButton(
                    title: appState.strings.openMeetingsFolder,
                    help: nil,
                    url: MeetingRecorder.meetingsDirectory
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.history.title(appState.strings))
        // Meetings are files, not app state: read them when the tab appears, so a
        // recording deleted in Finder does not linger in the list.
        .task { appState.refreshMeetings() }
    }

    // MARK: - Dictations

    @ViewBuilder private func dictationRow(_ record: DictationRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.date, format: .dateTime.day().month().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(record.needsTranscript ? appState.strings.noTextRow : record.text)
                    .lineLimit(2)
                    .foregroundStyle(record.needsTranscript ? Color.secondary : Color.primary)
                // The reason itself, when there is one worth reading: "empty" and
                // "unknown" are markers for the code, not sentences for a human.
                if let reason = failureReason(record) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(reason)
                }
            }
            Spacer(minLength: 8)

            HStack(spacing: 4) {
                iconButton("waveform", help: appState.strings.revealAudio) {
                    appState.revealAudio(record)
                }
                .disabled(record.audioURL == nil)

                Button {
                    appState.retranscribe(record)
                } label: {
                    if appState.retryingDictation == record.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // One retry at a time, so every row's ↻ goes down together; a
                // take whose WAV is gone has nothing to run again.
                .disabled(appState.retryingDictation != nil || record.audioURL == nil)
                .help(appState.strings.retryTranscription)

                iconButton("trash", help: appState.strings.delete) {
                    appState.deleteDictation(record)
                }
                .disabled(appState.retryingDictation == record.id)
            }
        }
    }

    /// `nil` when the take succeeded, or when the failure has no words in it.
    private func failureReason(_ record: DictationRecord) -> String? {
        guard let error = record.error,
              error != DictationCoordinator.emptyTranscriptReason,
              error != DictationCoordinator.unknownFailureReason
        else { return nil }
        return error
    }

    // MARK: - Meetings

    @ViewBuilder private func meetingRow(_ entry: MeetingEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                Text(entry.base)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Every name starts with "call-" and ends with the minute:
                    // the middle is what gives, not the tail.
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.needsRetry {
                    Text(appState.strings.meetingNeedsRetry)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.accent)
                }
            }
            Spacer(minLength: 8)

            HStack(spacing: 4) {
                iconButton("doc.text", help: appState.strings.revealFile) {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.mdURL])
                }
                .disabled(!entry.hasMarkdown)

                // Only the takes that still have stems: everything else has all
                // the text it will ever have.
                if let stems = entry.stemsURL {
                    Button {
                        appState.retryPendingMeetings(only: stems)
                    } label: {
                        if appState.retryingMeeting == stems {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isRetryingMeetings || appState.status != .idle)
                    .help(appState.strings.retryTranscription)
                }
            }
        }
    }

    // MARK: - Pieces

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    /// Section footers are the one place a labelled button fits: it is alone on
    /// its line and nothing competes with it for the width.
    @ViewBuilder private func folderButton(title: String, help: String?, url: URL?) -> some View {
        if let url {
            let button = Button(title) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .font(.system(size: 11))
            if let help {
                button.help(help)
            } else {
                button
            }
        }
    }
}
