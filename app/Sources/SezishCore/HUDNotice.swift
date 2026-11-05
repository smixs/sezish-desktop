import Foundation

/// A short message the dictation HUD shows in place of a notification: the
/// circle widens into a pill with the text and the error sound plays.
public enum HUDNotice: Sendable, Equatable {
    /// The paste did not go through; the text is on the clipboard.
    case pasteManually
    /// The engine heard nothing; the audio is kept in history.
    case noText
    /// The microphone did not record.
    case micFailed
    /// Local recognition has no downloaded model yet.
    case modelMissing

    /// The ones the user fixes in Settings: a click on the pill opens them.
    public var opensSettings: Bool {
        switch self {
        case .micFailed, .modelMissing: true
        case .pasteManually, .noText: false
        }
    }

    /// Seconds on screen; a clickable pill waits long enough to be clicked.
    public var duration: TimeInterval { opensSettings ? 4 : 2 }

    public static func after(_ outcome: DictationCoordinator.Outcome) -> HUDNotice? {
        switch outcome {
        case .inserted, .ignored: nil
        case .insertFailed: .pasteManually
        case .noText: .noText
        case .failed: .micFailed
        }
    }
}

/// Who holds Secure Input. While a password field or a terminal's "Secure
/// Keyboard Entry" has it, macOS hides key events from every app, so the
/// hotkey goes dead. The IORegistry root's `IOConsoleUsers` entry for our
/// session names the process.
public enum SecureInputOwner {
    public static func pid(consoleUsers: [[String: Any]], uid: UInt32) -> Int32? {
        for user in consoleUsers {
            guard (user["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid,
                  let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
                  pid > 0 else { continue }
            return pid
        }
        return nil
    }
}
