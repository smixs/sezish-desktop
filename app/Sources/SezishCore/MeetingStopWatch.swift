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

    /// Seconds of the recording that are trailing silence rather than meeting:
    /// two minutes of talk followed by a ten-minute silence window is a short
    /// recording, and must be judged as one. A manual stop and the ceiling
    /// discount nothing — every second of those was time somebody asked for.
    public var trailingSilence: TimeInterval {
        switch self {
        case .silence(let seconds), .callEnded(let seconds): seconds
        case .ceiling, .manual: 0
        }
    }

    /// True for the stop the silence net causes — the only one the detector has to
    /// be re-armed after, and the only one that may throw a take away.
    public var isSilenceStop: Bool {
        if case .silence = self { true } else { false }
    }

    /// The units of the "the recording stopped itself" banner, or nil for the
    /// stops that need no announcement (the user's own, and the detector's).
    public var banner: MeetingStopBanner? {
        switch self {
        case .silence(let seconds): return .silence(minutes: Int(seconds) / 60)
        case .ceiling(let seconds): return Self.ceilingBanner(seconds)
        case .callEnded, .manual: return nil
        }
    }

    /// The ceiling's parts with the zero ones dropped, so the default five hours
    /// reads as "5 ч" and a hand-tuned 90 minutes keeps its half hour. A ceiling
    /// under a minute (the hidden setting, hand-tuned) reads as one minute rather
    /// than nothing at all.
    private static func ceilingBanner(_ seconds: TimeInterval) -> MeetingStopBanner {
        let total = max(1, Int(seconds) / 60)
        return .ceiling(
            hours: total / 60 > 0 ? total / 60 : nil,
            minutes: total % 60 > 0 ? total % 60 : nil
        )
    }
}

/// What the user is told about a stop they did not ask for, in parts the app can
/// format without deciding anything: a 90-minute ceiling is "1 ч 30 мин", never a
/// rounded "1 ч".
public enum MeetingStopBanner: Equatable, Sendable {
    /// Minutes of both-track silence that ended an auto-started recording.
    case silence(minutes: Int)
    /// The ceiling, zero parts dropped: `(hours: 5, minutes: nil)` is "5 ч",
    /// `(hours: 1, minutes: 30)` is "1 ч 30 мин", `(hours: nil, minutes: 30)` is
    /// "30 мин". Exactly one part is nil only when the other covers it whole.
    case ceiling(hours: Int?, minutes: Int?)
}

/// The two safety nets that end a recording nobody is watching: a call app can
/// hold the mic open long after the call (Telegram, a browser tab), and a
/// forgotten recording must not run until morning.
///
/// The nets are deliberately independent: silence only applies to a recording
/// the detector started (a manual one is the user's own), the ceiling applies to
/// every recording — eight hours of audio is a bug, whoever started it.
public struct MeetingAutoStop: Sendable {
    /// Both tracks quiet this long and an auto-started recording ends itself.
    public static let defaultSilenceAfter: TimeInterval = 10 * 60
    /// Hard ceiling for any recording, auto or manual: five hours in, whatever
    /// this is, it stopped being a meeting.
    public static let defaultMaxDuration: TimeInterval = 5 * 60 * 60

    private let startedAt: Date
    private let isAuto: Bool
    private let silenceAfter: TimeInterval
    private let maxDuration: TimeInterval
    private var silentSince: Date?

    public init(
        startedAt: Date,
        isAuto: Bool,
        silenceAfter: TimeInterval = Self.defaultSilenceAfter,
        maxDuration: TimeInterval = Self.defaultMaxDuration
    ) {
        self.startedAt = startedAt
        self.isAuto = isAuto
        self.silenceAfter = silenceAfter
        self.maxDuration = maxDuration
    }

    /// One tick (the poll runs once a second). `micLoud` and `systemLoud` say
    /// whether that track held a speech frame since the previous tick; returns
    /// the reason to stop, or nil to keep recording.
    public mutating func tick(micLoud: Bool, systemLoud: Bool, at now: Date) -> MeetingStopReason? {
        if reachedCeiling(at: now) { return .ceiling(maxDuration) }
        guard isAuto else { return nil }
        return tickSilence(quiet: !micLoud && !systemLoud, at: now)
    }

    private func reachedCeiling(at now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= maxDuration
    }

    /// Either track speaking restarts the window, so the recording survives a
    /// quiet stretch on one side of a call.
    private mutating func tickSilence(quiet: Bool, at now: Date) -> MeetingStopReason? {
        guard quiet else {
            silentSince = nil
            return nil
        }
        let since = silentSince ?? now
        silentSince = since
        guard now.timeIntervalSince(since) >= silenceAfter else { return nil }
        return .silence(silenceAfter)
    }
}

/// Folds realtime buffers into 100 ms frames and reports when one of them was
/// loud enough to be speech — the silence stop's per-track signal, measured on
/// the audio thread. Buffers are smaller than a frame, so the frame spans them;
/// the threshold is the model gate's (`MeetingTranscriptionPipeline`), which
/// means a track that keeps the transcriber busy is exactly a track that keeps
/// the recording alive.
public struct MeetingLoudnessMeter: Sendable {
    /// 100 ms at 16 kHz, the frame the speech threshold is calibrated on.
    public static let frameSamples = 1_600

    private var energy: Float = 0
    private var frame = 0

    public init() {}

    /// True when this buffer completed a frame at or above the speech threshold.
    /// Allocating nothing, this is safe to call from a realtime callback.
    public mutating func append(_ samples16k: [Float]) -> Bool {
        var loud = false
        for sample in samples16k {
            energy += sample * sample
            frame += 1
            // Short of a full frame there is nothing to judge yet: the remainder
            // of the energy carries into the next buffer.
            guard frame == Self.frameSamples else { continue }
            if energy >= MeetingTranscriptionPipeline.speechFrameEnergy { loud = true }
            energy = 0
            frame = 0
        }
        return loud
    }

    /// Forget the half-counted frame: the next take's first samples are its own,
    /// not the tail of a recording that ended minutes ago.
    public mutating func reset() {
        energy = 0
        frame = 0
    }
}
