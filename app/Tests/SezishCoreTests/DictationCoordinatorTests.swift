import Foundation
import Testing
@testable import SezishCore

private struct TestError: Error {}

private final class MockMic: MicCapture, @unchecked Sendable {
    let samples: [Float]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    init(samples: [Float]) { self.samples = samples }
    func start() throws { startCount += 1 }
    func stop() async throws -> [Float] { stopCount += 1; return samples }
}

private final class MockTranscriber: Transcriber, @unchecked Sendable {
    let result: Result<String, Error>
    private(set) var callCount = 0
    init(_ result: Result<String, Error>) { self.result = result }
    func transcribe(_ samples16k: [Float]) async throws -> String {
        callCount += 1
        return try result.get()
    }
}

private final class MockInserter: TextInserter, @unchecked Sendable {
    private(set) var inserted: [String] = []
    func insert(_ text: String) async throws { inserted.append(text) }
}

private struct InsertFailure: LocalizedError {
    var errorDescription: String? { "paste blocked — press ⌘V" }
}

/// Fails every insertion — stands in for the secure-input guard in the real inserter.
private final class ThrowingInserter: TextInserter, @unchecked Sendable {
    private(set) var callCount = 0
    func insert(_ text: String) async throws {
        callCount += 1
        throw InsertFailure()
    }
}

/// Blocks `transcribe` until the test opens the gate — lets us observe the Processing state.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
    var isOpen: Bool { opened }
    /// Bounded wait for a call that may never come: yields (no real time) up to
    /// `maxYields` times and reports whether the gate opened, so a missing call fails
    /// the test instead of hanging it.
    func wait(maxYields: Int) async -> Bool {
        var spins = 0
        while !opened && spins < maxYields {
            await Task.yield()
            spins += 1
        }
        return opened
    }
}

private final class GatedTranscriber: Transcriber, @unchecked Sendable {
    private let gate: Gate
    private(set) var callCount = 0
    init(gate: Gate) { self.gate = gate }
    func transcribe(_ samples16k: [Float]) async throws -> String {
        callCount += 1
        await gate.wait()
        return "gated"
    }
}

/// Streaming engine: audio goes in while recording, the transcript comes out of
/// `finishStream()`. `startStream()` runs detached, so it reports through `started`:
/// the gate is the only synchronised edge between that task and the test.
private final class MockStreamingTranscriber: StreamingTranscriber, @unchecked Sendable {
    let result: Result<String, Error>
    let started = Gate()
    private(set) var startStreamCount = 0
    private(set) var feedCalls: [[Float]] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var transcribeCount = 0
    private(set) var warmupCount = 0
    init(_ result: Result<String, Error>) { self.result = result }
    func transcribe(_ samples16k: [Float]) async throws -> String {
        transcribeCount += 1
        return try result.get()
    }
    func warmup() async throws { warmupCount += 1 }
    func startStream() async {
        startStreamCount += 1
        await started.open()
    }
    func feed(_ samples16k: [Float]) { feedCalls.append(samples16k) }
    func finishStream() async throws -> String {
        finishCount += 1
        return try result.get()
    }
    func cancelStream() async { cancelCount += 1 }
}

/// `begin()` opens the stream from a detached task. Waits on the mock's gate — that
/// hop is also what makes the mock's counters safe to read afterwards — and reports
/// whether the call ever landed, so a regression fails instead of hanging.
private func awaitStreamStart(_ transcriber: MockStreamingTranscriber) async -> Bool {
    await transcriber.started.wait(maxYields: 100_000)
}

/// Records the order of session calls across concurrency domains.
private actor CallLog {
    private(set) var calls: [String] = []
    func append(_ name: String) { calls.append(name) }
}

