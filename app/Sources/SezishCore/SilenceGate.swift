import Foundation

/// hex's `dictate.silence-gate`: a take whose loudest 30 ms window, offset
/// removed, stays under -50 dBFS holds no speech. Engines invent closing phrases
/// ("Спасибо.") on such audio, so it is dropped before transcription. The
/// threshold is conservative: a whisper sits near -43 dBFS.
public enum SilenceGate {
    public static let thresholdDBFS: Float = -50
    /// 30 ms at 16 kHz.
    public static let windowSamples = 480

    public static func isNearSilent(_ samples: [Float]) -> Bool {
        loudestWindowDBFS(samples) < thresholdDBFS
    }

    /// The loudest window's RMS around its own mean, in dBFS; -120 for no audio.
    public static func loudestWindowDBFS(_ samples: [Float]) -> Float {
        var loudest = 0.0
        var start = 0
        while start < samples.count {
            let window = samples[start..<min(start + windowSamples, samples.count)]
            let count = Double(window.count)
            let mean = window.reduce(0.0) { $0 + Double($1) } / count
            let variance = window.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
            loudest = max(loudest, variance.squareRoot())
            start += windowSamples
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }
}
