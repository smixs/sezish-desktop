import Foundation

/// Cuts a long recording into pieces a fixed-size model can swallow.
///
/// The GigaAM ONNX export carries a self-attention mask baked for 5000 encoder frames, i.e.
/// exactly 200 s of audio at 25 frames per second: one sample past that and the session throws
/// "Attempting to broadcast an axis by a dimension other than 1". So anything longer is cut,
/// preferably where nobody is speaking — a boundary through the middle of a word costs both
/// chunks their last and first token.
///
/// That mask is only the hard stop. The chunk actually shipped is far shorter, because the
/// transcription quality falls apart long before the ceiling: see `defaultLimit`.
enum AudioChunker {
    /// 30 s at 16 kHz. This is the quality ceiling of GigaAM, not a technical one: the model is
    /// trained on short utterances, and past roughly half a minute the CTC output degrades into
    /// mush with letters dropped. Confirmed by an A/B over a real 170 s recording through the same
    /// ONNX pipeline: one 170 s pass came back garbled, 30 s and 25 s chunks came back clean.
    /// As a side effect it also sits far below the hard 200 s ceiling of the attention mask.
    static let defaultLimit = 30 * 16_000

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

        var ranges: [Range<Int>] = []
        var start = 0
        while let cut = nextCut(samples, from: start, limit: limit, searchWindow: searchWindow) {
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// Where the chunk starting at `start` ends, or nil when what is left already fits in
    /// `limit`. Only samples before the boundary decide it, so a recording still being spoken
    /// gets the same answer here as the finished one gets from `split`.
    static func nextCut(
        _ samples: [Float], from start: Int = 0, limit: Int = defaultLimit,
        searchWindow: Int = searchWindow
    ) -> Int? {
        precondition(limit > 0, "limit must be positive")
        guard samples.count - start > limit else { return nil }
        let hard = start + limit
        // The quiet spot is searched for behind the ideal boundary only: moving it forward
        // would push the chunk past the limit the whole exercise is about.
        let earliest = max(start + 1, hard - searchWindow)
        return quietestCut(samples, from: earliest, to: hard) ?? hard
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

/// The streaming half of `AudioChunker`: samples arrive a little at a time and a chunk leaves
/// as soon as its end is certain, which is the moment more than `limit` is buffered. Because
/// the cut reads nothing past itself, what comes out here is exactly what `AudioChunker.split`
/// produces over the same recording once it is finished.
struct StreamCutter {
    private var pending: [Float] = []
    private let limit: Int
    private let searchWindow: Int

    init(
        limit: Int = AudioChunker.defaultLimit, searchWindow: Int = AudioChunker.searchWindow
    ) {
        self.limit = limit
        self.searchWindow = searchWindow
    }

    mutating func append(_ samples: [Float]) { pending.append(contentsOf: samples) }

    /// The next chunk whose boundary is already decided, or nil while everything buffered
    /// still fits one chunk and could yet grow into it.
    mutating func nextChunk() -> [Float]? {
        guard let cut = AudioChunker.nextCut(
            pending, limit: limit, searchWindow: searchWindow) else { return nil }
        let chunk = Array(pending[0..<cut])
        pending.removeFirst(cut)
        return chunk
    }

    /// Everything left over once the recording is over.
    mutating func takeRest() -> [Float] {
        let rest = pending
        pending = []
        return rest
    }
}
