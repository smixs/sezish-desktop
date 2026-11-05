import Foundation

/// How hard the dictation wave moves with the voice. Serge picks the default
/// after seeing all three live (spec docs/specs/hex-polish.md, decision 19).
public enum WaveIntensity: String, Sendable, CaseIterable {
    case calm
    case lively
    case bold

    /// Height swing at full voice, as a fraction of a capsule's rest height:
    /// bold doubles the capsule at a crest.
    public var swing: Double {
        switch self {
        case .calm: 0.7
        case .lively: 0.85
        case .bold: 1.0
        }
    }

    /// Wave speed in silence (Hz) and how much a full voice adds to it.
    public var baseFrequency: Double {
        switch self {
        case .calm: 1.1
        case .lively: 1.3
        case .bold: 1.5
        }
    }

    public var speedGain: Double {
        switch self {
        case .calm: 0.6
        case .lively: 1.2
        case .bold: 2.0
        }
    }

    /// Level follower: how fast the wave jumps with a syllable and settles after.
    public var attack: Float {
        switch self {
        case .calm: 0.07
        case .lively: 0.05
        case .bold: 0.03
        }
    }

    public var release: Float {
        switch self {
        case .calm: 0.30
        case .lively: 0.22
        case .bold: 0.15
        }
    }

    /// Shortest a capsule may get at a trough, so it never vanishes.
    public static let minimumScale: Double = 0.25

    /// Height scale of a capsule at `level` (0…1) and wave `oscillation` (−1…1).
    public func capsuleScale(level: Double, oscillation: Double) -> Double {
        max(Self.minimumScale, 1 + level * swing * oscillation)
    }

    /// Wave frequency (Hz) at `level`: louder speech runs the wave faster.
    public func frequency(level: Double) -> Double {
        baseFrequency + speedGain * min(max(level, 0), 1)
    }
}
