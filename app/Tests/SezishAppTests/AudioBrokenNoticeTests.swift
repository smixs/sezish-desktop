import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The banner after a capture had to be abandoned (owner decision D3, 06.10.2026): the
/// take is saved, CoreAudio in the app is broken until a restart, and the banner's one
/// button restarts the app.
@MainActor // `Strings.ru` reads synchronously: the app target is MainActor-by-default.
struct AudioBrokenNoticeTests {
    @Test func theTextIsTheOwnersWording() {
        #expect(Strings.ru.notifMeetingAudioBroken
            == "Запись сохранена. macOS сломала звук в sezish, перезапусти его, чтобы записывать снова.")
        #expect(Strings.uz.notifMeetingAudioBroken
            == "Yozuv saqlandi. macOS sezishda ovozni buzib qoʼydi, yana yozish uchun uni qayta ishga tushiring.")
        // The button reuses the app's one restart label.
        #expect(Strings.ru.restart == "Перезапустить")
        for s in [Strings.ru, Strings.uz] {
            #expect(!s.notifMeetingAudioBroken.contains("—"))
            #expect(!s.notifMeetingAudioBroken.contains("'"))
        }
    }

    /// Only the button restarts: a plain click on the banner just opens the app, and the
    /// summary's retry button is not a restart either.
    @Test func onlyTheRestartButtonRestarts() {
        #expect(Notifier.isRestartRequest(actionIdentifier: Notifier.restartActionID))
        #expect(!Notifier.isRestartRequest(
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"))
        #expect(!Notifier.isRestartRequest(actionIdentifier: Notifier.retryActionID))
        #expect(Notifier.restartActionID != Notifier.retryActionID)
        #expect(Notifier.restartCategoryID != Notifier.retryCategoryID)
    }
}
