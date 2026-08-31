import Foundation

/// Cuts a long recording into pieces a fixed-size model can swallow.
///
/// The GigaAM ONNX export carries a self-attention mask baked for 5000 encoder frames, i.e.
/// exactly 200 s of audio at 25 frames per second: one sample past that and the session throws
/// "Attempting to broadcast an axis by a dimension other than 1". So anything longer is cut,
/// preferably where nobody is speaking — a boundary through the middle of a word costs both
/// chunks their last and first token.
enum AudioChunker {
    /// 180 s at 16 kHz, 20 s short of the hard ceiling.
    static let defaultLimit = 180 * 16_000

    /// How far back from the ideal boundary a quiet spot is worth looking for.
    static let searchWindow = 10 * 16_000
    /// Energy window whose middle becomes the cut. 200 ms is longer than the closure inside a
    /// word and shorter than the pause between sentences. Together with the 50 ms hop it means
    /// any silence of 250 ms or more has a window entirely inside it.
    static let probeWindow = 3_200
    static let probeHop = 800
    /// Below this RMS the probe window counts as silence. Roughly -40 dBFS: quiet enough that
    /// no phoneme survives in it, loud enough to still be found in a noisy room.
    static let silenceRMS: Float = 0.01

    /// Consecutive ranges covering every sample exactly once, none longer than `limit`.
    static func split(
        _ samples: [Float], limit: Int = defaultLimit, searchWindow: Int = searchWindow
    ) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        precondition(limit > 0, "limit must be positive")

        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > limit {
            let hard = start + limit
            // The quiet spot is searched for behind the ideal boundary only: moving it forward
            // would push the chunk past the limit the whole exercise is about.
            let earliest = max(start + 1, hard - searchWindow)
            let cut = quietestCut(samples, from: earliest, to: hard) ?? hard
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// Middle of the quietest probe window in `from..<to`, or nil when the whole stretch is
    /// speech — then the caller cuts hard and pays for one mangled word.
    private static func quietestCut(_ samples: [Float], from: Int, to: Int) -> Int? {
        guard from < to else { return nil }
        // A partial window would be measured over a handful of samples, and a zero crossing
        // inside a vowel reads as quiet as a real pause. Only whole windows are compared;
        // a search range too short for one is measured as a single window.
        let width = min(probeWindow, to - from)
        var best: (rms: Float, cut: Int)?
        var probe = from
        while probe + width <= to {
            let level = rms(samples, probe..<(probe + width))
            if best == nil || level < best!.rms { best = (level, probe + width / 2) }
            probe += probeHop
        }
        guard let best, best.rms < silenceRMS else { return nil }
        return best.cut
    }

    private static func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return .infinity }
        var sum: Float = 0
        for index in range { sum += samples[index] * samples[index] }
        return (sum / Float(range.count)).squareRoot()
    }
}
