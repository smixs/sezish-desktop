import Foundation
import Testing

@testable import SezishAsr

@Suite("GeminiLiveTranscriber")
struct GeminiLiveTranscriberTests {
    private func makeTranscriber(
        transport: FakeWebSocket,
        clock: any Clock<Duration> = ContinuousClock(),
        mode: GeminiTranscriptionMode = .smart,
        keepaliveInterval: Duration = .seconds(30),
        staleAfter: Duration = .seconds(45)
    ) -> GeminiLiveTranscriber {
        GeminiLiveTranscriber(
            apiKey: "test-key", mode: mode, transport: transport, clock: clock,
            setupTimeout: .seconds(10), finalTimeout: .seconds(20),
            keepaliveInterval: keepaliveInterval, staleAfter: staleAfter)
    }

    /// Ends the take: waits for `activityEnd` to be on the wire, then plays the server's answer.
    private func answerTake(
        _ ws: FakeWebSocket, sendsBeforeEnd: Int, finals: [String], interim: String? = nil
    ) async {
        await ws.waitForSends(sendsBeforeEnd + 1)
        ws.enqueue(Frame.emptyContent)
        if let interim { ws.enqueue(Frame.interim(interim)) }
        for text in finals { ws.enqueue(Frame.final(text)) }
        ws.enqueue(Frame.generationComplete)
    }

    /// Lets other tasks run without spending real time: the coordinator fires `startStream`
    /// detached, so tests have to let that task make progress before the next step.
    private func settle(_ times: Int = 50) async {
        for _ in 0..<times { await Task.yield() }
    }

