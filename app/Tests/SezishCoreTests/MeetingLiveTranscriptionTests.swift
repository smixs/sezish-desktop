import Foundation
import Testing
@testable import SezishCore

/// Labels each chunk by arrival order (and remembers its size and peak level), so
/// tests can assert chunk boundaries, strict ordering of the final transcript and
/// what actually reached inference.
private final class ChunkLoggingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chunkSizes: [Int] = []
    private(set) var chunkPeaks: [Float] = []

    func transcribe(_ samples16k: [Float]) async throws -> String {
        let index: Int = lock.withLock {
            chunkSizes.append(samples16k.count)
            chunkPeaks.append(samples16k.reduce(0) { Swift.max($0, Swift.abs($1)) })
            return chunkSizes.count
        }
        // The first chunk sleeps longest: if ordering relied on completion
        // time instead of the serial stream, the transcript would come out
        // reversed.
        try? await Task.sleep(nanoseconds: UInt64(max(0, 4 - index)) * 20_000_000)
        return "c\(index)"
    }
}

private struct FailingTranscriber: Transcriber {
    func transcribe(_ samples16k: [Float]) async throws -> String {
        throw CancellationError()
    }
}

/// Throws on every second call and counts its calls, so a test can assert the
/// failure counter against the real number of chunks the chunker produced.
private final class EveryOtherFailingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0

    func transcribe(_ samples16k: [Float]) async throws -> String {
        let index: Int = lock.withLock {
            calls += 1
            return calls
        }
        if index % 2 == 0 { throw CancellationError() }
        return "c\(index)"
    }
}

@Suite struct TranscriptChunkerTests {
    /// 1 s of steady signal, optionally with a dead-silent 100 ms hole.
    private func second(holeAt holeStart: Int? = nil) -> [Float] {
        var out = [Float](repeating: 0.2, count: 16_000)
        if let holeStart {
            for i in holeStart..<min(holeStart + 1_600, 16_000) { out[i] = 0 }
        }
        return out
    }

    @Test func emitsNothingBelowTarget() {
        var chunker = TranscriptChunker(targetSeconds: 2)
        #expect(chunker.append([Float](repeating: 0.1, count: 16_000)).isEmpty)
        #expect(chunker.flush()?.count == 16_000)
        #expect(chunker.flush() == nil) // emptied
    }

    @Test func cutsAtTheQuietestMomentOfTheTailWindow() {
        // Target 4 s, search tail 2 s. Silence hole mid-second-3 (samples
        // 40_000-41_600) — the cut must land inside it, not at the hard 4 s mark.
        var chunker = TranscriptChunker(targetSeconds: 4, quietSearchSeconds: 2)
        var chunks: [[Float]] = []
        for index in 0..<4 {
            chunks += chunker.append(second(holeAt: index == 2 ? 8_000 : nil))
        }
        #expect(chunks.count == 1)
        let cut = chunks[0].count
        #expect(cut >= 40_000 && cut <= 41_600, "cut at \(cut), expected inside the silence hole")
    }

    @Test func longStreamYieldsEveryChunkAndTail() {
        var chunker = TranscriptChunker(targetSeconds: 1, quietSearchSeconds: 0.2)
        var total: [[Float]] = []
        for _ in 0..<10 { // 5 s in half-second pushes
            total += chunker.append([Float](repeating: 0.3, count: 8_000))
        }
        if let tail = chunker.flush() { total.append(tail) }
        #expect(total.reduce(0) { $0 + $1.count } == 80_000) // nothing lost
        #expect(total.count >= 5)
    }
}

@Suite struct MeetingTranscriptionPipelineTests {
    // MARK: - Helpers

    /// Every segment's text is "cN", the arrival index of its chunk, so a test can
    /// look that chunk's size back up and rebuild the clock the pipeline kept.
    private func chunkIndex(_ segment: TranscriptSegment) -> Int {
        (Int(segment.text.dropFirst()) ?? 0) - 1
    }

    /// Asserts one track's segments carry the prefix sums of their own chunk sizes.
    /// A counter shared between the tracks, or a mixed stream, shifts every start
    /// after the first — which is exactly the old behaviour this replaces.
    private func expectOwnClock(_ track: [TranscriptSegment], sizes: [Int]) {
        var clock = 0
        for segment in track {
            #expect(abs(segment.start - Double(clock) / 16_000) < 0.001)
            clock += sizes[chunkIndex(segment)]
        }
    }

