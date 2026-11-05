import SwiftUI
import SezishCore

/// The first-run tour: hex's structure and motion, sezish's colors and accent.
/// One centered column per screen, a quiet language switch at the bottom.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let controller: OnboardingController

    private var s: OnboardingStrings { controller.strings }
    private var flow: OnboardingFlow { controller.flow }

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            Group {
                switch flow.step {
                case .permissions: PermissionsScreen(controller: controller)
                case .engine: EngineScreen(controller: controller)
                case .done, .finished: DoneScreen(controller: controller)
                }
            }
            .id(flow.step)
            .transition(reduceMotion ? .opacity
                : .opacity.combined(with: .offset(y: 8)))
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) { downloadPill.padding(.top, 14) }
        .overlay(alignment: .bottom) { bottomBar.padding(.horizontal, 20).padding(.bottom, 16) }
        .animation(.brandExpoOut, value: flow.step)
        .frame(width: 560, height: 480)
    }

    /// Download progress follows the whole tour, above whatever screen is up.
    @ViewBuilder private var downloadPill: some View {
        if flow.step != .engine, case .downloading(let fraction) = flow.model {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(s.downloading).font(.system(size: 11, weight: .medium))
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Brand.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Brand.bgSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.faint, lineWidth: 1))
            .transition(.opacity)
        }
    }

    private var bottomBar: some View {
        HStack {
            LanguageSwitch()
            Spacer()
            if flow.step == .engine || flow.step == .done {
                Button(s.back, action: controller.back)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.muted)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Shared pieces

private struct Heading: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Brand.text)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 480)
    }
}

/// One bordered card of rows separated by hairlines.
private struct RowCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: Brand.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.small)
                .strokeBorder(Brand.faint, lineWidth: 1))
            .frame(maxWidth: 460)
    }
}

private struct CardRow<Trailing: View>: View {
    let icon: String
    let title: String
    let hint: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.text)
                Text(hint).font(.system(size: 11)).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct AllowedMark: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.green)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// The row's action: the first row still to do carries the brand accent.
private struct RowButton: View {
    let title: String
    let accent: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if accent {
                Button(title, action: action).buttonStyle(BrandPrimaryButtonStyle(compact: true))
            } else {
                Button(title, action: action).buttonStyle(BrandSecondaryButtonStyle())
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct LanguageSwitch: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            ForEach([AppLanguage.uz, .ru], id: \.self) { language in
                Button(language.nativeName) { appState.setLanguage(language) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: appState.language == language ? .semibold : .regular))
                    .foregroundStyle(appState.language == language ? Brand.text : Brand.muted)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsScreen: View {
    let controller: OnboardingController
    private var s: OnboardingStrings { controller.strings }

    var body: some View {
        let rows = controller.flow.rows
        let micNext = rows.microphone == .todo || rows.microphone == .denied
        let axNext = !micNext && (rows.accessibility == .todo)
        VStack(spacing: 22) {
            Heading(title: s.permissionsTitle, subtitle: s.permissionsSubtitle)
            RowCard {
                CardRow(icon: "mic", title: s.microphone,
                        hint: rows.microphone == .denied ? s.deniedHint : s.microphoneHint) {
                    switch rows.microphone {
                    case .ready: AllowedMark(text: s.allowed)
                    default:
                        // A refused microphone is switched on in System Settings.
                        RowButton(title: controller.flow.status.microphone == .denied ? s.openSettings : s.allow,
                                  accent: micNext, action: controller.grantMicrophone)
                    }
                }
                BrandDivider()
                CardRow(icon: "character.cursor.ibeam", title: s.accessibility,
                        hint: accessibilityHint(rows.accessibility)) {
                    switch rows.accessibility {
                    case .ready: AllowedMark(text: s.allowed)
                    case .restart:
                        Text(s.needsRestart).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.muted)
                    case .stale:
                        RowButton(title: s.fixStale, accent: true, action: controller.grantAccessibility)
                    default:
                        RowButton(title: s.allow, accent: axNext, action: controller.grantAccessibility)
                    }
                }
            }
            .animation(.brandExpoOutFast, value: rows)
            if controller.flow.reopen {
                Button(s.restart, action: controller.reopen)
                    .buttonStyle(BrandPrimaryButtonStyle(compact: true))
                    .transition(.opacity)
            }
        }
    }

    private func accessibilityHint(_ status: OnboardingRowStatus) -> String {
        switch status {
        case .stale: s.staleHint
        case .restart: s.restartHint
        default: s.accessibilityHint
        }
    }
}

// MARK: - Engine

private struct EngineScreen: View {
    @Environment(AppState.self) private var appState
    let controller: OnboardingController
    private var s: OnboardingStrings { controller.strings }

