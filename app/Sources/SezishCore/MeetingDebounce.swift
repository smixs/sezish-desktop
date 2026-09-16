import Foundation

/// Debounce state machine for meeting detection: an external mic user must hold
/// for `startAfter` before a recording starts (no flapping on permission prompts
/// or one-word voice inputs), and must be gone for `stopAfter` before it ends
/// (AirPods reconnects and network hiccups don't cut a live call).
public struct MeetingDebounce: Sendable {
    public enum Event: Equatable {
        case start
        case stop
    }

    private enum State {
        case idle
        case candidate(since: Date)
        case active
        case ending(since: Date)
    }

    private var state: State = .idle
    private let startAfter: TimeInterval

    /// Defaults, exposed because the short-recording rule discounts the same stop
    /// window the detector waited out before it called the call ended.
    public static let defaultStartAfter: TimeInterval = 2
    public static let defaultStopAfter: TimeInterval = 10

    /// The window a call must stay gone before the detector calls it over. Public
    /// because that stretch of the recording is not meeting time either: the stop
    /// it produces carries it as `MeetingStopReason.callEnded`, and the detector
    /// hands its own window over rather than letting the app assume a default.
    public let stopAfter: TimeInterval

    public init(
        startAfter: TimeInterval = Self.defaultStartAfter,
        stopAfter: TimeInterval = Self.defaultStopAfter
    ) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
    }

    /// Feed one observation (typically once a second); returns an event when the
    /// debounced state flips.
    public mutating func tick(externalMicActive: Bool, at now: Date) -> Event? {
        switch (state, externalMicActive) {
        case (.idle, true):
            state = .candidate(since: now)
            return nil
        case (.idle, false), (.active, true):
            return nil
        case (.candidate(let since), true):
            guard now.timeIntervalSince(since) >= startAfter else { return nil }
            state = .active
            return .start
        case (.candidate, false):
            state = .idle
            return nil
        case (.active, false):
            state = .ending(since: now)
            return nil
        case (.ending, true):
            state = .active
            return nil
        case (.ending(let since), false):
            guard now.timeIntervalSince(since) >= stopAfter else { return nil }
            state = .idle
            return .stop
        }
    }

    public mutating func reset() {
        state = .idle
    }

    /// Seconds since the candidate window opened; nil unless debouncing a start.
    public func candidateHeldSeconds(at now: Date) -> TimeInterval? {
        if case .candidate(let since) = state { return now.timeIntervalSince(since) }
        return nil
    }

    /// Seconds since the mic went quiet mid-call; nil unless debouncing a stop.
    public func endingSilenceSeconds(at now: Date) -> TimeInterval? {
        if case .ending(let since) = state { return now.timeIntervalSince(since) }
        return nil
    }
}

/// Recordings shorter than this get their audio kept but no transcript, no
/// hook and no summary: with "any mic user is a call" detection, a voice
/// search or a voice message would otherwise become a meeting note.
public enum MeetingTranscriptionRule {
    public static let minimumSeconds: TimeInterval = 60

    /// `stopReason`'s trailing silence is not meeting time: an auto-started
    /// recording ends with the silence window that stopped it, so without the
    /// discount the "short recording" rule could never fire for exactly the
    /// recordings it exists for.
    public static func shouldTranscribe(
        duration: TimeInterval, stopReason: MeetingStopReason
    ) -> Bool {
        duration - stopReason.trailingSilence >= minimumSeconds
    }

    /// True when the take leaves nothing at all behind: no audio, no transcript,
    /// no banner. That is the silence net firing on a recording with no meeting in
    /// it — an app that holds the mic open would otherwise leave one orphan .m4a
    /// per round of "record, go quiet, stop", and nobody ever saw those takes.
    /// Every other short recording keeps its audio: those seconds are the user's.
    public static func discardsAudio(
        duration: TimeInterval, stopReason: MeetingStopReason
    ) -> Bool {
        guard stopReason.isSilenceStop else { return false }
        return !shouldTranscribe(duration: duration, stopReason: stopReason)
    }
}
