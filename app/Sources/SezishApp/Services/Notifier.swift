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
    /// Set by `AppState`: the user pressed "restart" on the broken-audio banner.
    var onRestart: (@MainActor () -> Void)?
    /// Every category with a button registered so far. The center replaces its
    /// categories wholesale on each call, so each call re-registers all of them: a
    /// retry banner still on screen keeps its button when a restart banner arrives.
    private var categories: [String: UNNotificationCategory] = [:]

    /// Ask for permission up front so the first real notification isn't dropped.
    func prepare() {
        guard hasBundle else { return }
        requestAuthorizationOnce()
        let delegate = Delegate(
            onRetry: { [weak self] md in
                Task { @MainActor in self?.onSummaryRetry?(md) }
            },
            onRestart: { [weak self] in
                Task { @MainActor in self?.onRestart?() }
            }
        )
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// - Parameter retry: the meeting a "retry" button should re-run, and the button's
    ///   already-localized title. Nil: a plain banner.
    /// - Parameter restart: the already-localized title of a button that restarts the
    ///   app. Nil: no such button.
    func notify(
        title: String, body: String, retry: (meeting: URL, actionTitle: String)? = nil,
        restart: String? = nil
    ) {
        guard hasBundle else { return }
        requestAuthorizationOnce()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let retry {
            // Re-registered on every call: that is what lets the button follow a
            // language change.
            register(category: Self.retryCategoryID, action: Self.retryActionID, title: retry.actionTitle)
            content.categoryIdentifier = Self.retryCategoryID
            content.userInfo = Self.retryUserInfo(for: retry.meeting)
        } else if let restart {
            register(category: Self.restartCategoryID, action: Self.restartActionID, title: restart)
            content.categoryIdentifier = Self.restartCategoryID
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func register(category: String, action: String, title: String) {
        categories[category] = UNNotificationCategory(
            identifier: category,
            actions: [UNNotificationAction(identifier: action, title: title, options: [])],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    nonisolated static let retryActionID = "sezish.summary.retry"
    nonisolated static let retryCategoryID = "sezish.summary.failed"
    nonisolated static let restartActionID = "sezish.app.restart"
    nonisolated static let restartCategoryID = "sezish.audio.broken"

    /// Only the button restarts: a plain click on the banner just opens the app.
    nonisolated static func isRestartRequest(actionIdentifier: String) -> Bool {
        actionIdentifier == restartActionID
    }
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
        private let onRestart: @Sendable () -> Void

        init(
            onRetry: @escaping @Sendable (URL) -> Void,
            onRestart: @escaping @Sendable () -> Void
        ) {
            self.onRetry = onRetry
            self.onRestart = onRestart
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
            } else if Notifier.isRestartRequest(actionIdentifier: response.actionIdentifier) {
                onRestart()
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
