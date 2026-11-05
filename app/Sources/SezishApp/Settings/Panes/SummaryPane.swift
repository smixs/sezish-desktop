import AppKit
import SwiftUI
import SezishCore

/// Meeting summaries: whether they run, which CLI writes them, and everything that
/// CLI still needs — install and sign-in included, so the user never opens a
/// terminal to get here.
///
/// The pane holds no logic of its own: `SummarySetupModel` owns the state machine
/// and this is a switch over `model.phase`.
struct SummaryPane: View {
    @Environment(AppState.self) private var appState

    @State private var model = SummarySetupModel(openURL: { NSWorkspace.shared.open($0) })
    /// Not a settings mirror (see the bindings below) — a scratch buffer for the
    /// browser fallback's paste field.
    @State private var pastedCode = ""

    var body: some View {
        Form {
            // Recording and the notes folder live here with the summary: every
            // setting about meetings in one place (hex's Meetings › Settings).
            Section {
                Toggle(appState.strings.autoRecordCalls, isOn: autoRecordBinding)
                LabeledContent {
                    Button(appState.strings.choose, action: chooseNotesFolder)
                        .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.strings.notesFolder)
                        Text(appState.settings.notesFolder?.path ?? appState.strings.notSelected)
                            .font(.system(size: 11).monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                .id(notesFolderVersion)
            }
            .toggleStyle(.switch)

            Section {
                Toggle(appState.strings.summaryToggle, isOn: summaryEnabledBinding)
                    .toggleStyle(.switch)
            }

            Section {
                Picker(selection: engineBinding) {
                    option(title: "Claude Code", subtitle: appState.strings.summaryEngineClaude)
                        .tag(SummaryEngineKind.claude)
                    option(title: "Codex", subtitle: appState.strings.summaryEngineCodex)
                        .tag(SummaryEngineKind.codex)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section {
                status
            } footer: {
                logFooter
            }

            // The reminder under the summary, where its absence bites.
            if appState.settings.notesFolder == nil {
                Section {
                    Label {
                        Text(appState.strings.summaryNoNotesFolder)
                            .font(.system(size: 11))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh(engine: appState.settings.summaryEngine) }
    }

    // MARK: - Bindings

    /// Reads and writes `AppSettings` directly instead of mirroring it in `@State`,
    /// per the old Hotkey pane idiom: the pane is rebuilt on every sidebar switch, so a
    /// mirror would start at its default and fire `onChange` with a value the user
    /// never touched. `AppSettings` is a reference type over UserDefaults, so every
    /// render reads the stored truth and no copy can drift from it.
    private var autoRecordBinding: Binding<Bool> {
        Binding(get: { appState.autoRecordMeetings }, set: { appState.setAutoRecordMeetings($0) })
    }

    /// The folder is read straight off settings on every draw; a choice re-renders
    /// through `notesFolderVersion`.
    @State private var notesFolderVersion = 0

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = appState.strings.choosePrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.settings.notesFolder = url
        notesFolderVersion += 1
        // Meetings already summarized into this vault take their cards' titles now.
        appState.nameSummarizedMeetings()
    }

    private var summaryEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.summaryEnabled },
            set: { appState.settings.summaryEnabled = $0 }
        )
    }

    /// Same idiom, plus the probe: a different engine is a different install, a
    /// different account and a different status to show.
    private var engineBinding: Binding<SummaryEngineKind> {
        Binding(
            get: { appState.settings.summaryEngine },
            set: { engine in
                appState.settings.summaryEngine = engine
                Task { await model.refresh(engine: engine) }
            }
        )
    }

    private func option(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .unknown, .probing:
            busy(appState.strings.summaryChecking)

        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.strings.summaryNotInstalled)
                Button(appState.strings.summaryInstall) {
                    Task { await model.install(engine: appState.settings.summaryEngine) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .installing:
            busy(appState.strings.summaryInstalling)

        case .installed(let version):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(appState.strings.summaryNeedsLogin)
                    Spacer(minLength: 0)
                    versionTag(version)
                }
                Button(appState.strings.summaryLogin) {
                    model.login(engine: appState.settings.summaryEngine)
                }
                .buttonStyle(.borderedProminent)
            }

        case .loggingIn(let authURL):
            VStack(alignment: .leading, spacing: 6) {
                busy(appState.strings.summaryWaitingBrowser)
                HStack {
                    if let authURL {
                        Button(appState.strings.summaryOpenAgain) {
                            NSWorkspace.shared.open(authURL)
                        }
                    }
                    Button(appState.strings.summaryEnterCode) { model.revealCodeEntry() }
                    Button(appState.strings.summaryCancel) { model.cancelLogin() }
                }
            }

        case .awaitingCode:
            VStack(alignment: .leading, spacing: 6) {
                TextField(appState.strings.summaryEnterCode, text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(appState.strings.summaryConfirm) {
                        model.submitPastedCode(pastedCode)
                        pastedCode = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(appState.strings.summaryCancel) { model.cancelLogin() }
                }
            }

        case .deviceCode(let url, let code):
            VStack(alignment: .leading, spacing: 6) {
                // The code is the thing the user has to retype, so it gets the size
                // and a selection handle for the copy-paste route.
                Text(code)
                    .font(.system(size: 22, weight: .semibold).monospaced())
                    .textSelection(.enabled)
                Text(appState.strings.summaryDeviceCodeHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(url)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    if let page = URL(string: url) {
                        Button(appState.strings.summaryOpen) { NSWorkspace.shared.open(page) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(appState.strings.summaryCancel) { model.cancelLogin() }
                }
            }

        case .ready(let version):
            Label {
                HStack(spacing: 8) {
                    Text(appState.strings.summaryReady)
                    Spacer(minLength: 0)
                    versionTag(version)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.strings.summaryFailed)
                    .foregroundStyle(Brand.red)
                // The CLI's own words: "не получилось" alone explains nothing.
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button(appState.strings.summaryRetry) {
                    Task { await model.refresh(engine: appState.settings.summaryEngine) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
        }
    }

    private func versionTag(_ version: String) -> some View {
        Text("v\(version)")
            .font(.system(size: 11).monospaced())
            .foregroundStyle(.secondary)
    }

    /// The last few lines the CLIs printed. Enough to tell a stall from a failure
    /// while an install runs, and small enough to ignore once it worked.
    @ViewBuilder private var logFooter: some View {
        if !model.logLines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                // Indexed, not keyed by the line: two identical lines in a row are
                // normal output, and identical ids are not.
                ForEach(Array(model.logLines.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
