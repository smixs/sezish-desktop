import Foundation
import Testing

@testable import SezishAsr

/// OpenAI dictation: the finished take goes up as one WAV to
/// `/v1/audio/transcriptions` on the user's own key.
@Suite("OpenAI transcription")
struct OpenAITranscriberTests {
    private let take: [Float] = (0..<8_000).map { 0.2 * sin(2 * .pi * 220 * Float($0) / 16_000) }

    private func fakeHTTP(status: Int = 200, body: String = #"{"text":"Привет, как дела?"}"#) -> FakeHTTP {
        let http = FakeHTTP()
        http.status = status
        http.body = Data(body.utf8)
        return http
    }

    @Test func postsTheTakeAsAWavFileWithTheModelAndKey() async throws {
        let http = fakeHTTP()
        let transcriber = OpenAITranscriber(apiKey: "sk-test", model: "gpt-transcribe", transport: http)

        let text = try await transcriber.transcribe(take)

        #expect(text == "Привет, как дела?")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let type = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(body.contains("filename=\"take.wav\"\r\nContent-Type: audio/wav"))
        #expect(request.httpBody.map { $0.count > 16_000 } == true) // 0.5 s of 16-bit PCM is there
    }

    @Test func theMiniModelIsSentByName() async throws {
        let http = fakeHTTP()
        _ = try await OpenAITranscriber(apiKey: "k", model: "gpt-4o-mini-transcribe", transport: http)
            .transcribe(take)
        let body = String(decoding: http.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("gpt-4o-mini-transcribe"))
    }

    @Test func anErrorCarriesOpenAIsOwnMessage() async {
        let http = fakeHTTP(status: 401, body: #"{"error":{"message":"Incorrect API key provided."}}"#)
        let transcriber = OpenAITranscriber(apiKey: "bad", model: "gpt-transcribe", transport: http)
        await #expect(throws: OpenAIError.badResponse(code: 401, message: "Incorrect API key provided.")) {
            _ = try await transcriber.transcribe(take)
        }
    }

    @Test func theTextIsTrimmed() async throws {
        let http = fakeHTTP(body: #"{"text":"  да \n"}"#)
        let text = try await OpenAITranscriber(apiKey: "k", model: "gpt-transcribe", transport: http)
            .transcribe(take)
        #expect(text == "да")
    }
}
