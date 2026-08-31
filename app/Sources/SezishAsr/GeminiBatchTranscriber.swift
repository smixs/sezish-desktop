import Foundation
import os

public enum GeminiBatchError: LocalizedError, Equatable {
    case badResponse(code: Int, body: String)
    case blocked(String)
    case emptyTranscript
    case audioTooLong(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code, let body):
            return "Gemini ответил \(code): \(body)"
        case .blocked(let reason):
            return "Gemini не отдал текст (\(reason))."
        case .emptyTranscript:
            return "Gemini вернул пустой текст."
        case .audioTooLong(let seconds):
            return "Запись слишком длинная для Gemini: \(seconds) с."
        }
    }
}

/// Unary transcription over `generateContent` — the path a finished recording takes.
///
/// The Live socket is built for speech arriving in realtime: a whole file poured into it
/// faster than it was spoken gets the session killed with «Resource has been exhausted»
/// (measured on a 308 s take). The same audio through the batch endpoint comes back whole.
/// Latency does not matter here: nobody is holding a key down, the take is already on disk.
struct GeminiBatchTranscriber: Sendable {
    /// Pinned, not `-latest`: an alias moving under a shipped app changes recognition
    /// behaviour without a release. Verified against this endpoint on 2026-08-27.
    static let model = "gemini-2.5-flash"
    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    /// The request as a whole may not exceed 20 MB, prompt and JSON included. AAC at 32 kbps
    /// hits that after an hour of speech, so the guard is a tripwire, not a limit anyone meets.
    private static let maxPayloadBytes = 18 * 1_024 * 1_024

    private let apiKey: String
    private let mode: GeminiTranscriptionMode
    private let transport: any HTTPTransport
    private let logger = Logger(subsystem: "com.smixs.sezish", category: "gemini")

    init(apiKey: String, mode: GeminiTranscriptionMode, transport: any HTTPTransport) {
        self.apiKey = apiKey
        self.mode = mode
        self.transport = transport
    }

    func transcribe(_ samples16k: [Float]) async throws -> String {
        let seconds = samples16k.count / 16_000
        // 32 kbps AAC instead of raw PCM: 8× less to upload, and the same encoder the cloud
        // engine has been shipping. Gemini takes ADTS as `audio/aac`.
        let audio = try CloudTranscriber.aacData(samples16k).base64EncodedString()
        guard audio.utf8.count <= Self.maxPayloadBytes else {
            throw GeminiBatchError.audioTooLong(seconds: seconds)
        }

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key travels in a header, not in the URL: URLSession error text and system logs
        // quote URLs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try Self.body(prompt: Self.prompt(for: mode), audio: audio)
        request.timeoutInterval = CloudTranscriber.timeout(forSampleCount: samples16k.count)

        logger.notice("batch transcribe \(seconds) s, \(audio.utf8.count / 1_024) KB")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GeminiBatchError.badResponse(
                code: response.statusCode,
                body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let text = try Self.transcript(from: data)
        logger.notice("batch transcript \(text.count) chars")
        return text
    }

    // MARK: - Wire format

    /// SMART and VERBATIM are Live-side server settings with no batch equivalent, so the
    /// difference has to be spelled out to the model instead.
    static func prompt(for mode: GeminiTranscriptionMode) -> String {
        let common = "Keep the speaker's own language. "
            + "Return only the transcript text: no commentary, no quotes, no markdown."
        switch mode {
        case .smart:
            return "Transcribe the speech in this recording. Add punctuation and capitalization, "
                + "drop filler words, stutters and false starts. " + common
        case .verbatim:
            return "Transcribe the speech in this recording word for word. "
                + "Keep filler words, stutters and repetitions exactly as spoken. " + common
        }
    }

    static func body(prompt: String, audio: String) throws -> Data {
        let payload: [String: Any] = [
            "contents": [["parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "audio/aac", "data": audio]],
            ]]],
            // Nothing to reason about in a transcript, and thinking is latency the retry
            // pays for nothing.
            "generationConfig": ["temperature": 0, "thinkingConfig": ["thinkingBudget": 0]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// The transcript is the text of the first candidate. An answer without one carries its
    /// reason (safety, recitation, token budget) and is an error: an empty string here would
    /// be stored as a successful empty take.
    static func transcript(from data: Data) throws -> String {
        struct Reply: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            let candidates: [Candidate]?
        }

        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let candidate = reply.candidates?.first else {
            throw GeminiBatchError.blocked("no candidates")
        }
        let text = (candidate.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            guard let reason = candidate.finishReason, reason != "STOP" else {
                throw GeminiBatchError.emptyTranscript
            }
            throw GeminiBatchError.blocked(reason)
        }
        return text
    }
}
