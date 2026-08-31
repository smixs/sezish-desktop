import AppKit
import SwiftUI
import SezishCore

@main
struct SezishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appState)
                .environmentObject(delegate.updater)
        } label: {
            // The label is alive from launch, so it doubles as the "open Settings
            // on manual launch / on reopen" hook (the menu content is not).
            MenuBarLabel(isRecording: appState.isRecordingMeeting,
                         launchedAsLoginItem: delegate.launchedAsLoginItem,
                         launchHidden: appState.settings.launchHidden)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environment(appState)
                .environmentObject(delegate.updater)
        }
    }
}

private struct MenuBarLabel: View {
    let isRecording: Bool
    let launchedAsLoginItem: Bool
    /// The user's "start hidden" switch, read once at launch.
    let launchHidden: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        icon
            .task {
                guard !launchedAsLoginItem, !launchHidden else { return }
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sezishShowSettings)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }

    @ViewBuilder private var icon: some View {
        if isRecording {
            Image(systemName: "waveform.circle.fill")
        } else if let brand = moduleResources.image(forResource: "MenuBarIcon") {
            // Template glyph (brand S-wave): black+alpha, system tints it per menu bar theme.
            Image(nsImage: { brand.isTemplate = true; return brand }())
        } else {
            Image(systemName: "waveform")
        }
    }
}

