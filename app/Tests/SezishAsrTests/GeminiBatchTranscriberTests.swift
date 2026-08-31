import Foundation
import Testing

@testable import SezishAsr

@Suite("Gemini batch route")
struct GeminiBatchTranscriberTests {
    private func makeTranscriber(
        transport: FakeWebSocket, http: FakeHTTP, mode: GeminiTranscriptionMode = .smart
    ) -> GeminiLiveTranscriber {
        GeminiLiveTranscriber(
            apiKey: "test-key", mode: mode, transport: transport, http: http,
            clock: ContinuousClock(), setupTimeout: .seconds(10), finalTimeout: .seconds(20))
    }

    /// Just past the threshold: the shortest take that must not go near the socket.
    private var longTake: [Float] {
        (0...GeminiLiveTranscriber.batchAfterSamples)
            .map { Float(0.3 * sin(2.0 * Double.pi * 220.0 * Double($0) / 16_000.0)) }
    }

    // MARK: - Which route

    @Test func aRetryLongerThanThirtySecondsGoesToTheBatchEndpoint() async throws {
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        let transcriber = makeTranscriber(transport: ws, http: http)

        let text = try await transcriber.transcribe(longTake)

        #expect(text == "перегнали")
        #expect(ws.connectCount == 0) // the socket was never touched
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        // The key travels in the header, never in the URL.
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.query == nil)
        #expect(http.mimeType() == "audio/aac")
        #expect(http.audioBytes() > 0)
    }

    @Test func aRetryAtThirtySecondsStaysOnTheSocket() async throws {
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        let transcriber = makeTranscriber(transport: ws, http: http)
        let samples = [Float](repeating: 0.2, count: GeminiLiveTranscriber.batchAfterSamples)

        let take = Task { try await transcriber.transcribe(samples) }
        await ws.waitForSends(1) // the setup frame: this take went to the Live API
        #expect(http.requests.isEmpty)

        await transcriber.cancelStream() // nothing here waits for a whole 30 s take to drain
        _ = try? await take.value

        #expect(ws.connectCount == 1)
        #expect(http.requests.isEmpty)
    }

    @Test func anEmptyBufferIsNeitherRoute() async throws {
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        let transcriber = makeTranscriber(transport: ws, http: http)

        #expect(try await transcriber.transcribe([]) == "")
        #expect(ws.connectCount == 0)
        #expect(http.requests.isEmpty)
    }

    // MARK: - Failures

    @Test func aServerErrorSurfacesInsteadOfFallingBackToTheSocket() async throws {
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        http.status = 429
        http.body = Data(#"{"error":{"message":"quota"}}"#.utf8)
        let transcriber = makeTranscriber(transport: ws, http: http)
        await #expect(throws: GeminiBatchError.self) { try await transcriber.transcribe(longTake) }
        #expect(ws.connectCount == 0)
    }

    @Test func aRequestThatNeverLeftIsNotSwallowed() async throws {
        struct Offline: Error {}
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        http.failure = Offline()
        let transcriber = makeTranscriber(transport: ws, http: http)
        await #expect(throws: Offline.self) { try await transcriber.transcribe(longTake) }
        #expect(ws.connectCount == 0)
    }

    // MARK: - Prompt

    @Test func smartAndVerbatimAskForDifferentTranscripts() {
        let smart = GeminiBatchTranscriber.prompt(for: .smart)
        let verbatim = GeminiBatchTranscriber.prompt(for: .verbatim)
        #expect(smart.contains("drop filler words"))
        #expect(verbatim.contains("word for word"))
        #expect(verbatim.contains("Keep filler words"))
        // Both must come back as bare text: the transcript is pasted at the caret.
        #expect(smart.contains("no markdown"))
        #expect(verbatim.contains("no markdown"))
    }

    @Test(arguments: [GeminiTranscriptionMode.smart, .verbatim])
    func theModeReachesTheRequest(mode: GeminiTranscriptionMode) async throws {
        let ws = FakeWebSocket()
        let http = FakeHTTP()
        let transcriber = makeTranscriber(transport: ws, http: http, mode: mode)
        _ = try await transcriber.transcribe(longTake)

        #expect(http.prompt() == GeminiBatchTranscriber.prompt(for: mode))
    }

    // MARK: - Reply parsing

    @Test func aReplyIsTheJoinedTextOfTheFirstCandidate() throws {
        let data = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"Привет, "},{"text":"друзья."}]},
        "finishReason":"STOP"}]}
        """#.utf8)
        #expect(try GeminiBatchTranscriber.transcript(from: data) == "Привет, друзья.")
    }

    /// An empty answer is a failure, never an empty transcript: stored as text it would look
    /// like a take that simply had no words in it.
    @Test func anEmptyAnswerThrows() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":"  "}]},"finishReason":"STOP"}]}"#.utf8)
        #expect(throws: GeminiBatchError.emptyTranscript) {
            try GeminiBatchTranscriber.transcript(from: data)
        }
    }

    @Test func aBlockedAnswerCarriesItsReason() throws {
        let data = Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8)
        #expect(throws: GeminiBatchError.blocked("SAFETY")) {
            try GeminiBatchTranscriber.transcript(from: data)
        }
        #expect(throws: GeminiBatchError.blocked("no candidates")) {
            try GeminiBatchTranscriber.transcript(from: Data(#"{"candidates":[]}"#.utf8))
        }
    }
}
