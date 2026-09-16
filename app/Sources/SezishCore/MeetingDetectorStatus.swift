import Foundation

/// What the app itself is doing: the detector cannot tell a live recording from
/// a stale debounce (manual stop, failed start, gated auto-start), so the app
/// status is an explicit input of the decision — never inferred from the tick.
public enum MeetingAppStatus: Equatable, Sendable {
    case idle
    case recording
    case processing
}

/// What the meeting detector thinks right now: facts only, no text. The menu
/// shows one line under the meeting button (like `lastDecision` in amanu) so
/// the user sees why no recording runs while auto-record is on.
public enum MeetingDetectorStatus: Equatable, Sendable {
    case ready
    case denied(names: [String])
    case candidate(name: String, seconds: Int)
    case recording
    case processing
    case fading(seconds: Int)

    /// Pure decision from the app status and what the detector tick knows: the
    /// duplex candidate, the deny-classified holders, and the debounce state.
    /// Only a live recording reads as one; an active debounce with an idle app
    /// is just a held mic, never a recording.
    public static func resolve(
        appStatus: MeetingAppStatus,
        debounce: MeetingDebounce,
        candidateName: String?,
        deniedNames: [String],
        at now: Date
    ) -> MeetingDetectorStatus {
        switch appStatus {
        case .recording:
            return .recording
        case .processing:
            return .processing
        case .idle:
            return idleStatus(
                candidateName: candidateName, deniedNames: deniedNames,
                debounce: debounce, at: now)
        }
    }

    private static func idleStatus(
        candidateName: String?,
        deniedNames: [String],
        debounce: MeetingDebounce,
        at now: Date
    ) -> MeetingDetectorStatus {
        if let silence = debounce.endingSilenceSeconds(at: now) {
            return .fading(seconds: Int(silence))
        }
        if let name = candidateName, let held = debounce.candidateHeldSeconds(at: now) {
            return .candidate(name: name, seconds: Int(held))
        }
        if !deniedNames.isEmpty { return .denied(names: deniedNames) }
        return .ready
    }
}

/// One detector tick, as AppState stores it. The decision itself is rebuilt at
/// render time, when the app status is known — `at` is the tick's own clock, so
/// one tick takes one timestamp for both the debounce and the decision.
public struct MeetingDetectorFacts: Sendable {
    public let debounce: MeetingDebounce
    public let candidateName: String?
    public let deniedNames: [String]
    public let at: Date

    public init(
        debounce: MeetingDebounce,
        candidateName: String?,
        deniedNames: [String],
        at: Date
    ) {
        self.debounce = debounce
        self.candidateName = candidateName
        self.deniedNames = deniedNames
        self.at = at
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
    public let processing: String
    /// `%d` is the seconds of silence.
    public let fading: String

    public init(
        ready: String, denied: String, candidate: String,
        recording: String, processing: String, fading: String
    ) {
        self.ready = ready
        self.denied = denied
        self.candidate = candidate
        self.recording = recording
        self.processing = processing
        self.fading = fading
    }
}

/// Pure render of a decision into a menu line; nil only when no decision was
/// ever published (no tick yet), never for a decision itself.
public func meetingStatusLine(
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
    case .processing: return text.processing
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
