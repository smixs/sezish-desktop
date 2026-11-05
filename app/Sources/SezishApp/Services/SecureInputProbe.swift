import AppKit
import Carbon
import IOKit
import SezishCore

/// Whether Secure Input is on and who holds it. While it is on, macOS hides key
/// events from every other app, so the dictation hotkey is dead.
enum SecureInputProbe {
    /// nil when Secure Input is off; the holder's name, or "" when it is unknown.
    @MainActor static func holder() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let users = property as? [[String: Any]],
              let pid = SecureInputOwner.pid(consoleUsers: users, uid: getuid())
        else { return "" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    }
}
