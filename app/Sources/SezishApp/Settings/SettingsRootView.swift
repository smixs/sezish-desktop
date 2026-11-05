import SwiftUI
import SezishCore

/// Settings shell: the native macOS sidebar + detail split, one pane per topic.
/// The sidebar keeps the system selection highlight — brand colour appears only
/// in the pane tiles and in the detail tint, so the window still reads as a Mac
/// settings window and not as a themed web page.
struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updater: UpdaterModel

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selectionBinding) { pane in
                Label {
                    Text(pane.title(appState.strings))
                } icon: {
                    PaneTile(pane: pane)
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(175)
            .safeAreaInset(edge: .top) { sidebarHeader }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            NavigationStack { detail }
                .tint(Brand.accent)
        }
        .navigationSplitViewStyle(.balanced)
        // Wider than before: the meetings page holds a list and a card side by side.
        .frame(minWidth: 720, idealWidth: 800, maxWidth: 1100, minHeight: 500, idealHeight: 580)
    }

    /// List selection is optional by contract; a click on empty sidebar space must
    /// not blank the detail column, so nil is simply ignored.
    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { appState.settingsPane },
            set: { if let new = $0 { appState.settingsPane = new } }
        )
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            SezishLogoMark()
                .frame(height: 20)
            Text("sezish")
                .font(.system(size: 15, weight: .heavy))
                .tracking(-0.3)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// Quit, the version and the update check, at the foot of the sidebar like hex.
    private var sidebarFooter: some View {
        let s = SettingsStrings.forLanguage(appState.language)
        return VStack(alignment: .leading, spacing: 6) {
            Button(s.quit) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
            Text("\(s.version) \(appVersion)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(appState.strings.checkUpdates) { updater.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(!updater.canCheckForUpdates)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    @ViewBuilder private var detail: some View {
        switch appState.settingsPane {
        case .general: GeneralPane()
        case .history: HistoryPane()
        case .meetings: MeetingsPane()
        }
    }
}

/// One row of the settings sidebar. The tiles take the gradient's three stops,
/// first to last, so the sidebar reads as the brand ramp laid on its side.
enum SettingsPane: CaseIterable, Identifiable {
    case general
    case history
    case meetings

    var id: Self { self }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: strings.general
        case .history: strings.paneHistory
        case .meetings: strings.historyMeetings
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .meetings: "person.2"
        }
    }

    var tileColor: Color {
        switch self {
        case .general: Color(hex: 0xFFA700)
        case .history: Color(hex: 0xFF3600)
        case .meetings: Color(hex: 0xFF0087)
        }
    }
}

/// System Settings-style rounded tile: white glyph on the pane's brand colour.
private struct PaneTile: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(pane.tileColor, in: RoundedRectangle(cornerRadius: 6))
    }
}