    /// The merge order of the finished transcript: by time, ties me → them → untagged.
    private func mergeRank(_ speaker: Speaker?) -> Int {
        switch speaker {
        case .me: 0
        case .them: 1
        case .none: 2
        }
    }

    // MARK: - Two-track diarization

    @Test func tagsBothTracksAndMergesThemByTimestamp() async {
        let transcriber = ChunkLoggingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: true, chunkSeconds: 1)
        // Alternating taps with unequal totals (mic 20 000 frames, system 12 000):
        // the short stem must neither stretch nor truncate the long one.
        for push in 0..<25 {
            pipeline.ingestMic([Float](repeating: 0.1, count: 800))
            if push < 15 { pipeline.ingestSystem([Float](repeating: 0.1, count: 800)) }
        }
        let segments = await pipeline.finish()

        let me = segments.filter { $0.speaker == .me }
        let them = segments.filter { $0.speaker == .them }
        #expect(me.count >= 2) // the long stem was cut at least once mid-recording
        #expect(them.count >= 1)
        #expect(me.count + them.count == segments.count) // nothing untagged

        // Each track's texts follow its own chunk arrival order, despite the mock
        // sleeping longest on the earliest chunks.
        #expect(me.map(chunkIndex) == me.map(chunkIndex).sorted())
        #expect(them.map(chunkIndex) == them.map(chunkIndex).sorted())
        expectOwnClock(me, sizes: transcriber.chunkSizes)
        expectOwnClock(them, sizes: transcriber.chunkSizes)
        #expect(them.first?.start == 0) // its own clock, not a continuation of the mic's

        let merged = segments.sorted { lhs, rhs in
            lhs.start == rhs.start
                ? mergeRank(lhs.speaker) < mergeRank(rhs.speaker)
                : lhs.start < rhs.start
        }
        #expect(segments == merged)

