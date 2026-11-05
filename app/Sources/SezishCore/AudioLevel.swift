import Foundation

/// Pure audio-level math for the recording indicator: block RMS, perceptual
/// normalization, and an asymmetric follower. Deterministic and allocation-free —
/// `rms` is safe to call from the realtime audio tap.
public enum AudioLevel {
    /// Root-mean-square of a block of samples. 0 for an empty block.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps RMS onto a 0…1 display level over a −50…−10 dBFS window: room noise
    /// stays near the floor, normal speech lands mid-range, shouting saturates.
    public static func normalize(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 50) / 40, 0), 1)
    }
}

/// Asymmetric exponential follower: fast attack so the wave jumps with speech,
/// slow release so it settles down instead of flickering.
public struct LevelSmoother: Sendable {
    public private(set) var value: Float = 0
    private let attackTau: Float
    private let releaseTau: Float

    public init(attackTau: Float = 0.04, releaseTau: Float = 0.25) {
        self.attackTau = attackTau
        self.releaseTau = releaseTau
    }

    /// Advances the follower toward `target` by `dt` seconds and returns the new value.
    @discardableResult
    public mutating func step(target: Float, dt: Float) -> Float {
        let clamped = target.isFinite ? min(max(target, 0), 1) : 0
        guard dt > 0 else { return value }
        let tau = clamped > value ? attackTau : releaseTau
        value += (clamped - value) * (1 - exp(-dt / tau))
        return value
    }
}

extension AudioLevel {
    /// dBFS of an RMS value; silence and garbage read as −120.
    public static func decibels(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return -120 }
        return max(20 * log10(rms), -120)
    }
}

/// Slow auto level for the recording indicator: the loudest the speaker has
/// recently been reads as full and the room as silent, so a quiet laptop
/// microphone moves the wave as much as a close studio one.
///
/// Ported from hex's `AutoLevel` (anomalyco/hex, `src/rune_hud/dot_scope.rs`,
/// MIT, © 2026 Christopher Langton; see THIRD_PARTY_NOTICES.md), constants kept.
public struct AutoLevel: Sendable {
    /// The quietest the speaker's peak may be thought to be, above the room.
    static let minSpan: Float = 16
    /// How far below the peak the level starts.
    static let range: Float = 24
    /// How far above the room the level starts.
    static let roomMargin: Float = 5
    static let attack: Float = 0.04
    static let roomFall: Float = 0.3
    static let roomRise: Float = 6
    /// Seconds the peak takes to fall back once the speaker is quieter.
    static let release: Float = 3
    /// Nothing below this counts as sound, however quiet the room.
    static let noiseFloor: Float = -60

    /// The speaker's recent peak and the room, dBFS. The defaults are a laptop
    /// microphone at talking distance.
    private var peak: Float = -30
    private var room: Float = -55

    public init() {}

    /// Learns from `dt` seconds at `loudness` dBFS and returns the 0…1 level.
    public mutating func step(loudness: Float, dt: Float) -> Float {
        let db = loudness.isNaN ? -120 : max(loudness, -120)
        guard dt > 0, dt.isFinite else { return level(loudness: db) }
        func follow(_ value: inout Float, _ target: Float, _ time: Float) {
            value += (target - value) * (1 - exp(-dt / max(time, 1e-3)))
        }
        follow(&room, db, db < room ? Self.roomFall : Self.roomRise)
        let lowest = max(room, Self.noiseFloor) + Self.minSpan
        follow(&peak, db > peak ? db : lowest, db > peak ? Self.attack : Self.release)
        peak = max(peak, lowest)
        return level(loudness: db)
    }

    /// Where `loudness` dBFS sits in the current window, 0…1, without learning.
    public func level(loudness: Float) -> Float {
        guard !loudness.isNaN else { return 0 }
        let low = max(max(room, Self.noiseFloor) + Self.roomMargin, peak - Self.range)
        return min(max((loudness - low) / max(peak - low, 1), 0), 1)
    }
}