    var body: some View {
        let local = controller.flow.engine == .local
        VStack(spacing: 22) {
            Heading(title: s.engineTitle, subtitle: s.engineSubtitle)
            RowCard {
                choice(selected: !local, icon: "cloud", title: s.cloudTitle, hint: s.cloudHint,
                       badge: s.recommended, action: controller.chooseCloud)
                BrandDivider()
                choice(selected: local, icon: "laptopcomputer", title: s.localTitle, hint: s.localHint,
                       badge: nil) { controller.chooseLocal(controller.localModel) }
                if local {
                    VStack(spacing: 0) {
                        modelRow(.multilingual, title: appState.strings.modelMultiTitle)
                        modelRow(.ruEnPunctuated, title: appState.strings.modelRuEnTitle)
                    }
                    .padding(.leading, 44)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
            .animation(.brandExpoOutFast, value: local)
            Button(s.continue, action: controller.next)
                .buttonStyle(BrandPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func choice(selected: Bool, icon: String, title: String, hint: String,
                        badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CardRow(icon: icon, title: title, hint: hint) {
                HStack(spacing: 10) {
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.accent)
                    }
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Brand.accent : Brand.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ model: AsrModel, title: String) -> some View {
        let selected = controller.localModel == model
        return Button { controller.chooseLocal(model) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Brand.accent : Brand.muted)
                Text(title).font(.system(size: 12)).foregroundStyle(Brand.text)
                Spacer(minLength: 8)
                if selected { modelState }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var modelState: some View {
        switch controller.flow.model {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                BrandProgressBar(fraction: fraction).frame(width: 70)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Brand.muted)
            }
        case .failed:
            Button(s.retry, action: controller.retryDownload).buttonStyle(BrandSecondaryButtonStyle())
        case .ready:
            AllowedMark(text: s.ready)
        case .missing:
            EmptyView()
        }
    }
}

// MARK: - Done

private struct DoneScreen: View {
    @Environment(AppState.self) private var appState
    let controller: OnboardingController
    @State private var changingKey = false
    private var s: OnboardingStrings { controller.strings }

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 18) {
            Canvas { context, size in
                SezishGlyph.draw(in: context, size: size,
                                 capsuleScales: Array(repeating: 1, count: SezishGlyph.capsules.count))
            }
            .frame(width: 44, height: 58)
            Text(s.doneTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Brand.text)
            keyLine
            Label(s.livesInMenuBar, systemImage: "menubar.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Brand.bgSoft, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.faint, lineWidth: 1))
            HStack(spacing: 16) {
                Toggle(s.launchAtLogin, isOn: $controller.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Button(s.changeKey) { changingKey.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.accent)
            }
            if changingKey {
                ShortcutRecorder(
                    currentLabel: appState.currentShortcut.displayLabel(strings: appState.strings),
                    prompt: appState.strings.recorderPrompt,
                    helpText: appState.strings.recorderHelp,
                    needsModifierText: appState.strings.recorderNeedsModifier
                ) { shortcut in
                    appState.setShortcut(shortcut)
                    changingKey = false
                }
                .transition(.opacity)
            }
            startButton
        }
        .animation(.brandExpoOutFast, value: changingKey)
    }

    private var keyLine: some View {
        let hold = appState.hotkeyMode == .hold
        return HStack(spacing: 6) {
            Text(hold ? s.holdPrefix : s.pressPrefix)
            Keycaps(label: appState.currentShortcut.displayLabel(strings: appState.strings))
            Text(hold ? s.holdSuffix : s.pressSuffix)
        }
        .font(.system(size: 13))
        .foregroundStyle(Brand.muted)
    }

    @ViewBuilder private var startButton: some View {
        let ready = controller.flow.engineReady
        Button(action: controller.next) {
            if ready {
                Text(s.start)
            } else if case .downloading(let fraction) = controller.flow.model {
                Text("\(s.waitingForModel) \(Int((fraction * 100).rounded()))%").monospacedDigit()
            } else {
                Text(s.waitingForModel)
            }
        }
        .buttonStyle(BrandPrimaryButtonStyle(compact: true))
        .disabled(!ready)
        .opacity(ready ? 1 : 0.55)
        .keyboardShortcut(.defaultAction)
        .padding(.top, 4)
    }
}

/// The shortcut drawn as keys: "⌥ + Space" becomes two caps.
private struct Keycaps: View {
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(label.components(separatedBy: " + ").enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.faint, lineWidth: 1))
            }
        }
    }
}
