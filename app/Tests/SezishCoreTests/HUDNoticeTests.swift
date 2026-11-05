import Foundation
import Testing
@testable import SezishCore

/// A dictation that went wrong says so on the HUD for a moment instead of in
/// a notification; the ones the user must act on open Settings when clicked.
struct HUDNoticeTests {
    @Test func everyFailedEndingHasANotice() {
        #expect(HUDNotice.after(.inserted) == nil)
        #expect(HUDNotice.after(.ignored) == nil)
        #expect(HUDNotice.after(.insertFailed("⌘V")) == .pasteManually)
        #expect(HUDNotice.after(.noText) == .noText)
        #expect(HUDNotice.after(.failed) == .micFailed)
    }

    @Test func onlyFixableNoticesOpenSettingsAndStayLonger() {
        #expect(HUDNotice.micFailed.opensSettings)
        #expect(HUDNotice.modelMissing.opensSettings)
        #expect(!HUDNotice.pasteManually.opensSettings)
        #expect(!HUDNotice.noText.opensSettings)
        #expect(HUDNotice.pasteManually.duration == 2)
        #expect(HUDNotice.micFailed.duration == 4)
    }
}

/// Secure Input stops the hotkey; the IORegistry names the process holding it.
struct SecureInputOwnerTests {
    @Test func findsThePidOfOurSession() {
        let users: [[String: Any]] = [
            ["kCGSSessionUserIDKey": NSNumber(value: 502), "kCGSSessionSecureInputPID": NSNumber(value: 77)],
            ["kCGSSessionUserIDKey": NSNumber(value: 501), "kCGSSessionSecureInputPID": NSNumber(value: 4242)],
        ]
        #expect(SecureInputOwner.pid(consoleUsers: users, uid: 501) == 4242)
        #expect(SecureInputOwner.pid(consoleUsers: users, uid: 503) == nil)
    }

    @Test func noPidOrZeroMeansNobody() {
        let users: [[String: Any]] = [
            ["kCGSSessionUserIDKey": NSNumber(value: 501)],
            ["kCGSSessionUserIDKey": NSNumber(value: 501), "kCGSSessionSecureInputPID": NSNumber(value: 0)],
        ]
        #expect(SecureInputOwner.pid(consoleUsers: users, uid: 501) == nil)
        #expect(SecureInputOwner.pid(consoleUsers: [], uid: 501) == nil)
    }
}
