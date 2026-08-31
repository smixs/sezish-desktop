import Foundation

/// Slices a continuous 16 kHz stream into model-sized chunks, cutting at the
/// quietest moment near the boundary so words are not split mid-syllable.
/// The local CTC model cannot swallow a whole meeting in one tensor (attention
/// is O(T²)), so ~half-minute windows are both safe and RTF-friendly.
public struct TranscriptChunker {
    private var buffer: [Float] = []
    private let target: Int
    private let searchTail: Int
    private let frame: Int

    public init(
        sampleRate: Int = 16_000,
        targetSeconds: Double = 30,
        quietSearchSeconds: Double = 5
    ) {
        target = Int(targetSeconds * Double(sampleRate))
        // Capped at half the window so a uniformly quiet stream can never
        // degenerate into mini-chunks: the cut always lands in the second half.
        searchTail = min(Int(quietSearchSeconds * Double(sampleRate)), target / 2)
        frame = max(sampleRate / 10, 1) // 100 ms energy frames
    }

    /// Feeds more samples; returns every completed chunk (usually 0 or 1).
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        var out: [[Float]] = []
        while buffer.count >= target {
            let cut = quietCutIndex()
            out.append(Array(buffer[..<cut]))
            buffer.removeFirst(cut)
        }
        return out
    }

    /// The unfinished tail at end of recording; empties the buffer.
    public mutating func flush() -> [Float]? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer = [] }
        return buffer
    }

    /// Midpoint of the lowest-energy 100 ms frame within the last
    /// `quietSearchSeconds` of the window — a likely inter-word pause.
    private func quietCutIndex() -> Int {
        var best = target
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = max(target - searchTail, 0)
        while start + frame <= target {
            var energy: Float = 0
            for sample in buffer[start..<(start + frame)] {
                energy += sample * sample
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + frame / 2
            }
            start += frame
        }
        return best
    }
}

/// Which recorded track a segment came from: the mic (the user) or the system
/// audio (everyone else on the call). Two tracks are free two-party diarization —
/// no speaker-identification model needed.
public enum Speaker: String, Sendable, Equatable {
    case me, them
}

/// One transcribed chunk of a meeting: where it starts, who said it, what was
/// said. Silent chunks produce no segment, so gaps in the timestamps mean silence.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let text: String
    /// nil when there was nothing to diarize against (a mic-only recording):
    /// labelling every line "me" with no second party is noise, not information.
    public let speaker: Speaker?

    public init(start: TimeInterval, text: String, speaker: Speaker? = nil) {
        self.start = start
        self.text = text
        self.speaker = speaker
    }

    /// "[3:12]" under an hour, "[1:03:12]" above — recording-relative.
    public var timestampLabel: String {
        let total = Int(start.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "[%d:%02d:%02d]", hours, minutes, seconds)
            : String(format: "[%d:%02d]", minutes, seconds)
    }
}

extension TranscriptSegment {
    /// Renders merged segments for the meeting .md: "[3:12] Я: текст" for tagged
    /// segments, "[3:12] текст" when undiarized. nil when there is nothing to say.
    /// Shared by every render site so a meeting salvaged after a crash reads
    /// exactly like one saved normally.
    public static func render(
        _ segments: [TranscriptSegment], meLabel: String, themLabel: String
    ) -> String? {
        guard !segments.isEmpty else { return nil }
        return segments.map { segment in
            switch segment.speaker {
            case .me: "\(segment.timestampLabel) \(meLabel): \(segment.text)"
            case .them: "\(segment.timestampLabel) \(themLabel): \(segment.text)"
            case .none: "\(segment.timestampLabel) \(segment.text)"
            }
        }.joined(separator: "\n\n")
    }
}

/// Transcribes a meeting incrementally while it is being recorded, so the full
/// transcript is ready seconds after the call ends instead of minutes.
///
/// Two tracks, two transcripts: the mic stem and the system stem are chunked and
/// recognised separately, tagged `.me` / `.them`, and merged by timestamp in
/// `finish()`. That buys two-party diarization for free, and each stem is also a
/// better input than their sum — one voice at a time, no soft clipping where the
/// two overlap. So the transcript is deliberately NOT a reading of the mixed
/// .m4a: it is made from cleaner audio than the file the user keeps.
///
/// Ingest is called from realtime audio threads (lock-guarded, no I/O); inference
/// runs on a single worker task fed through one AsyncStream. One worker, not two:
/// the transcriber is an actor that serializes anyway, so a second one would only
/// add contention.
public final class MeetingTranscriptionPipeline: @unchecked Sendable {
    /// A cut chunk, the track it came from and its position on that track's clock
    /// (a running sample count — a track's chunks are contiguous from sample 0, so
    /// a prefix sum is exact). Both clocks start at 0; the taps open within tens of
    /// ms of each other, far below the resolution of a timestamp label.
    private struct Chunk: Sendable {
        let speaker: Speaker?
        let startSample: Int
        let samples: [Float]
    }

    /// Sum of squares of a 100 ms frame below which the chunk is room tone rather
    /// than speech. At 16 kHz a frame is 1600 samples, so a 0.005 noise floor
    /// scores 1600·0.005² = 0.04 and a 0.05 voice scores 4.0 — an order of
    /// magnitude either side of this, so no plausible gain setting flips a verdict.
    private static let speechFrameEnergy: Float = 0.4

    private let lock = NSLock()
    // One chunker and one clock per track, mutated in place: the structs share no
    // state, and copying one into a local would silently fork its buffer.
    private var micChunker: TranscriptChunker
    private var systemChunker: TranscriptChunker
    private var micEmittedSamples = 0
    private var systemEmittedSamples = 0
    private var diarized: Bool
    private var finished = false

