import AppKit
import ServiceManagement
import SwiftUI
import SezishCore

/// Language, the three everyday switches and the notes folder.
struct GeneralPane: View {
    @Environment(AppState.self) private var appState

    @State private var autoRecordMeetings = false
    @State private var playSounds = true
    @State private var launchAtLogin = false
    @State private var notesFolder: URL?

    var body: some View {
        Form {
            Section {
                Picker(appState.strings.language, selection: languageBinding) {
                    Text("Oʼzbekcha").tag(AppLanguage.uz)
                    Text("Русский").tag(AppLanguage.ru)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(appState.strings.autoRecordCalls, isOn: $autoRecordMeetings)
                    .onChange(of: autoRecordMeetings) { _, value in
                        appState.setAutoRecordMeetings(value)
                    }
                Toggle(appState.strings.launchAtLogin, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        // `syncFromStorage` also writes this state, and that write
                        // fires `onChange` too. Re-registering an already-enabled
                        // login item re-triggers the system's "added items that can
                        // run in background" notice, so only act on a real flip.
                        guard value != (SMAppService.mainApp.status == .enabled) else { return }
                        setLaunchAtLogin(value)
                    }
                Toggle(appState.strings.launchHiddenToggle, isOn: launchHiddenBinding)
                Toggle(appState.strings.soundsToggle, isOn: $playSounds)
                    .onChange(of: playSounds) { _, value in
                        appState.setSoundsEnabled(value)
                    }
            } footer: {
                Text(appState.strings.launchHiddenHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)

            Section(appState.strings.notesFolder) {
                LabeledContent {
                    Button(appState.strings.choose, action: chooseNotesFolder)
                        .buttonStyle(.bordered)
                } label: {
                    Text(notesFolder?.path ?? appState.strings.notSelected)
                        .font(.system(size: 12).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(notesFolder == nil ? .secondary : .primary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.general.title(appState.strings))
        .onAppear(perform: syncFromStorage)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { appState.language }, set: { appState.setLanguage($0) })
    }

    /// Read only at launch, so a binding straight over storage is enough — no mirror.
    private var launchHiddenBinding: Binding<Bool> {
        Binding(get: { appState.settings.launchHidden }, set: { appState.settings.launchHidden = $0 })
    }

    private func syncFromStorage() {
        autoRecordMeetings = appState.settings.autoRecordMeetings
        playSounds = appState.settings.playSounds
        notesFolder = appState.settings.notesFolder
        // Login-item state is never cached — always read live from the system.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle to the real system state on failure.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = appState.strings.choosePrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        notesFolder = url
        appState.settings.notesFolder = url
    }
}