/// A session that stays half-open until the test says otherwise: `startStream()` parks
/// on `release`, and `finishing` reports the moment `finishStream()` is entered. A
/// caller without a happens-before edge to `startStream()` trips `finishing` early.
private final class SlowStartTranscriber: StreamingTranscriber, @unchecked Sendable {
    let log = CallLog()
    let release = Gate()
    let finishing = Gate()
    func transcribe(_ samples16k: [Float]) async throws -> String { "буфер" }
    func startStream() async {
        await release.wait()
        await log.append("startStream")
    }
    func feed(_ samples16k: [Float]) {}
    func finishStream() async throws -> String {
        await finishing.open()
        await log.append("finishStream")
        return "поток"
    }
    func cancelStream() async { await log.append("cancelStream") }
}

/// A mic whose `stop()` fails — the device went away mid-take.
private final class ThrowingMic: MicCapture, @unchecked Sendable {
    private(set) var stopCount = 0
    func start() throws {}
    func stop() async throws -> [Float] {
        stopCount += 1
        throw TestError()
    }
}

private func tmpHistory() throws -> (DictationHistory, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sezish-coord-\(UUID().uuidString)", isDirectory: true)
    return (try DictationHistory(directory: dir), dir)
}

/// A recording long enough to clear the 0.3 s minimum (0.5 s @ 16 kHz).
private let longEnough = [Float](repeating: 0.1, count: 8_000)

@Suite @MainActor struct DictationCoordinatorTests {
    @Test func happyPathRecordsTranscribesInsertsAndStores() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockTranscriber(.success("готово"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        #expect(coord.state == .recording)
        #expect(mic.startCount == 1)

        await coord.end()
        #expect(coord.state == .idle)
        #expect(mic.stopCount == 1)
        #expect(transcriber.callCount == 1)
        #expect(inserter.inserted == ["готово"])
        #expect(history.records.count == 1)
        #expect(history.records.first?.text == "готово")
    }

    @Test func transcribeErrorKeepsAudioWithEmptyTextAndSkipsInsert() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockTranscriber(.failure(TestError()))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(coord.state == .idle)
        #expect(outcome == .noText)
        #expect(transcriber.callCount == 1)
        #expect(inserter.inserted.isEmpty)
        // The take is never lost: audio is stored with an empty transcript.
        #expect(history.records.count == 1)
        #expect(history.records.first?.text == "")
        if let url = history.records.first?.audioURL {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func emptyTranscriptKeepsAudioWithoutInsert() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockTranscriber(.success(""))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(outcome == .noText)
        #expect(inserter.inserted.isEmpty)
        #expect(history.records.count == 1)
    }

    @Test func beginDuringProcessingIsIgnored() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let gate = Gate()
        let transcriber = GatedTranscriber(gate: gate)
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        #expect(coord.state == .recording)

        let task = Task { await coord.end() }

        var spins = 0
        while coord.state != .processing && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(coord.state == .processing)

        coord.begin() // must be ignored while processing
        #expect(coord.state == .processing)
        #expect(mic.startCount == 1)

        await gate.open()
        await task.value

        #expect(coord.state == .idle)
        #expect(inserter.inserted == ["gated"])
        #expect(history.records.count == 1)
    }