    /// Chunks whose inference threw. Lives in its own class because the worker
    /// closure is built before `self` exists and so cannot capture it.
    private final class FailureCounter: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
    }

    private let continuation: AsyncStream<Chunk>.Continuation
    private let worker: Task<[TranscriptSegment], Never>
    private let failures: FailureCounter

    /// How many chunks were lost to a failed inference. A dropped chunk is an
    /// invisible hole in the transcript, and a meeting with holes must stay
    /// retryable. Read it after `finish()` returned: by then the worker is done.
    public var failedChunkCount: Int { failures.lock.withLock { failures.value } }

    public init(
        transcriber: any Transcriber,
        hasSystemStream: Bool = true,
        chunkSeconds: Double = 30,
        sampleRate: Int = 16_000
    ) {
        self.diarized = hasSystemStream
        self.micChunker = TranscriptChunker(sampleRate: sampleRate, targetSeconds: chunkSeconds)
        self.systemChunker = TranscriptChunker(sampleRate: sampleRate, targetSeconds: chunkSeconds)

        var continuation: AsyncStream<Chunk>.Continuation!
        let chunks = AsyncStream<Chunk>(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        let rate = Double(sampleRate)
        let frame = max(sampleRate / 10, 1) // 100 ms energy frames, as in the chunker
        // A failed chunk is dropped rather than failing the whole meeting: a
        // transcript with a hole beats none, and the audio is on disk anyway.
        // Counted, though, so the caller can offer the meeting for a retry.
        let failures = FailureCounter()
        self.failures = failures
        worker = Task.detached(priority: .utility) {
            var segments: [TranscriptSegment] = []
            for await chunk in chunks {
                // Each track is mostly silence while the other side talks, so
                // gating the quiet chunks roughly halves the inference a call
                // costs. Timestamps are unaffected: the clocks count emitted
                // samples, not transcribed ones.
                guard MeetingTranscriptionPipeline.hasSpeech(chunk.samples, frame: frame) else {
                    continue
                }
                do {
                    let text = try await transcriber.transcribe(chunk.samples)
                    if !text.isEmpty {
                        segments.append(TranscriptSegment(
                            start: Double(chunk.startSample) / rate,
                            text: text,
                            speaker: chunk.speaker))
                    }
                } catch {
                    failures.lock.withLock { failures.value += 1 }
                }
            }
            return segments
        }
    }

    public func ingestMic(_ samples16k: [Float]) {
        lock.withLock {
            guard !finished else { return }
            for chunk in micChunker.append(samples16k) { yieldMicLocked(chunk) }
        }
    }

    public func ingestSystem(_ samples16k: [Float]) {
        lock.withLock {
            guard !finished, diarized else { return }
            for chunk in systemChunker.append(samples16k) { yieldSystemLocked(chunk) }
        }
    }

    /// The system-audio tap failed to start (TCC denied): there is no second party
    /// on record, so drop what the dying tap buffered and stop tagging speakers.
    /// Chunks already sent out keep their tag — in production this only ever fires
    /// at start, before a single chunk exists.
    public func systemStreamUnavailable() {
        lock.withLock {
            diarized = false
            _ = systemChunker.flush()
        }
    }

    /// Drains both tails, waits for in-flight inference, returns the transcript
    /// as timestamped segments (recording-relative, one per non-silent chunk).
    /// Call once, after the recorder stopped (no more ingest callbacks).
    public func finish() async -> [TranscriptSegment] {
        lock.withLock {
            guard !finished else { return }
            // Each track's tail is its own last chunk: nothing is mixed, and the
            // shorter stem is not padded to the length of the longer one.
            if let tail = micChunker.flush() { yieldMicLocked(tail) }
            if diarized, let tail = systemChunker.flush() { yieldSystemLocked(tail) }
            finished = true
        }
        continuation.finish()
        // Two clocks, one transcript. Both start at 0, so ties are routine: break
        // them in a fixed speaker order to keep the merge deterministic.
        return await worker.value.sorted { lhs, rhs in
            lhs.start == rhs.start
                ? Self.mergeRank(lhs.speaker) < Self.mergeRank(rhs.speaker)
                : lhs.start < rhs.start
        }
    }

    /// Abandons the pipeline without a transcript (recorder failed to start).
    public func cancel() {
        lock.withLock { finished = true }
        continuation.finish()
        worker.cancel()
    }

    private func yieldMicLocked(_ samples: [Float]) {
        let speaker: Speaker? = diarized ? .me : nil
        continuation.yield(
            Chunk(speaker: speaker, startSample: micEmittedSamples, samples: samples))
        micEmittedSamples += samples.count
    }

    private func yieldSystemLocked(_ samples: [Float]) {
        continuation.yield(
            Chunk(speaker: .them, startSample: systemEmittedSamples, samples: samples))
        systemEmittedSamples += samples.count
    }

    /// me before them before untagged, so a tie reads as the user speaking first.
    private static func mergeRank(_ speaker: Speaker?) -> Int {
        switch speaker {
        case .me: 0
        case .them: 1
        case .none: 2
        }
    }

    /// True when at least one 100 ms frame is loud enough to be worth the model.
    /// Per frame rather than over the whole chunk: one word inside half a minute of
    /// silence must still pass, and averaging would bury it.
    private static func hasSpeech(_ samples: [Float], frame: Int) -> Bool {
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var energy: Float = 0
            for sample in samples[start..<end] {
                energy += sample * sample
            }
            if energy >= speechFrameEnergy { return true }
            start = end
        }
        return false
    }
}
