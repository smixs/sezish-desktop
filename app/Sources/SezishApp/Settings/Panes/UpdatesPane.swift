import SwiftUI
import SezishCore

/// Sparkle's user-facing surface: version, the automatic check, and a manual one.
struct UpdatesPane: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updater: UpdaterModel

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(appState.strings.updatesVersion, value: appVersion)
                Toggle(appState.strings.updatesAutoCheck, isOn: autoCheckBinding)
                    .toggleStyle(.switch)
                Button(appState.strings.checkUpdates) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.updates.title(appState.strings))
    }

    /// Sparkle owns the flag; the toggle proxies it instead of keeping a mirror
    /// that could drift from what the updater actually does.
    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }
}
