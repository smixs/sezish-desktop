import SwiftUI
import SezishCore

/// Accessibility and Microphone status, live off the 1 s permission poll.
struct PermissionsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                statusRow(
                    title: appState.strings.accessibility,
                    ok: appState.accessibilityTrusted,
                    okText: appState.strings.granted,
                    failText: appState.strings.neededForHotkey
                ) {
                    Button(appState.strings.openSystemSettings,
                           action: appState.openAccessibilitySettings)
                        .buttonStyle(.bordered)
                }
                // Granted but the tap still won't install: only a relaunch cures it.
                if appState.needsRestart { restartBanner }
                statusRow(
                    title: appState.strings.microphone,
                    ok: appState.microphoneAuthorized,
                    okText: appState.strings.granted,
                    failText: appState.strings.neededForSpeech
                ) {
                    Button(appState.strings.allow, action: appState.requestMicrophone)
                        .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.permissions.title(appState.strings))
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Brand.accent)
            Text(appState.strings.restartBannerText)
                .font(.system(size: 11))
            Spacer()
            Button(appState.strings.restart, action: appState.relaunch)
                .buttonStyle(.borderedProminent)
        }
        .listRowBackground(Brand.accent.opacity(0.08))
    }

    private func statusRow(
        title: String,
        ok: Bool,
        okText: String,
        failText: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Brand.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(ok ? okText : failText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { action() }
        }
    }
}
