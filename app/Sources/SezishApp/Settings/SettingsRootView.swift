import SwiftUI
import SezishCore

/// Settings shell: the native macOS sidebar + detail split, one pane per topic.
/// The sidebar keeps the system selection highlight — brand colour appears only
/// in the pane tiles and in the detail tint, so the window still reads as a Mac
/// settings window and not as a themed web page.
struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SettingsPane = .general

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
        } detail: {
            detail
                .tint(Brand.accent)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620, minHeight: 440, idealHeight: 520)
    }

    /// List selection is optional by contract; a click on empty sidebar space must
    /// not blank the detail column, so nil is simply ignored.
    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { selection },
            set: { if let new = $0 { selection = new } }
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

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralPane()
        case .recognition: RecognitionPane()
        case .history: HistoryPane()
        case .summary: SummaryPane()
        case .hotkey: HotkeyPane()
        case .permissions: PermissionsPane()
        case .updates: UpdatesPane()
        }
    }
}

/// One row of the settings sidebar. The tile colours walk the logo's arc from its
/// first capsule to its last, so the sidebar reads as the glyph laid on its side.
enum SettingsPane: CaseIterable, Identifiable {
    case general
    case recognition
    case history
    case summary
    case hotkey
    case permissions
    case updates

    var id: Self { self }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: strings.general
        case .recognition: strings.recognition
        case .history: strings.paneHistory
        case .summary: strings.paneSummary
        case .hotkey: strings.paneHotkey
        case .permissions: strings.permissions
        case .updates: strings.paneUpdates
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recognition: "waveform"
        case .history: "clock.arrow.circlepath"
        case .summary: "sparkles"
        case .hotkey: "keyboard"
        case .permissions: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

    var tileColor: Color {
        switch self {
        case .general: Color(hex: 0xFFA700)
        case .recognition: Color(hex: 0xFF6B00)
        // The logo has five capsules and there are seven panes now, so these sit
        // between their neighbours on the same ramp instead of borrowing a
        // capsule's colour and breaking the walk.
        case .history: Color(hex: 0xFF5E00)
        case .summary: Color(hex: 0xFF5000)
        case .hotkey: Color(hex: 0xFF3600)
        case .permissions: Color(hex: 0xFF0044)
        case .updates: Color(hex: 0xFF0087)
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
