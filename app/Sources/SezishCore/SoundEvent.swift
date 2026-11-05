import Foundation

/// The app's brand sounds, one per event. The files sit in the app bundle as
/// `<resourceName>.caf`.
public enum SoundEvent: String, CaseIterable, Sendable {
    case start
    case stop
    case done
    case cancel
    case error
    case meetingStart = "meeting-start"
    case meetingStop = "meeting-stop"

    public var resourceName: String { "sound-" + rawValue }

    /// The sound that closes a dictation: done when the text landed, error when
    /// the user has something to do about it, silence for a clip too short to count.
    public static func after(_ outcome: DictationCoordinator.Outcome) -> SoundEvent? {
        switch outcome {
        case .inserted: .done
        case .insertFailed, .noText, .failed: .error
        case .ignored: nil
        }
    }
}