    /// Waits for a condition on the same budget as `settle`, and gives up instead of parking:
    /// a missing ping has to show up as a failed expectation, not as a stuck run.
    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Ends the take and returns its text.
    private func finishTake(
        _ transcriber: GeminiLiveTranscriber, _ ws: FakeWebSocket,
        sendsBeforeEnd: Int, final: String
    ) async throws -> String {
        async let text = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: sendsBeforeEnd, finals: [final])
        return try await text
    }

    @Test func finishBeforeSetupCompleteKeepsTheFrameOrder() async throws {
        let ws = FakeWebSocket()
        ws.autoSetupComplete = false // the session is still opening
        let transcriber = makeTranscriber(transport: ws)

        let started = Task { await transcriber.startStream() }
        await ws.waitForSends(1) // setup is on the wire, setupComplete is not back yet
        transcriber.feed([Float](repeating: 0.1, count: 3_200))
        let finished = Task { try await transcriber.finishStream() }
        await settle() // the short tap: end of speech lands while the socket is still opening

        ws.enqueue(Frame.setupComplete)
        await ws.waitForSends(5)
        ws.enqueue(Frame.final("Дай мне промпт"))
        ws.enqueue(Frame.generationComplete)

        #expect(try await finished.value == "Дай мне промпт")
        await started.value
        #expect(ws.sent.count == 5)
        #expect(ws.setupFrames.count == 1)
        #expect(ws.sent[1] == GeminiLiveProtocol.activityStartMessage)
        #expect(ws.audioPayloadSizes == [3_200, 3_200])
        #expect(ws.sent.last == GeminiLiveProtocol.activityEndMessage)
    }

    @Test func cancelDuringSetupReturnsWithoutWaitingForTheTimeout() async throws {
        let ws = FakeWebSocket()
        ws.autoSetupComplete = false
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        let started = Task { await transcriber.startStream() }
        await ws.waitForSends(1)
        await transcriber.cancelStream() // Esc must not sit through setupTimeout
        #expect(ws.closeCount == 1)
        await started.value

        ws.autoSetupComplete = true
        await transcriber.startStream()
        async let text = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 3, finals: ["после отмены"])

        #expect(try await text == "после отмены")
        #expect(ws.connectCount == 2)
    }

    @Test func takeSendsSetupActivityAudioAndReturnsTheFinal() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        #expect(ws.setupFrames.count == 1)
        #expect(ws.activityStarts == 1)
        #expect(ws.sent.count == 2)

        transcriber.feed([Float](repeating: 0.1, count: 3_200))
        await ws.waitForSends(4)
        #expect(ws.audioPayloadSizes == [3_200, 3_200])

        // Less than a 100 ms chunk stays in the buffer until the take ends.
        transcriber.feed([Float](repeating: 0.2, count: 800))
        #expect(ws.sent.count == 4)

        async let text = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 5, finals: ["Дай мне промпт"], interim: "Дай мне, блядь, промт")

        #expect(try await text == "Дай мне промпт")
        #expect(ws.audioPayloadSizes == [3_200, 3_200, 1_600])
        #expect(ws.activityEnds == 1)
        #expect(ws.sent.last == GeminiLiveProtocol.activityEndMessage)
        #expect(ws.closeCount == 0)
        #expect(ws.connects.first?.absoluteString.contains("key=test-key") == true)
    }

    @Test func audioFedWhileFinishingStaysInOrderBeforeActivityEnd() async throws {
        let ws = FakeWebSocket()
        let hold = SendHold()
        ws.audioHold = hold
        let transcriber = makeTranscriber(transport: ws)

        let first = [Float](repeating: 0.1, count: 1_600)
        let second = [Float](repeating: 0.2, count: 1_600)

        await transcriber.startStream()
        transcriber.feed(first)
        await hold.waitForEntries(1) // the first audio frame is in flight

        let finished = Task { try await transcriber.finishStream() }
        await settle() // finishStream is inside flushTail, waiting for that drain
        transcriber.feed(second) // the mic tap delivers one more buffer after the key went up
        await settle()
        // Only the drain `finishStream` waits for may touch the wire now. A second one
        // running in parallel would already be pushing this buffer out.
        #expect(hold.entries == 1)

        hold.releaseNext() // the first frame goes out
        await hold.waitForEntries(2) // the second one is now in flight, still held
        await settle(200)
        // Whoever sends it, `finishStream` owns that frame: end of speech cannot be
        // announced before the audio it belongs to has landed.
        #expect(ws.sent.count == 3)
        #expect(!ws.sent.contains(GeminiLiveProtocol.activityEndMessage))

        hold.releaseNext()
        await ws.waitForSends(5)
        ws.enqueue(Frame.final("ок"))
        ws.enqueue(Frame.generationComplete)
        #expect(try await finished.value == "ок")

        #expect(ws.sent == [
            GeminiLiveProtocol.setupMessage(mode: .smart),
            GeminiLiveProtocol.activityStartMessage,
            GeminiLiveProtocol.audioMessage(pcm16: GeminiLiveProtocol.pcm16(first)),
            GeminiLiveProtocol.audioMessage(pcm16: GeminiLiveProtocol.pcm16(second)),
            GeminiLiveProtocol.activityEndMessage,
        ])
    }

    @Test func orphanedDrainCannotTouchTheNextTake() async throws {
        let ws = FakeWebSocket()
        let hold = SendHold()
        ws.audioHold = hold
        let transcriber = makeTranscriber(transport: ws)

        let dropped = [Float](repeating: 0.1, count: 1_600)
        let fresh = [Float](repeating: 0.2, count: 1_600)

        await transcriber.startStream()
        transcriber.feed(dropped)
        await hold.waitForEntries(1) // an audio frame of the doomed take is in flight
        ws.audioHold = nil // only that one frame stays parked

        await transcriber.cancelStream() // Esc
        await transcriber.startStream() // and straight into the next one, new socket
        transcriber.feed(fresh)
        hold.releaseNext() // the orphan wakes up on a socket that no longer exists
        await settle()

        // Queued up front: a poisoned take throws before `activityEnd`, and waiting for a
        // frame that never comes would hang instead of failing.
        ws.enqueue(Frame.final("новый"))
        ws.enqueue(Frame.generationComplete)

        // The orphan must neither poison this take with its send failure nor spend its audio.
        #expect(try await transcriber.finishStream() == "новый")
        #expect(ws.sentOn(connection: 2) == [
            GeminiLiveProtocol.setupMessage(mode: .smart),
            GeminiLiveProtocol.activityStartMessage,
            GeminiLiveProtocol.audioMessage(pcm16: GeminiLiveProtocol.pcm16(fresh)),
            GeminiLiveProtocol.activityEndMessage,
        ])
    }

    @Test func sessionSurvivesBetweenTakes() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        transcriber.feed([Float](repeating: 0.1, count: 1_600))
        async let first = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 3, finals: ["первый"])
        #expect(try await first == "первый")

        await transcriber.startStream()
        transcriber.feed([Float](repeating: 0.1, count: 1_600))
        async let second = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 6, finals: ["второй"])
        #expect(try await second == "второй")

        #expect(ws.connectCount == 1)
        #expect(ws.setupFrames.count == 1)
        #expect(ws.activityStarts == 2)
        #expect(ws.closeCount == 0)
    }

    @Test func stragglingFinalBetweenTakesNeverLeaksIntoTheNextOne() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        async let first = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 2, finals: ["первый"])
        #expect(try await first == "первый")

        let handled = ws.receiveCount
        ws.enqueue(Frame.final("мусор"))
        await ws.waitForReceives(handled + 1) // the loop asked for the next frame => this one is done

        await transcriber.startStream()
        async let second = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 4, finals: ["второй"])
        #expect(try await second == "второй")
        #expect(ws.connectCount == 1) // the stray frame did not disturb the session
    }

    @Test func cancelInsideConnectLeavesNoOrphanSocket() async throws {
        let ws = FakeWebSocket()
        let hold = SendHold()
        ws.connectHold = hold
        let transcriber = makeTranscriber(transport: ws)

        let started = Task { await transcriber.startStream() }
        await hold.waitForEntries(1) // parked mid handshake
        await transcriber.cancelStream() // Esc while the socket is still coming up
        ws.connectHold = nil
        hold.releaseNext() // the handshake finishes with nobody to own it
        await started.value
        await settle()

        #expect(ws.closeCount == 1) // the orphan socket was closed, not left running
        #expect(ws.activityStarts == 0) // and never announced speech

        await transcriber.startStream()
        let beforeEnd = ws.sent.count
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: beforeEnd,
                                     final: "после отмены") == "после отмены")
        #expect(ws.activityStarts == 1)
        #expect(ws.connectCount == 2)
    }

    @Test func keyPressDuringWarmupJoinsTheSameConnection() async throws {
        let ws = FakeWebSocket()
        ws.autoSetupComplete = false
        let transcriber = makeTranscriber(transport: ws)

        // Warmup fires when recording starts, the key press lands a moment later: the second
        // caller must join the handshake in flight, not tear it down and start over.
        let warm = Task { await transcriber.warmup() }
        await ws.waitForSends(1) // setup is out, setupComplete is not back
        let started = Task { await transcriber.startStream() }
        await settle()
        ws.enqueue(Frame.setupComplete)
        await warm.value
        await started.value

        #expect(ws.connectCount == 1)
        #expect(ws.setupFrames.count == 1)
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "готово") == "готово")
    }

    @Test func shutdownClosesTheSocketAndTheNextTakeReconnects() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        _ = try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "первый")

        // Settings changed the engine: the owner drops the transcriber and the socket with it.
        await transcriber.shutdown()
        #expect(ws.closeCount == 1)
        await transcriber.waitForReceiveLoop() // the loop is gone, not parked on a dead socket

        await transcriber.startStream()
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: 4, final: "второй") == "второй")
        #expect(ws.connectCount == 2)
    }

    @Test func goAwayDuringATakeReconnectsAfterItNotInsideIt() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        ws.enqueue(#"{"goAway": {"timeLeft": "5s"}}"#)
        await ws.waitForReceives(3) // the warning is handled, the take carries on

        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "успел") == "успел")
        #expect(ws.closeCount == 1) // dropped between takes, not in the middle of one

        await transcriber.startStream()
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: 4, final: "на новом") == "на новом")
        #expect(ws.connectCount == 2)
    }

    @Test func reconnectsAfterTheServerClosesBetweenTakes() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        async let first = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 2, finals: ["первый"])
        #expect(try await first == "первый")

        ws.serverClose(code: 1_000, reason: "idle")
        await transcriber.waitForReceiveLoop()

        await transcriber.startStream()
        async let second = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 5, finals: ["второй"])
        #expect(try await second == "второй")

        #expect(ws.connectCount == 2)
        #expect(ws.setupFrames.count == 2)
    }

    @Test func badKeyClosesWith1007AndSurfacesAsInvalidApiKey() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        ws.serverClose(code: 1_007, reason: "API key not valid. Please pass a valid API key.")
        await transcriber.waitForReceiveLoop()

        transcriber.feed([Float](repeating: 0.1, count: 3_200)) // must not trap on a dead socket
        await #expect(throws: GeminiLiveError.invalidApiKey) {
            try await transcriber.finishStream()
        }
    }

    @Test func closeRightAfterSetupSurfacesTheRealCauseNotTheTimeout() async throws {
        let ws = FakeWebSocket()
        ws.autoSetupComplete = false
        ws.closeAfterSetup = (1_007, "API key not valid. Please pass a valid API key.")
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        // Only fires if the close failed to surface on its own. Then the take ends on
        // .setupTimeout instead of the real cause, which is exactly the defect.
        let watchdog = Task {
            for _ in 0..<500 {
                if Task.isCancelled { return }
                await Task.yield()
            }
            clock.advance(by: .seconds(10))
        }
        defer { watchdog.cancel() }

        await transcriber.startStream()
        await #expect(throws: GeminiLiveError.invalidApiKey) {
            try await transcriber.finishStream()
        }
    }

    @Test func missingSetupCompleteTimesOut() async throws {
        let ws = FakeWebSocket()
        ws.autoSetupComplete = false
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        let started = Task { await transcriber.startStream() }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(10))
        await started.value

        await #expect(throws: GeminiLiveError.setupTimeout) {
            try await transcriber.finishStream()
        }
    }

    @Test func missingGenerationCompleteTimesOut() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.startStream()
        let text = Task { try await transcriber.finishStream() }
        // By deadline, not by count: setup and keepalive timers are in flight too.
        await waitUntil { clock.hasSleep(after: .seconds(20)) }
        ws.enqueue(Frame.final("без завершения"))
        clock.advance(by: .seconds(20))

        await #expect(throws: GeminiLiveError.finalTimeout) { _ = try await text.value }
    }

    @Test func cancelDropsTheSocketAndTheNextTakeStartsClean() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        transcriber.feed([Float](repeating: 0.1, count: 1_600))
        await ws.waitForSends(3)
        ws.enqueue(Frame.final("отменённый"))
        await transcriber.cancelStream()
        #expect(ws.closeCount == 1)

        let sentBefore = ws.sent.count
        await transcriber.startStream()
        async let text = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: sentBefore + 2, finals: ["чистый"])

        #expect(try await text == "чистый")
        #expect(ws.connectCount == 2)
    }

    @Test func unaryTranscribeRunsTheWholeTake() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        async let text = transcriber.transcribe([Float](repeating: 0.1, count: 3_200))
        await answerTake(ws, sendsBeforeEnd: 4, finals: ["готово"])

        #expect(try await text == "готово")
        #expect(ws.setupFrames.count == 1)
        #expect(ws.activityStarts == 1)
        #expect(ws.audioPayloadSizes == [3_200, 3_200])
        #expect(ws.activityEnds == 1)
    }

    @Test func emptyInputNeverTouchesTheSocket() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        #expect(try await transcriber.transcribe([]) == "")
        #expect(ws.connectCount == 0)
        #expect(ws.sent.isEmpty)
    }

    @Test func finalAndCompletionInOneFrameEndTheTake() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.startStream()
        async let text = transcriber.finishStream()
        await ws.waitForSends(3)
        // Both halves in a single frame: the take must end without touching the clock.
        ws.enqueue(#"{"serverContent": {"inputTranscription": {"text": "x"}, "generationComplete": true}}"#)

        #expect(try await text == "x")
    }

    @Test func keepalivePingsAnIdleSession() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.warmup() // the socket is up and nobody is dictating
        await waitUntil { clock.hasSleep(after: .seconds(30)) }
        clock.advance(by: .seconds(30))
        await waitUntil { ws.pingCount >= 1 }

        #expect(ws.pingCount == 1)
        #expect(ws.connectCount == 1)
        #expect(ws.closeCount == 0)
    }

    @Test func keepaliveStaysQuietWhileATakeIsRunning() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.startStream()
        await waitUntil { clock.hasSleep(after: .seconds(30)) }
        clock.advance(by: .seconds(30))
        // The loop parked again, so the tick was handled: audio frames are the keepalive
        // during a take and a ping has no business on that wire.
        await waitUntil { clock.hasSleep(after: .seconds(30)) }
        #expect(ws.pingCount == 0)

        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "без пинга") == "без пинга")
    }

    @Test func aFailedKeepalivePingDropsTheSessionAndTheNextTakeReconnects() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        ws.pingFailure = WebSocketCloseError(code: 1_006, reason: "connection abort")
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.warmup()
        await waitUntil { clock.hasSleep(after: .seconds(30)) }
        clock.advance(by: .seconds(30))
        await waitUntil { ws.closeCount >= 1 } // the corpse is hung up here, not on the next key press
        #expect(ws.pingCount == 1)

        ws.pingFailure = nil
        await transcriber.startStream()
        let beforeEnd = ws.sent.count
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: beforeEnd,
                                     final: "на новом") == "на новом")
        #expect(ws.connectCount == 2)
    }

    @Test func keepaliveStopsWithTheSession() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(transport: ws, clock: clock)

        await transcriber.warmup()
        await waitUntil { clock.hasSleep(after: .seconds(30)) }
        await transcriber.shutdown()
        #expect(!clock.hasSleep(after: .seconds(30))) // the timer is off the clock, not leaked
        clock.advance(by: .seconds(30))
        await settle()

        #expect(ws.pingCount == 0) // nothing pings a socket the app has already hung up
    }

    @Test func aSessionIdleTooLongIsReplacedBeforeSpeechIsAnnounced() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        // Keepalive parked far away: this is about the socket going stale on its own.
        let transcriber = makeTranscriber(
            transport: ws, clock: clock, keepaliveInterval: .seconds(600), staleAfter: .seconds(45))

        await transcriber.startStream()
        _ = try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "первый")

        clock.advance(by: .seconds(60)) // four and a half minutes between takes, in short
        await transcriber.startStream()

        #expect(ws.connectCount == 2)
        // The order is the point: a fresh socket, then speech — never `activityStart` into a corpse.
        #expect(ws.sentOn(connection: 2) == [
            GeminiLiveProtocol.setupMessage(mode: .smart),
            GeminiLiveProtocol.activityStartMessage,
        ])
        let beforeEnd = ws.sent.count
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: beforeEnd,
                                     final: "второй") == "второй")
    }

    @Test func aSessionIdleWithinTheLimitIsReused() async throws {
        let ws = FakeWebSocket()
        let clock = ManualClock()
        let transcriber = makeTranscriber(
            transport: ws, clock: clock, keepaliveInterval: .seconds(600), staleAfter: .seconds(45))

        await transcriber.startStream()
        _ = try await finishTake(transcriber, ws, sendsBeforeEnd: 2, final: "первый")

        clock.advance(by: .seconds(30)) // still inside the window, the handshake is worth keeping
        await transcriber.startStream()
        let beforeEnd = ws.sent.count
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: beforeEnd,
                                     final: "второй") == "второй")

        #expect(ws.connectCount == 1)
        #expect(ws.activityStarts == 2)
    }

    @Test func aFailedSendMarksTheSessionDeadSoTheNextTakeReconnects() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        // The socket is gone and only the writing side knows: the receive loop stays parked,
        // which is exactly how a stale TCP behaves before its idle timeout fires.
        ws.sendFailure = WebSocketCloseError(code: 1_006, reason: "operation timed out")
        transcriber.feed([Float](repeating: 0.1, count: 1_600))
        await #expect(throws: GeminiLiveError.serverClosed(code: 1_006, reason: "operation timed out")) {
            try await transcriber.finishStream()
        }
        ws.sendFailure = nil

        await transcriber.startStream()
        let beforeEnd = ws.sent.count
        #expect(try await finishTake(transcriber, ws, sendsBeforeEnd: beforeEnd,
                                     final: "на новом") == "на новом")
        #expect(ws.connectCount == 2)
    }

    @Test func severalFinalsInOneTakeAreJoined() async throws {
        let ws = FakeWebSocket()
        let transcriber = makeTranscriber(transport: ws)

        await transcriber.startStream()
        async let text = transcriber.finishStream()
        await answerTake(ws, sendsBeforeEnd: 2, finals: ["Первая фраза.", "Вторая фраза."])

        #expect(try await text == "Первая фраза. Вторая фраза.")
    }
}
