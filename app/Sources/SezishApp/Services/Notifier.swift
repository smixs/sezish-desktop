import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for one-shot user
/// notifications. Authorization is requested lazily on first use.
///
/// Guarded by `Bundle.main.bundleIdentifier`: `UNUserNotificationCenter.current()` raises
/// an ObjC exception when the process has no bundle (e.g. `swift run`), so we no-op there
/// and only ever touch it inside a real `.app` launched via LaunchServices.
@MainActor
final class Notifier {
    private var requestedAuthorization = false
    private var delegate: Delegate?

    /// Ask for permission up front so the first real notification isn't dropped.
    func prepare() {
        guard hasBundle else { return }
        requestAuthorizationOnce()
        let delegate = Delegate()
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func notify(title: String, body: String) {
        guard hasBundle else { return }
        requestAuthorizationOnce()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestAuthorizationOnce() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `willPresent` keeps the banner visible when sezish itself is frontmost
    /// (it would be swallowed otherwise).
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }
}
