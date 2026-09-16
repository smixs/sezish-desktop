import Foundation

/// What the meeting detector thinks right now: facts only, no text. The menu
/// shows one line under the meeting button (like `lastDecision` in amanu) so
/// the user sees why no recording runs while auto-record is on.
public enum MeetingDetectorStatus: Equatable, Sendable {
    case disabled
    case ready
    case denied(names: [String])
    case candidate(name: String, seconds: Int)
    case recording
    case fading(seconds: Int)

    /// Pure decision from what the detector tick already knows: the duplex
    /// candidate, the deny-classified holders, and the debounce state.
    public static func resolve(
        autoRecord: Bool,
        debounce: MeetingDebounce,
        candidateName: String?,
        deniedNames: [String],
        at now: Date
    ) -> MeetingDetectorStatus {
        guard autoRecord else { return .disabled }
        if let live = liveStatus(debounce: debounce, at: now) { return live }
        return idleStatus(
            candidateName: candidateName, deniedNames: deniedNames,
            debounce: debounce, at: now)
    }

    private static func liveStatus(
        debounce: MeetingDebounce, at now: Date
    ) -> MeetingDetectorStatus? {
        if debounce.isActive { return .recording }
        if let silence = debounce.endingSilenceSeconds(at: now) {
            return .fading(seconds: Int(silence))
        }
        return nil
    }

    private static func idleStatus(
        candidateName: String?,
        deniedNames: [String],
        debounce: MeetingDebounce,
        at now: Date
    ) -> MeetingDetectorStatus {
        if let name = candidateName, let held = debounce.candidateHeldSeconds(at: now) {
            return .candidate(name: name, seconds: Int(held))
        }
        if !deniedNames.isEmpty { return .denied(names: deniedNames) }
        return .ready
    }
}

/// Format strings for the menu line; the concrete ru/uz tables live in
/// `Strings` (Localization.swift), this only names the slots.
public struct MeetingStatusText: Sendable {
    public let ready: String
    /// `%@` is the ", "-joined holder names.
    public let denied: String
    /// `%@` is the holder name, `%d` the seconds it holds the mic.
    public let candidate: String
    public let recording: String
    /// `%d` is the seconds of silence.
    public let fading: String

    public init(
        ready: String, denied: String, candidate: String,
        recording: String, fading: String
    ) {
        self.ready = ready
        self.denied = denied
        self.candidate = candidate
        self.recording = recording
        self.fading = fading
    }
}

/// Pure render of a decision into a menu line; nil means no line.
public func meetingStatusLine(
    _ status: MeetingDetectorStatus, text: MeetingStatusText
) -> String? {
    if case .disabled = status { return nil }
    return activeStatusLine(status, text: text)
}

private func activeStatusLine(
    _ status: MeetingDetectorStatus, text: MeetingStatusText
) -> String? {
    if let short = shortStatusLine(status, text: text) { return short }
    return formattedStatusLine(status, text: text)
}

private func shortStatusLine(
    _ status: MeetingDetectorStatus, text: MeetingStatusText
) -> String? {
    switch status {
    case .ready: return text.ready
    case .recording: return text.recording
    default: return nil
    }
}

private func formattedStatusLine(
    _ status: MeetingDetectorStatus, text: MeetingStatusText
) -> String? {
    switch status {
    case .denied(let names):
        return String(format: text.denied, names.joined(separator: ", "))
    case .candidate(let name, let seconds):
        return String(format: text.candidate, name, seconds)
    case .fading(let seconds):
        return String(format: text.fading, seconds)
    default: return nil
    }
}
