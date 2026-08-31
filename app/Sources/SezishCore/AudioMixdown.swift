import Foundation

/// Mixes the mic and system-audio stems into one mono track for transcription.
public enum AudioMixdown {
    /// Monotonic soft clip: |output| < 1 for any finite input, transparent at
    /// speech levels (tanh(x) ≈ x for small x), no hard-clip crunch on overlaps.
    public static func softClip(_ x: Float) -> Float {
        tanhf(x)
    }

    /// Element-wise sum with soft clipping. The shorter slice is zero-padded, so
    /// the result length is max(a.count, b.count) — chunk-friendly for spooled
    /// stems of slightly different lengths.
    public static func mix(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> [Float] {
        let count = Swift.max(a.count, b.count)
        var out = [Float](repeating: 0, count: count)
        let aBase = a.startIndex
        let bBase = b.startIndex
        for i in 0..<count {
            let av = i < a.count ? a[aBase + i] : 0
            let bv = i < b.count ? b[bBase + i] : 0
            out[i] = tanhf(av + bv)
        }
        return out
    }
}
