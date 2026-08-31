import Foundation

/// One finished dictation: the recognized text plus a pointer to its stored audio.
public struct DictationRecord: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let audioURL: URL?
    /// Which engine produced `text` — "cloud" or "local/<model>". Diagnostics only, never shown:
    /// without it a silent fallback between the two is invisible in the output. Optional
    /// so an `index.json` written before this field still decodes (old entries → nil).
    public let engine: String?
    /// Why `text` is empty: the transcriber's message, or "empty" when it returned nothing.
    /// nil on successful takes and on records written before this field existed.
    public let error: String?

    /// A take whose audio is on disk but whose transcript is missing. The single place
    /// where "failed" is defined: eviction, the menu and the retry all ask this.
    public var needsTranscript: Bool { text.isEmpty }

    public init(
        id: UUID = UUID(), date: Date = Date(), text: String, audioURL: URL? = nil,
        engine: String? = nil, error: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.audioURL = audioURL
        self.engine = engine
        self.error = error
    }
}
