import Foundation
import os
import SezishCore

public enum OpenAIError: LocalizedError, Equatable {
    case badResponse(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code, let message): "OpenAI ответил \(code): \(message)"
        }
    }
}

/// Dictation over OpenAI's `/v1/audio/transcriptions` on the user's own key. The
/// finished take goes up once, as 16 kHz 16-bit WAV (ADTS AAC is not among the
/// formats the endpoint takes; a minute of speech is under 2 MB of 25).
public struct OpenAITranscriber: Transcriber {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private let apiKey: String
    private let model: String
    private let transport: any HTTPTransport
    private let logger = Logger(subsystem: "com.smixs.sezish", category: "openai")

    public init(apiKey: String, model: String, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func transcribe(_ samples16k: [Float]) async throws -> String {
        let boundary = "sezish-" + UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body(wav: WAVFile.data(samples16k), model: model, boundary: boundary)
        request.timeoutInterval = CloudTranscriber.timeout(forSampleCount: samples16k.count)

        logger.notice("transcribe \(samples16k.count / 16_000) s via \(model, privacy: .public)")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw OpenAIError.badResponse(code: response.statusCode, message: Self.message(in: data))
        }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func body(wav: Data, model: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// `{"error":{"message":…}}` when OpenAI explains itself, else the body's start.
    static func message(in data: Data) -> String {
        struct Failure: Decodable {
            struct Inner: Decodable { let message: String }
            let error: Inner
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) { return failure.error.message }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
