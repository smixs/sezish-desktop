import Foundation

/// How the server post-processes the transcript. `SMART` cleans the text up (punctuation,
/// profanity, disfluencies), `VERBATIM` returns what was said.
public enum GeminiTranscriptionMode: String, Sendable, CaseIterable {
    case smart = "SMART"
    case verbatim = "VERBATIM"
}

/// One frame from the server. Everything the session ever sent during the spike is here;
/// anything else stays `.unknown` and is dropped by the caller, never an error.
public enum ServerEvent: Equatable, Sendable {
    case setupComplete
    /// The server is about to drop this session. Reconnect between takes, not during one.
    case goAway
    case interim(String)
    case final(String)
    case generationComplete
    case empty
    case unknown(String)
}

/// Pure wire format of `gemini-3.5-transcribe-live`: no IO, no state.
///
/// Outgoing frames are string literals rather than serialized dictionaries — they are byte
/// for byte the frames the spike recorded, the only variable parts (mode, base64 audio) use
/// alphabets that need no JSON escaping, and `audioMessage` runs ten times a second.
public enum GeminiLiveProtocol {
    public static let model = "models/gemini-3.5-transcribe-live"
    public static let audioMimeType = "audio/pcm;rate=16000"

    public static func setupMessage(mode: GeminiTranscriptionMode) -> String {
        """
        {"setup":{"model":"\(model)",\
        "generationConfig":{"responseModalities":["TEXT"]},\
        "realtimeInputConfig":{"automaticActivityDetection":{"disabled":true}},\
        "inputAudioTranscription":{"languageCodes":[],"mode":"\(mode.rawValue)"}}}
        """
    }

    /// Push-to-talk boundaries: automatic activity detection is off, so speech start and end
    /// are the client's business.
    public static let activityStartMessage = #"{"realtimeInput":{"activityStart":{}}}"#
    public static let activityEndMessage = #"{"realtimeInput":{"activityEnd":{}}}"#

    public static func audioMessage(pcm16: Data) -> String {
        """
        {"realtimeInput":{"audio":{"data":"\(pcm16.base64EncodedString())",\
        "mimeType":"\(audioMimeType)"}}}
        """
    }

    /// Float samples to 16-bit little-endian PCM. Scaling by 32768 keeps the negative rail
    /// exact (-1 → -32768) and clamping trims the positive one (1 → 32767).
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            let value = Int16(clamping: Int((clamped * 32_768).rounded()))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A frame can carry more than one event: the spike always got the final and the
    /// completion separately, but nothing in the protocol promises that, and losing the
    /// completion would leave the take hanging until `finalTimeout`.
    public static func parse(_ text: String) -> [ServerEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let frame = object as? [String: Any] else {
            return [.unknown(text)]
        }
        if frame["setupComplete"] != nil { return [.setupComplete] }
        if frame["goAway"] != nil { return [.goAway] }
        guard let content = frame["serverContent"] as? [String: Any] else { return [.unknown(text)] }
        if content.isEmpty { return [.empty] }

        var events: [ServerEvent] = []
        if let text = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            events.append(.interim(text))
        }
        if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String {
            events.append(.final(text))
        }
        if content["generationComplete"] as? Bool == true { events.append(.generationComplete) }
        return events.isEmpty ? [.unknown(text)] : events
    }
}
