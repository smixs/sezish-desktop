import AppKit

extension Notification.Name {
    static let sezishShowSettings = Notification.Name("sezishShowSettings")
}

/// Menu-bar apps show nothing on launch; this makes manual launches visible.
/// Detects login-item launches via the launch Apple event so the Settings window
/// only auto-opens when the user started the app deliberately.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var launchedAsLoginItem = false

    /// Lives on the delegate, not on the App struct: SwiftUI may re-create the
    /// struct, and exactly one Sparkle updater must ever start per process.
    let updater = UpdaterModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Re-opening the app (Spotlight/Launchpad/Finder) while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .sezishShowSettings, object: nil)
        return false
    }
}