        // Both tracks transcribed whole and separately — a mix would halve this.
        #expect(transcriber.chunkSizes.reduce(0, +) == 32_000)
    }

    @Test func micOnlyRecordingIsUndiarized() async {
        let transcriber = ChunkLoggingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: false, chunkSeconds: 1)
        for _ in 0..<10 { pipeline.ingestMic([Float](repeating: 0.1, count: 4_000)) }
        let segments = await pipeline.finish()

        // No second party to contrast with, so no labels — today's behaviour.
        #expect(segments.allSatisfy { $0.speaker == nil })
        #expect(segments.map(\.text) == (1...segments.count).map { "c\($0)" })
        #expect(transcriber.chunkSizes.reduce(0, +) == 40_000)
        expectOwnClock(segments, sizes: transcriber.chunkSizes)
    }

    @Test func systemStreamUnavailableMidStreamUntagsLaterChunks() async {
        let transcriber = ChunkLoggingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: true, chunkSeconds: 1)
        pipeline.ingestMic([Float](repeating: 0.1, count: 16_000)) // cuts one mic chunk
        pipeline.ingestSystem([Float](repeating: 0.1, count: 16_000)) // and one system chunk
        pipeline.systemStreamUnavailable() // the tap died mid-call
        pipeline.ingestMic([Float](repeating: 0.1, count: 16_000))
        pipeline.ingestSystem([Float](repeating: 0.1, count: 16_000)) // must be ignored
        let segments = await pipeline.finish()

        let them = segments.filter { $0.speaker == .them }
        #expect(them.count == 1) // only what the tap delivered before it died

        // Mic chunks cut before the call keep their tag; everything after is
        // untagged, because from there on there is only one voice on record.
        let mic = segments.filter { $0.speaker != .them }
        #expect(mic.first?.speaker == .me)
        #expect(mic.dropFirst().allSatisfy { $0.speaker == nil })
        #expect(mic.count >= 2)

        // 32 000 mic frames plus that one system chunk: the buffered system tail is
        // dropped by the call and the later system push never enters the pipeline.
        let themSize = them.map { transcriber.chunkSizes[chunkIndex($0)] }.reduce(0, +)
        #expect(transcriber.chunkSizes.reduce(0, +) == 32_000 + themSize)
        #expect(themSize < 16_000)
    }

    // MARK: - Silence gate

    @Test func quietChunksSkipInferenceWithoutBreakingTheClock() async {
        let transcriber = ChunkLoggingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: false, chunkSeconds: 1)
        // Loud, room tone, loud. The lengths are picked so the chunker's quiet cuts
        // land on the two boundaries: the middle chunk is pure room tone, and the
        // 30 000-frame stream ends before a third cut, so the last loud stretch is
        // the flushed tail.
        var stream = [Float](repeating: 0.1, count: 8_800)
        stream += [Float](repeating: 0.0005, count: 10_400)
        stream += [Float](repeating: 0.1, count: 10_800)
        pipeline.ingestMic(stream)
        let segments = await pipeline.finish()

        #expect(transcriber.chunkSizes.count == 2) // the quiet chunk never reached the model
        #expect(transcriber.chunkPeaks.allSatisfy { $0 > 0.01 })
        #expect(segments.count == 2)
        #expect(segments[0].start == 0)

        // The skipped chunk still advanced the clock: the counter tracks emitted
        // samples, not transcribed ones, so the tail sits where the audio does.
        let skipped = 30_000 - transcriber.chunkSizes.reduce(0, +)
        #expect(skipped > 0)
        let tailStart = Double(30_000 - transcriber.chunkSizes[1]) / 16_000
        #expect(abs(segments[1].start - tailStart) < 0.001)
    }

    // MARK: - Failure and lifecycle

    @Test func failedChunksAreDroppedNotFatal() async {
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: FailingTranscriber(), hasSystemStream: false, chunkSeconds: 1)
        pipeline.ingestMic([Float](repeating: 0.1, count: 40_000))
        let segments = await pipeline.finish()
        #expect(segments.isEmpty) // no transcript, no crash — caller reports "no text"
        #expect(pipeline.failedChunkCount > 0)
    }

    @Test func failedChunkCountCountsThrowingChunks() async {
        let transcriber = EveryOtherFailingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: false, chunkSeconds: 1)
        pipeline.ingestMic([Float](repeating: 0.1, count: 64_000))
        let segments = await pipeline.finish()

        // Counted against the transcriber's own calls, not against a chunk count
        // guessed from the chunker's cut geometry.
        #expect(transcriber.calls >= 4)
        #expect(pipeline.failedChunkCount == transcriber.calls / 2)
        #expect(segments.count == transcriber.calls - transcriber.calls / 2)
    }

    @Test func cancelStopsWorkAndIngestAfterFinishIsIgnored() async {
        let transcriber = ChunkLoggingTranscriber()
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: false, chunkSeconds: 1)
        pipeline.ingestMic([Float](repeating: 0.1, count: 4_000))
        let segments = await pipeline.finish()
        #expect(segments.map(\.text) == ["c1"])
        #expect(segments.first?.start == 0)
        pipeline.ingestMic([Float](repeating: 0.1, count: 16_000)) // late audio-thread callback
        #expect(transcriber.chunkSizes.reduce(0, +) == 4_000)

        let cancelled = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: false, chunkSeconds: 1)
        cancelled.ingestMic([Float](repeating: 0.1, count: 4_000))
        cancelled.cancel() // must not hang or crash
    }

    // MARK: - Rendering

    @Test func timestampLabelFormatsMinutesAndHours() {
        #expect(TranscriptSegment(start: 0, text: "x").timestampLabel == "[0:00]")
        #expect(TranscriptSegment(start: 192.7, text: "x").timestampLabel == "[3:12]")
        #expect(TranscriptSegment(start: 3_792, text: "x").timestampLabel == "[1:03:12]")
    }

    @Test func renderLabelsOnlyTaggedSegments() {
        #expect(TranscriptSegment.render([], meLabel: "Я", themLabel: "Собеседник") == nil)

        let dialogue = [
            TranscriptSegment(start: 3, text: "привет", speaker: .me),
            TranscriptSegment(start: 5.4, text: "и тебе", speaker: .them),
        ]
        #expect(
            TranscriptSegment.render(dialogue, meLabel: "Я", themLabel: "Собеседник")
                == "[0:03] Я: привет\n\n[0:05] Собеседник: и тебе")

        // Undiarized recording: a label would claim knowledge the pipeline lacks.
        let monologue = [TranscriptSegment(start: 0, text: "заметка")]
        #expect(
            TranscriptSegment.render(monologue, meLabel: "Я", themLabel: "Собеседник")
                == "[0:00] заметка")
    }
}
