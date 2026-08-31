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
    private let stopAfter: TimeInterval

    public init(startAfter: TimeInterval = 2, stopAfter: TimeInterval = 10) {
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
}

/// Recordings shorter than this get their audio kept but no transcript, no
/// hook and no summary: with "any mic user is a call" detection, a voice
/// search or a voice message would otherwise become a meeting note.
public enum MeetingTranscriptionRule {
    public static let minimumSeconds: TimeInterval = 60

    public static func shouldTranscribe(duration: TimeInterval) -> Bool {
        duration >= minimumSeconds
    }
}
