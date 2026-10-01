import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The retry offer after a failed summary: texts, who gets a button, what the
/// notification carries, and the "one run per meeting" gate.
@MainActor // `Strings.ru` reads synchronously: the app target is MainActor-by-default.
struct SummaryRetryTests {

    @Test func failureTextsAreTheOwnersWording() {
        #expect(Strings.ru.notifSummaryCardsFailed == "Карточки встречи не собрались")
        #expect(Strings.ru.notifSummaryRetryAction == "Повторить")
        #expect(Strings.uz.notifSummaryCardsFailed == "Uchrashuv kartochkalari yigʼilmadi")
        #expect(Strings.uz.notifSummaryRetryAction == "Qayta urinish")
        for s in [Strings.ru, Strings.uz] {
            #expect(!s.notifSummaryCardsFailed.contains("—"))
            #expect(!s.notifSummaryRetryAction.contains("—"))
        }
    }

    @Test func onlyAFailureOffersTheRetryButton() {
        let ru = Strings.ru
        #expect(AppState.summaryNotification(.failed("x"), strings: ru) == ru.notifSummaryCardsFailed)
        #expect(AppState.summaryNotification(.done, strings: ru) == ru.notifSummaryReady)
        #expect(AppState.summaryNotification(.skipped, strings: ru) == nil)
        #expect(AppState.summaryOffersRetry(.failed("x")))
        #expect(!AppState.summaryOffersRetry(.done))
        #expect(!AppState.summaryOffersRetry(.skipped))
    }

    @Test func theNotificationCarriesTheMeetingAndOnlyTheButtonRetries() {
        let md = URL(fileURLWithPath: "/tmp/meetings/call 1.md")
        let info = Notifier.retryUserInfo(for: md)
        #expect(Notifier.retryTarget(actionIdentifier: Notifier.retryActionID, userInfo: info) == md)
        // A plain click on the banner (default action) must not start an agent run.
        #expect(Notifier.retryTarget(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info) == nil)
        #expect(Notifier.retryTarget(actionIdentifier: Notifier.retryActionID, userInfo: [:]) == nil)
    }

    @Test func theGateAllowsOneRunPerMeeting() {
        var gate = SummaryRunGate()
        let a = URL(fileURLWithPath: "/m/a.md")
        let b = URL(fileURLWithPath: "/m/b.md")
        let first = gate.begin(a)
        let again = gate.begin(a)
        let other = gate.begin(b)
        gate.end(a)
        let afterEnd = gate.begin(a)
        #expect(first)
        #expect(!again)
        #expect(other)
        #expect(afterEnd)
    }
}