private struct MenuContent: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updater: UpdaterModel
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                appState.toggleMeetingRecording()
            } label: {
                Label {
                    Text(meetingButtonTitle)
                        .foregroundStyle(Brand.text)
                } icon: {
                    Image(systemName: meetingButtonIcon)
                        .foregroundStyle(appState.status == .processingMeeting
                                         ? AnyShapeStyle(Brand.muted) : AnyShapeStyle(Brand.gradient))
                        .symbolEffect(.pulse, isActive: appState.isRecordingMeeting)
                }
            }
            .buttonStyle(BrandRowButtonStyle())
            .disabled(appState.status == .processingMeeting)

            // Meetings whose stems are still parked: the only place the user is
            // told a take is waiting for a second attempt.
            if !appState.pendingMeetings.isEmpty {
                Button {
                    appState.retryPendingMeetings()
                } label: {
                    Label {
                        Text(String(format: appState.strings.meetingsPending,
                                    appState.pendingMeetings.count))
                            .foregroundStyle(Brand.text)
                    } icon: {
                        if appState.isRetryingMeetings {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise").foregroundStyle(Brand.muted)
                        }
                    }
                }
                .buttonStyle(BrandRowButtonStyle())
                .disabled(appState.isRetryingMeetings || appState.status != .idle)
                // The label counts them; the verb lives here, where a 280 pt menu
                // row has room for it.
                .help(appState.strings.retryTranscription)
            }

            BrandDivider().padding(.vertical, 4)

            // Cloud mode needs no model — the download section is a local-mode affair.
            if appState.usesLocalTranscription {
                ModelSection()
            }

            HStack {
                BrandSectionHeader(appState.strings.dictations)
                Spacer()
                Button(appState.strings.openFolder) { openHistoryFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .help(appState.strings.openFolderHelp)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            if appState.dictations.isEmpty {
                Text(appState.strings.emptyYet)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.muted)
                    .padding(.horizontal, 8)
            } else {
                if let last = appState.dictations.last, !last.text.isEmpty {
                    Button {
                        copy(last.text)
                    } label: {
                        Label {
                            Text(appState.strings.copyLast).foregroundStyle(Brand.text)
                        } icon: {
                            Image(systemName: "doc.on.doc").foregroundStyle(Brand.muted)
                        }
                    }
                    .buttonStyle(BrandRowButtonStyle())
                }
                ForEach(appState.dictations.suffix(3).reversed()) { record in
                    // Siblings, not nested: a .plain button inside the row style
                    // drives the row's own hover and press highlight.
                    HStack(spacing: 4) {
                        Button {
                            record.needsTranscript
                                ? appState.retranscribe(record)
                                : copy(record.text)
                        } label: {
                            Text(record.needsTranscript
                                 ? appState.strings.noTextRow
                                 : Self.trimmed(record.text))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .font(.system(size: 12))
                                .foregroundStyle(record.needsTranscript ? Brand.muted : Brand.text)
                        }
                        .buttonStyle(BrandRowButtonStyle())
                        // The empty row's own click is a retry, so it goes down
                        // with the ↻ buttons; a row with text still copies.
                        .disabled(record.needsTranscript
                                  && (appState.retryingDictation != nil || record.audioURL == nil))
                        .help(record.needsTranscript
                              ? appState.strings.noTextRowHelp
                              : appState.strings.copyRowHelp)

                        Button {
                            appState.retranscribe(record)
                        } label: {
                            if appState.retryingDictation == record.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        // A glyph is a few points wide; the click target is the cell.
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        // One retry at a time, so every row's ↻ goes down together; a
                        // take whose WAV is gone has nothing to run again.
                        .disabled(appState.retryingDictation != nil || record.audioURL == nil)
                        .help(appState.strings.retryTranscription)

                        Button {
                            appState.revealAudio(record)
                        } label: {
                            Image(systemName: "waveform")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        // Records from an older index.json carry no WAV.
                        .disabled(record.audioURL == nil)
                        .help(appState.strings.revealAudio)
                    }
                    // Lines the icons up with the "Открыть папку" of the header.
                    .padding(.trailing, 8)
                }
                Text(appState.strings.rowHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.muted.opacity(0.7))
                    .padding(.horizontal, 8)
            }

            BrandDivider().padding(.vertical, 4)

            SettingsLink {
                Label {
                    Text(appState.strings.settingsItem).foregroundStyle(Brand.text)
                } icon: {
                    Image(systemName: "gearshape").foregroundStyle(Brand.muted)
                }
            }
            .buttonStyle(BrandRowButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })

            Button {
                updater.checkForUpdates()
            } label: {
                Label {
                    HStack {
                        Text(appState.strings.checkUpdates).foregroundStyle(Brand.text)
                        Spacer()
                        Text("v" + appVersion)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Brand.muted)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Brand.muted)
                }
            }
            .buttonStyle(BrandRowButtonStyle())
            .disabled(!updater.canCheckForUpdates)

            BrandDivider().padding(.vertical, 4)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label {
                    Text(appState.strings.quit).foregroundStyle(Brand.text)
                } icon: {
                    Image(systemName: "power").foregroundStyle(Brand.muted)
                }
            }
            .buttonStyle(BrandRowButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(8)
        .frame(width: 280)
        .background(Brand.bg)
    }

    private var meetingButtonTitle: String {
        switch appState.status {
        case .idle: appState.strings.startMeeting
        case .recordingMeeting: appState.strings.stopMeeting
        case .processingMeeting: appState.strings.meetingProcessing
        }
    }

    private var meetingButtonIcon: String {
        switch appState.status {
        case .idle: "record.circle"
        case .recordingMeeting: "stop.circle.fill"
        case .processingMeeting: "waveform.badge.magnifyingglass"
        }
    }

    private static func trimmed(_ text: String, limit: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openHistoryFolder() {
        guard let dir = AppState.historyDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

}

/// Model download / progress row, shown until the model is on disk and ready.
private struct ModelSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.modelPhase {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appState.strings.downloadingModel)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    Text("\(Int(fraction * 100)) %")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Brand.muted)
                }
                BrandProgressBar(fraction: fraction)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            BrandDivider().padding(.vertical, 4)
        case .missing, .failed:
            Button {
                appState.downloadModel()
            } label: {
                Label(appState.strings.downloadModel, systemImage: "arrow.down.circle")
            }
            .buttonStyle(BrandPrimaryButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            if case .failed(let message) = appState.modelPhase {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.red)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
            BrandDivider().padding(.vertical, 4)
        }
    }
}
