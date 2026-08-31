import SwiftUI
import SezishCore

/// The push-to-talk gesture: hold vs toggle, and the shortcut itself.
struct HotkeyPane: View {
    @Environment(AppState.self) private var appState

    private var holdMode: Bool { appState.hotkeyMode == .hold }

    /// Reads and writes `appState` directly instead of mirroring it in `@State`.
    /// The pane is rebuilt on every sidebar switch, so a mirror would start at its
    /// default, animate to the stored value on `onAppear` and fire `onChange` with
    /// a value the user never touched.
    private var holdModeBinding: Binding<Bool> {
        Binding(
            get: { holdMode },
            set: { appState.setHotkeyMode($0 ? .hold : .toggle) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(appState.strings.holdModeToggle, isOn: holdModeBinding)
                    .toggleStyle(.switch)
                LabeledContent(appState.strings.shortcutLabel) {
                    ShortcutRecorder(
                        currentLabel: appState.currentShortcut.displayLabel(strings: appState.strings),
                        prompt: appState.strings.recorderPrompt,
                        helpText: appState.strings.recorderHelp,
                        needsModifierText: appState.strings.recorderNeedsModifier,
                        onCommit: appState.setShortcut
                    )
                }
            } header: {
                Text(appState.strings.hotkeySection)
            } footer: {
                Text(holdMode
                    ? appState.strings.hotkeyModeHoldHint
                    : appState.strings.hotkeyModeToggleHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.hotkey.title(appState.strings))
    }
}