    @Test func insertFailureStillStoresTranscriptToHistory() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockTranscriber(.success("привет"))
        let inserter = ThrowingInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(coord.state == .idle)
        #expect(inserter.callCount == 1)
        // A paste failure must not discard the transcript: it is still persisted.
        #expect(history.records.count == 1)
        #expect(history.records.first?.text == "привет")
        // ...and the failure is surfaced with the inserter's actionable message.
        #expect(outcome == .insertFailed("paste blocked — press ⌘V"))
    }

    @Test func recordingShorterThanMinimumIsDiscarded() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // One sample under 0.3 s — a stray tap of the push-to-talk key.
        let mic = MockMic(samples: [Float](repeating: 0.1, count: DictationCoordinator.minimumSamples - 1))
        let transcriber = MockTranscriber(.success("готово"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        await coord.end()

        #expect(coord.state == .idle)
        #expect(mic.stopCount == 1)
        #expect(transcriber.callCount == 0)   // never transcribed
        #expect(inserter.inserted.isEmpty)    // never inserted
        #expect(history.records.isEmpty)      // never stored
    }

    @Test func recordingAtMinimumIsKept() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Exactly 0.3 s — the boundary must be transcribed.
        let mic = MockMic(samples: [Float](repeating: 0.1, count: DictationCoordinator.minimumSamples))
        let transcriber = MockTranscriber(.success("ok"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        await coord.end()

        #expect(transcriber.callCount == 1)
        #expect(inserter.inserted == ["ok"])
        #expect(history.records.count == 1)
    }

    // MARK: - Engine provenance

    @Test func storedRecordCarriesTheCoordinatorEngine() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: MockTranscriber(.success("готово")), engine: "local",
            inserter: inserter, history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(outcome == .inserted)
        #expect(history.records.last?.engine == "local")
    }

    @Test func noTextRecordCarriesTheCoordinatorEngine() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let coord = DictationCoordinator(
            mic: mic, transcriber: MockTranscriber(.failure(TestError())), engine: "cloud",
            inserter: MockInserter(), history: history)

        coord.begin()
        let outcome = await coord.end()

        // The kept-anyway take must be attributable too: that is the path where a
        // degraded engine shows up first.
        #expect(outcome == .noText)
        #expect(history.records.last?.text == "")
        #expect(history.records.last?.engine == "cloud")
    }

    // MARK: - Esc cancel

    @Test func cancelDiscardsEverything() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough) // plenty long — must be dropped anyway
        let transcriber = MockTranscriber(.success("готово"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        await coord.cancel()

        #expect(coord.state == .idle)
        #expect(mic.stopCount == 1)          // mic was shut down
        #expect(transcriber.callCount == 0)  // never transcribed
        #expect(inserter.inserted.isEmpty)   // never inserted
        #expect(history.records.isEmpty)     // never stored — the take never existed
    }

    @Test func cancelWhileIdleIsNoOp() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let coord = DictationCoordinator(
            mic: mic, transcriber: MockTranscriber(.success("x")), engine: "cloud",
            inserter: MockInserter(), history: history)

        await coord.cancel()
        #expect(coord.state == .idle)
        #expect(mic.stopCount == 0)
    }

    @Test func beginAfterCancelStartsAFreshTake() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockTranscriber(.success("второй"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "cloud", inserter: inserter, history: history)

        coord.begin()
        await coord.cancel()
        coord.begin()
        #expect(coord.state == .recording)
        await coord.end()

        #expect(inserter.inserted == ["второй"])
        #expect(history.records.count == 1)
    }

    // MARK: - Failure reason

    @Test func transcribeErrorStoresItsReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.failure(TranscribeFailure())),
            engine: "cloud", inserter: MockInserter(), history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(outcome == .noText)
        // The reason is what the user will read in the history, so it must be the
        // localized message, not the raw enum case.
        #expect(history.records.first?.error == "сеть недоступна")
    }

    @Test func emptyTranscriptStoresEmptyReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.success("")),
            engine: "cloud", inserter: MockInserter(), history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(outcome == .noText)
        #expect(history.records.first?.error == DictationCoordinator.emptyTranscriptReason)
        #expect(DictationCoordinator.emptyTranscriptReason == "empty")
    }

    /// A plain Swift error has no message for people: the record stores a marker
    /// instead of the type name.
    @Test func plainTranscribeErrorStoresUnknownReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.failure(TestError())),
            engine: "cloud", inserter: MockInserter(), history: history)

        coord.begin()
        let outcome = await coord.end()

        #expect(outcome == .noText)
        #expect(history.records.first?.error == DictationCoordinator.unknownFailureReason)
        #expect(DictationCoordinator.unknownFailureReason == "unknown")
    }

    // MARK: - Retranscribe

    @Test func retranscribeUpdatesRecordAndReturnsText() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockTranscriber(.success("перегнали"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "local",
            inserter: inserter, history: history)
        let rec = try history.add(
            text: "", samples16k: longEnough, engine: "cloud", error: "сеть недоступна")

        let outcome = await coord.retranscribe(rec)

        #expect(outcome == .done("перегнали"))
        #expect(coord.state == .idle)
        #expect(transcriber.callCount == 1)
        #expect(inserter.inserted.isEmpty) // retry never types into the active window
        #expect(history.records.count == 1)
        let updated = try #require(history.records.first)
        #expect(updated.id == rec.id)
        #expect(updated.text == "перегнали")
        #expect(updated.engine == "local")
        #expect(updated.error == nil)
        #expect(updated.audioURL == rec.audioURL)
    }

    @Test func retranscribeFailureKeepsAudioAndStoresReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.failure(TranscribeFailure())),
            engine: "cloud", inserter: MockInserter(), history: history)
        let rec = try history.add(text: "", samples16k: longEnough, engine: "cloud", error: "старая причина")

        let outcome = await coord.retranscribe(rec)

        #expect(outcome == .noText)
        #expect(coord.state == .idle)
        let updated = try #require(history.records.first)
        #expect(updated.id == rec.id)
        #expect(updated.text == "")
        // The original reason stays in front: it is the one that explains the take.
        #expect(updated.error == "старая причина → сеть недоступна")
        let wav = try #require(updated.audioURL)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    /// The retry runs on whatever engine is selected now, which is not the one that lost the
    /// take. Stamping it over the record erases the only evidence of what actually broke.
    @Test func retranscribeFailureKeepsTheOriginalEngineAndReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough),
            transcriber: MockTranscriber(.failure(TranscribeFailure())),
            engine: "gemini/live-smart", inserter: MockInserter(), history: history)
        let rec = try history.add(
            text: "", samples16k: longEnough, engine: "local/v3", error: "ORT сломался")

        #expect(await coord.retranscribe(rec) == .noText)

        let first = try #require(history.records.first)
        #expect(first.engine == "local/v3")
        #expect(first.error == "ORT сломался → сеть недоступна")

        // A second retry replaces its own half instead of stacking another line.
        #expect(await coord.retranscribe(first) == .noText)

        let second = try #require(history.records.first)
        #expect(second.engine == "local/v3")
        #expect(second.error == "ORT сломался → сеть недоступна")
    }

    @Test(arguments: [
        (nil, "сеть недоступна", "сеть недоступна"),
        ("", "сеть недоступна", "сеть недоступна"),
        ("ORT сломался", "сеть недоступна", "ORT сломался → сеть недоступна"),
        ("ORT сломался", "ORT сломался", "ORT сломался"),
        // Markers are for the code; a line the user reads must not be built out of them.
        ("empty", "сеть недоступна", "сеть недоступна"),
        ("unknown", "сеть недоступна", "сеть недоступна"),
        ("ORT сломался", "empty", "ORT сломался"),
        ("ORT сломался", "unknown", "ORT сломался"),
    ])
    func retryReasonKeepsTheOriginalInFront(original: String?, retry: String, expected: String) {
        #expect(DictationCoordinator.reason(original: original, retry: retry) == expected)
    }

    @Test func retranscribeWhileRecordingIsBusy() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockTranscriber(.success("перегнали"))
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "cloud",
            inserter: MockInserter(), history: history)
        let rec = try history.add(text: "", samples16k: longEnough, engine: "cloud", error: "boom")

        coord.begin()
        let outcome = await coord.retranscribe(rec)

        #expect(outcome == .busy)
        #expect(coord.state == .recording)
        #expect(transcriber.callCount == 0)
        #expect(history.records.first?.text == "")
    }

    @Test func beginDuringRetranscribeIsIgnored() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let gate = Gate()
        let coord = DictationCoordinator(
            mic: mic, transcriber: GatedTranscriber(gate: gate), engine: "cloud",
            inserter: MockInserter(), history: history)
        let rec = try history.add(text: "", samples16k: longEnough, engine: "cloud", error: "boom")

        let task = Task { await coord.retranscribe(rec) }

        var spins = 0
        while coord.state != .processing && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(coord.state == .processing)

        coord.begin() // the hotkey must not start a take while a retry is running
        #expect(coord.state == .processing)
        #expect(mic.startCount == 0)

        await gate.open()
        let outcome = await task.value

        #expect(outcome == .done("gated"))
        #expect(coord.state == .idle)
        #expect(history.records.first?.text == "gated")
    }

    /// A take that already has text must survive a failed retry untouched: the stored
    /// transcript is still the best one we have.
    @Test func retranscribeFailureKeepsExistingText() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.failure(TranscribeFailure())),
            engine: "local", inserter: MockInserter(), history: history)
        let rec = try history.add(text: "старый текст", samples16k: longEnough, engine: "cloud")

        let outcome = await coord.retranscribe(rec)

        #expect(outcome == .noText)
        #expect(history.records.count == 1)
        let stored = try #require(history.records.first)
        #expect(stored.id == rec.id)
        #expect(stored.text == "старый текст")
        #expect(stored.engine == "cloud")
        #expect(stored.error == nil)
    }

    /// A record whose index entry lost its audio path: nothing to feed the transcriber,
    /// and the thrown error carries no message for people.
    @Test func retranscribeWithoutAudioStoresUnknownReason() async throws {
        let (writer, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No stored reason: the retry's own «unknown» is all there is to write.
        try writer.add(text: "", samples16k: longEnough, engine: "cloud")
        let indexURL = dir.appendingPathComponent("index.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: indexURL))
        var entries = try #require(raw as? [[String: Any]])
        for i in entries.indices { entries[i].removeValue(forKey: "audioURL") }
        try JSONSerialization.data(withJSONObject: entries).write(to: indexURL, options: .atomic)

        let history = try DictationHistory(directory: dir)
        let rec = try #require(history.records.first)
        #expect(rec.audioURL == nil)
        let transcriber = MockTranscriber(.success("перегнали"))
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "local",
            inserter: MockInserter(), history: history)

        let outcome = await coord.retranscribe(rec)

        #expect(outcome == .noText)
        #expect(transcriber.callCount == 0)
        #expect(history.records.first?.error == DictationCoordinator.unknownFailureReason)
    }

    // MARK: - Streaming transcriber

    @Test func beginOpensTheStreamInsteadOfWarmingUp() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockStreamingTranscriber(.success("поток"))
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "gemini",
            inserter: MockInserter(), history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))

        #expect(coord.state == .recording)
        #expect(transcriber.startStreamCount == 1)
        #expect(transcriber.warmupCount == 0) // the stream itself is the warmup
    }

    @Test func endTakesTheTextFromFinishStream() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockStreamingTranscriber(.success("поток"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "gemini",
            inserter: inserter, history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        let outcome = await coord.end()

        #expect(outcome == .inserted)
        #expect(transcriber.finishCount == 1)
        #expect(transcriber.transcribeCount == 0) // the buffer is never re-sent
        #expect(inserter.inserted == ["поток"])
        #expect(history.records.count == 1)
        #expect(history.records.first?.text == "поток")
        #expect(history.records.first?.engine == "gemini")
    }

    @Test func finishStreamFailureKeepsAudioWithItsReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockStreamingTranscriber(.failure(TranscribeFailure()))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "gemini",
            inserter: inserter, history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        let outcome = await coord.end()

        #expect(outcome == .noText)
        #expect(transcriber.finishCount == 1)
        #expect(inserter.inserted.isEmpty)
        let stored = try #require(history.records.first)
        #expect(stored.text == "")
        #expect(stored.error == "сеть недоступна")
        let wav = try #require(stored.audioURL)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func emptyStreamTranscriptStoresEmptyReason() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = MockStreamingTranscriber(.success(""))
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "gemini",
            inserter: MockInserter(), history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        let outcome = await coord.end()

        #expect(outcome == .noText)
        // The empty string has to come out of the stream, not out of a re-sent buffer.
        #expect(transcriber.finishCount == 1)
        #expect(transcriber.transcribeCount == 0)
        #expect(history.records.first?.error == DictationCoordinator.emptyTranscriptReason)
    }

    /// A stray key-tap: the session must be dropped, not flushed — a finish would
    /// bill a round trip for nothing.
    @Test func shortStreamingClipCancelsTheSession() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: [Float](repeating: 0.1, count: DictationCoordinator.minimumSamples - 1))
        let transcriber = MockStreamingTranscriber(.success("поток"))
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "gemini",
            inserter: MockInserter(), history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        let outcome = await coord.end()

        #expect(outcome == .ignored)
        #expect(transcriber.cancelCount == 1)
        #expect(transcriber.finishCount == 0)
        #expect(history.records.isEmpty)
    }

    @Test func cancelDropsTheStreamingSession() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = MockMic(samples: longEnough)
        let transcriber = MockStreamingTranscriber(.success("поток"))
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "gemini",
            inserter: MockInserter(), history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        await coord.cancel()

        #expect(coord.state == .idle)
        #expect(mic.stopCount == 1)
        #expect(transcriber.cancelCount == 1)
        #expect(transcriber.finishCount == 0)
        #expect(history.records.isEmpty)
    }

    /// The mic died mid-take: there is nothing to transcribe, but the session is
    /// already open and must not be left hanging.
    @Test func micFailureStillDropsTheStreamingSession() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = ThrowingMic()
        let transcriber = MockStreamingTranscriber(.success("поток"))
        let coord = DictationCoordinator(
            mic: mic, transcriber: transcriber, engine: "gemini",
            inserter: MockInserter(), history: history)

        coord.begin()
        #expect(await awaitStreamStart(transcriber))
        let outcome = await coord.end()

        #expect(outcome == .failed)
        #expect(mic.stopCount == 1)
        #expect(transcriber.cancelCount == 1)
        #expect(transcriber.finishCount == 0)
        #expect(history.records.isEmpty)
    }

    /// A live session cannot be flushed before it is open: `finishStream()` must wait
    /// out the `startStream()` that `begin()` launched detached.
    @Test func finishStreamNeverOvertakesStartStream() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriber = SlowStartTranscriber()
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: transcriber, engine: "gemini",
            inserter: inserter, history: history)

        coord.begin()
        let take = Task { await coord.end() }

        // The session is still opening. Poll from here, on the MainActor, so every hop
        // hands `end()` a slot to run in — spinning inside another actor would starve it
        // and pass for the wrong reason. Reaching `finishStream()` in any of these hops
        // means the flush overtook the opening.
        var overtook = false
        var spins = 0
        while spins < 10_000 {
            if await transcriber.finishing.isOpen {
                overtook = true
                break
            }
            await Task.yield()
            spins += 1
        }
        #expect(overtook == false)

        await transcriber.release.open()
        let outcome = await take.value

        #expect(outcome == .inserted)
        #expect(await transcriber.log.calls == ["startStream", "finishStream"])
        #expect(inserter.inserted == ["поток"])
    }

    /// The record went away mid-retry: the text is transcribed but cannot be written
    /// back, so the retry reports failure rather than a result nobody stored.
    @Test func retranscribeUnknownRecordIsNoText() async throws {
        let (history, dir) = try tmpHistory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = DictationCoordinator(
            mic: MockMic(samples: longEnough), transcriber: MockTranscriber(.success("перегнали")),
            engine: "local", inserter: MockInserter(), history: history)
        let stored = try history.add(text: "", samples16k: longEnough, engine: "cloud", error: "boom")
        // Same audio, an id this history never saw.
        let ghost = DictationRecord(text: "", audioURL: stored.audioURL, engine: "cloud", error: "boom")

        let outcome = await coord.retranscribe(ghost)

        #expect(outcome == .noText)
        #expect(history.records.count == 1)
        #expect(history.records.first?.text == "")
        #expect(history.records.first?.error == "boom")
    }
}

/// A transcriber failure that carries a user-facing message, like the cloud one does.
private struct TranscribeFailure: LocalizedError {
    var errorDescription: String? { "сеть недоступна" }
}
