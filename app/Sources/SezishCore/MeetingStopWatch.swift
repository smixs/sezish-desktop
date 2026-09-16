import Foundation

/// Why a recording ended: what the short-recording rule has to discount, and
/// what the user is told.
public enum MeetingStopReason: Equatable, Sendable {
    /// Both tracks went quiet for `seconds`. Auto-started recordings only.
    case silence(TimeInterval)
    /// The detector saw the call end; the debounce's stop window was quiet too.
    case callEnded(TimeInterval)
    /// The ceiling: the recording ran `seconds` and stopped being a meeting.
    case ceiling(TimeInterval)
    /// The user stopped it.
    case manual

    // RED: surface only, the behaviour lands in the next commit.
    public var trailingSilence: TimeInterval { 0 }
}

/// The two safety nets that end a recording nobody is watching: a call app can
/// hold the mic open long after the call (Telegram, a browser tab), and a
/// forgotten recording must not run until morning.
public struct MeetingAutoStop: Sendable {
    /// Both tracks quiet this long and an auto-started recording ends itself.
    public static let defaultSilenceAfter: TimeInterval = 10 * 60
    /// Hard ceiling for any recording, auto or manual: five hours in, whatever
    /// this is, it stopped being a meeting.
    public static let defaultMaxDuration: TimeInterval = 5 * 60 * 60

    public init(
        startedAt: Date,
        isAuto: Bool,
        silenceAfter: TimeInterval = Self.defaultSilenceAfter,
        maxDuration: TimeInterval = Self.defaultMaxDuration
    ) {}

    // RED: surface only, the behaviour lands in the next commit.
    public mutating func tick(micLoud: Bool, systemLoud: Bool, at now: Date) -> MeetingStopReason? {
        nil
    }
}

/// Folds realtime buffers into 100 ms frames and reports the ones loud enough to
/// be speech: the silence stop's per-track signal, measured on the audio thread.
public struct MeetingLoudnessMeter: Sendable {
    public init() {}

    // RED: surface only, the behaviour lands in the next commit.
    public mutating func append(_ samples: [Float]) -> Bool { false }
}
