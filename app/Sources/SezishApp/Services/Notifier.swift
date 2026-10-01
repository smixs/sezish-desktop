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

    /// Set by `AppState`: the user pressed "retry" on a failed-summary banner.
    var onSummaryRetry: (@MainActor (URL) -> Void)?

    /// Ask for permission up front so the first real notification isn't dropped.
    func prepare() {
        guard hasBundle else { return }
        requestAuthorizationOnce()
        let delegate = Delegate { [weak self] md in
            Task { @MainActor in self?.onSummaryRetry?(md) }
        }
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// - Parameter retry: the meeting a "retry" button should re-run, and the button's
    ///   already-localized title. Nil: a plain banner.
    func notify(title: String, body: String, retry: (meeting: URL, actionTitle: String)? = nil) {
        guard hasBundle else { return }
        requestAuthorizationOnce()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let retry {
            // Categories are replaced wholesale on every call; this is the only one, and
            // re-registering is what lets the button follow a language change.
            let action = UNNotificationAction(
                identifier: Self.retryActionID, title: retry.actionTitle, options: [])
            UNUserNotificationCenter.current().setNotificationCategories([
                UNNotificationCategory(
                    identifier: Self.retryCategoryID, actions: [action],
                    intentIdentifiers: [], options: [])
            ])
            content.categoryIdentifier = Self.retryCategoryID
            content.userInfo = Self.retryUserInfo(for: retry.meeting)
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static let retryActionID = "sezish.summary.retry"
    nonisolated static let retryCategoryID = "sezish.summary.failed"
    private nonisolated static let meetingKey = "meetingMd"

    nonisolated static func retryUserInfo(for md: URL) -> [AnyHashable: Any] {
        [meetingKey: md.path]
    }

    /// Only the button counts: a plain click on the banner opens the app and must not
    /// start a paid agent run.
    nonisolated static func retryTarget(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> URL? {
        guard actionIdentifier == retryActionID,
            let path = userInfo[meetingKey] as? String, !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
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
        private let onRetry: @Sendable (URL) -> Void

        init(onRetry: @escaping @Sendable (URL) -> Void) {
            self.onRetry = onRetry
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            if let md = Notifier.retryTarget(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo)
            {
                onRetry(md)
            }
            completionHandler()
        }

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
