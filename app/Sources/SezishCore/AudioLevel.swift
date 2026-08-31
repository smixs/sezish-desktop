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
