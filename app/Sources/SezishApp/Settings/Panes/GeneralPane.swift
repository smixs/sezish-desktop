import AppKit
import ServiceManagement
import SwiftUI
import SezishCore

/// hex's General page: missing permissions on top, one card of everyday rows,
/// the rare ones under "Advanced ▸". Recognition opens as a sub-page.
struct GeneralPane: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updater: UpdaterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var playSounds = true
    @State private var soundVolume = 0.5
    @State private var launchAtLogin = false
    @State private var showAdvanced = false
    @State private var showSecureInputFix = false

    private var s: SettingsStrings { .forLanguage(appState.language) }
    private var permissionsMissing: Bool {
        !appState.accessibilityTrusted || !appState.microphoneAuthorized || appState.needsRestart
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsPageTitle(title: appState.strings.general)
                if permissionsMissing { permissions }
                if let line = appState.secureInputLine { secureInput(line) }
                mainCard
                advancedToggle
                if showAdvanced { advancedCard.transition(.opacity) }
            }
            .padding(20)
            .animation(reduceMotion ? nil : .brandExpoOutFast, value: showAdvanced)
            .animation(.brandExpoOutFast, value: permissionsMissing)
            .animation(.brandExpoOutFast, value: appState.secureInputHolder)
        }
        .background(Brand.bg)
        .onAppear(perform: syncFromStorage)
    }

    // MARK: - Secure Input

    /// The hotkey is dead while another app holds Secure Input; the fix is in that app.
    private func secureInput(_ line: String) -> some View {
        SettingsCard {
            SettingsRow(icon: "lock.fill", title: line, divider: false) {
                Button(appState.strings.secureInputFix) { showSecureInputFix.toggle() }
                    .buttonStyle(BrandSecondaryButtonStyle())
                    .popover(isPresented: $showSecureInputFix, arrowEdge: .bottom) {
                        Text(appState.strings.secureInputHelp)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 280)
                            .padding(14)
                    }
            }
        }
    }

    // MARK: - Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionLabel(title: s.permissionsNeeded)
            SettingsCard {
                if !appState.microphoneAuthorized {
                    SettingsRow(icon: "mic", title: appState.strings.microphone,
                                hint: appState.strings.neededForSpeech,
                                divider: !appState.accessibilityTrusted || appState.needsRestart) {
                        Button(appState.strings.allow, action: appState.requestMicrophone)
                            .buttonStyle(BrandSecondaryButtonStyle())
                    }
                }
                if !appState.accessibilityTrusted {
                    SettingsRow(icon: "character.cursor.ibeam", title: appState.strings.accessibility,
                                hint: appState.strings.neededForHotkey, divider: false) {
                        // The tour owns the guide and "Still grey? Fix it".
                        Button(appState.strings.allow, action: appState.showOnboarding)
                            .buttonStyle(BrandSecondaryButtonStyle())
                    }
                } else if appState.needsRestart {
                    SettingsRow(icon: "arrow.clockwise", title: appState.strings.accessibility,
                                hint: appState.strings.restartBannerText, divider: false) {
                        Button(appState.strings.restart, action: appState.relaunch)
                            .buttonStyle(BrandPrimaryButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    // MARK: - Everyday

    private var mainCard: some View {
        SettingsCard {
            SettingsRow(icon: "keyboard", title: appState.strings.shortcutLabel) {
                ShortcutRecorder(
                    currentLabel: appState.currentShortcut.displayLabel(strings: appState.strings),
                    prompt: appState.strings.recorderPrompt,
                    helpText: appState.strings.recorderHelp,
                    needsModifierText: appState.strings.recorderNeedsModifier,
                    onCommit: appState.setShortcut
                )
            }
            SettingsRow(icon: "hand.raised", title: s.shortcutMode,
                        hint: appState.hotkeyMode == .hold
                            ? appState.strings.hotkeyModeHoldHint : appState.strings.hotkeyModeToggleHint) {
                Picker("", selection: hotkeyModeBinding) {
                    Text(s.modeHold).tag(HotkeyMode.hold)
                    Text(s.modeToggle).tag(HotkeyMode.toggle)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsLinkRow(icon: "waveform", title: appState.strings.recognition, value: engineName) {
                RecognitionPane()
            }
            SettingsRow(icon: "waveform.path", title: appState.strings.waveIntensity) {
                Picker("", selection: waveBinding) {
                    Text(appState.strings.waveCalm).tag(WaveIntensity.calm)
                    Text(appState.strings.waveLively).tag(WaveIntensity.lively)
                    Text(appState.strings.waveBold).tag(WaveIntensity.bold)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRow(icon: "speaker.wave.2", title: appState.strings.soundsToggle) {
                HStack(spacing: 10) {
                    // The volume is heard on release, at the new level.
                    Slider(value: $soundVolume, in: 0...1) { editing in
                        if !editing { appState.setSoundVolume(soundVolume) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)
                    .disabled(!playSounds)
                    .opacity(playSounds ? 1 : 0.4)
                    .help(s.soundVolume)
                    .accessibilityLabel(s.soundVolume)
                    Toggle("", isOn: $playSounds)
                        .labelsHidden()
                        .onChange(of: playSounds) { _, value in appState.setSoundsEnabled(value) }
                }
            }
            SettingsRow(icon: "power", title: appState.strings.launchAtLogin, divider: false) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, value in
                        // `syncFromStorage` also writes this state, and re-registering an
                        // enabled login item re-triggers the system's background notice.
                        guard value != (SMAppService.mainApp.status == .enabled) else { return }
                        setLaunchAtLogin(value)
                    }
            }
        }
        .toggleStyle(.switch)
    }

    private var engineName: String {
        switch appState.effectiveTranscriptionMode {
        case .cloud: appState.strings.cloudTitle
        case .local: appState.strings.localTitle
        case .gemini: appState.strings.geminiTitle
        }
    }

    // MARK: - Advanced

    private var advancedToggle: some View {
        Button { showAdvanced.toggle() } label: {
            HStack(spacing: 4) {
                Text(s.advanced)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.muted)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var advancedCard: some View {
        SettingsCard {
            SettingsRow(icon: "globe", title: appState.strings.language) {
                Picker("", selection: languageBinding) {
                    Text("Oʼzbekcha").tag(AppLanguage.uz)
                    Text("Русский").tag(AppLanguage.ru)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRow(icon: "eye.slash", title: appState.strings.launchHiddenToggle,
                        hint: appState.strings.launchHiddenHint) {
                Toggle("", isOn: launchHiddenBinding).labelsHidden()
            }
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: appState.strings.updatesAutoCheck) {
                Toggle("", isOn: autoCheckBinding).labelsHidden()
            }
            Button(action: appState.showOnboarding) {
                SettingsRow(icon: "sparkles", title: OnboardingStrings.forLanguage(appState.language).runAgain,
                            divider: false) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .toggleStyle(.switch)
    }

    // MARK: - Bindings

    /// Applies live: the next frame of a running dictation already uses it.
    private var waveBinding: Binding<WaveIntensity> {
        Binding(get: { appState.levelMeter.intensity }, set: { appState.setWaveIntensity($0) })
    }

    private var hotkeyModeBinding: Binding<HotkeyMode> {
        Binding(get: { appState.hotkeyMode }, set: { appState.setHotkeyMode($0) })
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { appState.language }, set: { appState.setLanguage($0) })
    }

    /// Read only at launch, so a binding straight over storage is enough — no mirror.
    private var launchHiddenBinding: Binding<Bool> {
        Binding(get: { appState.settings.launchHidden }, set: { appState.settings.launchHidden = $0 })
    }

    /// Sparkle owns the flag; the toggle proxies it instead of keeping a mirror.
    private var autoCheckBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 })
    }

    private func syncFromStorage() {
        playSounds = appState.settings.playSounds
        soundVolume = appState.settings.soundVolume
        // Login-item state is never cached — always read live from the system.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Revert the toggle to the real system state on failure.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
