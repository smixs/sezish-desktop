import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The bridge from the audio callback to a spool file. After a capture is abandoned
/// its callback may still fire, so the stem has to refuse deliveries once closed, and
/// the finalize has to run on the stem's own queue: `PCMSpoolFile` is not thread-safe,
/// and an append racing the header patch would corrupt the take.
@Suite(.timeLimit(.minutes(1))) struct MeetingStemTests {
    private func makeStem() throws -> (MeetingStem, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stem-\(UUID().uuidString).wav")
        return (MeetingStem(spool: try PCMSpoolFile(url: url), label: "test"), url)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    @Test func finishCountsEverythingIngestedBeforeIt() throws {
        let (stem, url) = try makeStem()
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<3 { stem.ingest([Float](repeating: 0.1, count: 1_600)) }

        #expect(try stem.finish() == 4_800)
        #expect(try PCMSpoolReader(url: url).frameCount == 4_800)
    }

    @Test func aClosedStemIgnoresDeliveries() throws {
        let (stem, url) = try makeStem()
        defer { try? FileManager.default.removeItem(at: url) }
        stem.ingest([Float](repeating: 0.1, count: 1_000))
        stem.close()
        stem.ingest([Float](repeating: 0.1, count: 500))

        #expect(try stem.finish() == 1_000)
        #expect(try PCMSpoolReader(url: url).frameCount == 1_000)
    }

    /// Four callback threads keep delivering while the stem is finished: no crash, and
    /// not one byte lands after the header was patched, so the size on disk is exactly
    /// what the header says.
    @Test func deliveriesRacingTheFinishNeverWriteAfterIt() throws {
        let (stem, url) = try makeStem()
        defer { try? FileManager.default.removeItem(at: url) }
        let started = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: done) {
                started.signal()
                // Far more than the finish needs to start: the deliveries run on
                // through it and past it.
                for _ in 0..<3_000 { stem.ingest([Float](repeating: 0.2, count: 160)) }
            }
        }
        for _ in 0..<4 { started.wait() }
        for _ in 0..<50 { stem.ingest([Float](repeating: 0.2, count: 160)) }
        let frames = try stem.finish()
        done.wait()

        #expect(try PCMSpoolReader(url: url).frameCount == frames)
        #expect(try fileSize(url) == 44 + frames * 2)
    }
}

