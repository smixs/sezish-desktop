import Foundation

/// How dictation transcribes. Cloud is the product default (works out of the box,
/// no 215 MB download); local is the offline opt-in; gemini is the user's own
/// Google key, billed to them.
public enum TranscriptionMode: String, Sendable, CaseIterable {
    case cloud
    case local
    case gemini
}

/// UI language. Absent in settings means "follow the system".
/// The order is the order of the picker: the two home-market languages first.
/// Not every client speaks all of them — the Mac app still ships ru/uz only and
/// reads everything else in Russian (see `AppState.init`).
public enum AppLanguage: String, Sendable, CaseIterable {
    case uz
    case ru
    case kk
    case ky
    case en

    /// The language's own name: a language list is read by the person who is about
    /// to switch to that language, so no entry may be written in another one.
    public var nativeName: String {
        switch self {
        case .uz: "Oʻzbekcha"
        case .ru: "Русский"
        case .kk: "Қазақша"
        case .ky: "Кыргызча"
        case .en: "English"
        }
    }

    /// The system language, when we speak it. Anything outside the five falls back
    /// to English: it is the one language a foreign visitor is likely to read, and
    /// Russian in a phone set to, say, German would be a guess about the person.
    public static func systemDefault() -> AppLanguage {
        guard let preferred = Locale.preferredLanguages.first else { return .en }
        // The raw preference is a full tag ("uz-Latn-UZ", "en-GB") — take the
        // language subtag rather than matching prefixes on the whole string.
        let code = Locale(identifier: preferred).language.languageCode?.identifier
        return AppLanguage(rawValue: code ?? "") ?? .en
    }
}

public struct CloudCredentials: Sendable, Equatable {
    public let endpoint: URL
    public let apiKey: String

    public init(endpoint: URL, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }
}

/// Thin, testable wrapper over UserDefaults (suite is injected for isolation in tests).
/// `launchAtLogin` is deliberately absent: it is read live from `SMAppService`, never cached.
public final class AppSettings {
    private let defaults: UserDefaults
    /// Credentials baked into the bundle at build time (Info.plist); defaults-set
    /// credentials override them, so a dev/tester can point at another backend.
    private let bakedCloud: CloudCredentials?

    public init(defaults: UserDefaults, bakedCloud: CloudCredentials? = nil) {
        self.defaults = defaults
        self.bakedCloud = bakedCloud
    }

    public var autoRecordMeetings: Bool {
        get { defaults.bool(forKey: Keys.autoRecordMeetings) }
        set { defaults.set(newValue, forKey: Keys.autoRecordMeetings) }
    }

    /// Stored as the plain absolute string (not a security-scoped bookmark): the app is
    /// non-sandboxed, and a literal path round-trips without symlink resolution surprises.
    public var notesFolder: URL? {
        get {
            guard let string = defaults.string(forKey: Keys.notesFolder) else { return nil }
            return URL(string: string)
        }
        set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: Keys.notesFolder)
            } else {
                defaults.removeObject(forKey: Keys.notesFolder)
            }
        }
    }

    /// The push-to-talk shortcut, persisted as JSON. `nil` until the user records one, at which
    /// point the app layer falls back to `Shortcut.defaultShortcut`. Exposing the decoded
    /// `Shortcut` (rather than raw `Data`) keeps all encoding in Core, so the app never touches
    /// JSON. A corrupt or stale payload decodes to `nil` and degrades to the default.
    public var shortcut: Shortcut? {
        get {
            guard let data = defaults.data(forKey: Keys.shortcut) else { return nil }
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.shortcut)
            } else {
                defaults.removeObject(forKey: Keys.shortcut)
            }
        }
    }

    /// Cloud endpoint override via `defaults write com.smixs.sezish cloudEndpoint <url>` —
    /// beats the baked credentials when set together with `cloudApiKey`.
    public var cloudEndpoint: URL? {
        guard let string = defaults.string(forKey: Keys.cloudEndpoint), !string.isEmpty
        else { return nil }
        return URL(string: string)
    }

    public var cloudApiKey: String? {
        defaults.string(forKey: Keys.cloudApiKey)
    }

    /// Credentials dictation would use in cloud mode: defaults override first, then baked.
    public var cloudCredentials: CloudCredentials? {
        if let endpoint = cloudEndpoint, let apiKey = cloudApiKey, !apiKey.isEmpty {
            return CloudCredentials(endpoint: endpoint, apiKey: apiKey)
        }
        return bakedCloud
    }

    /// Which on-device model dictation and meetings run on. Stored raw so a value
    /// from a newer build degrades to the model every install has.
    public var localModel: AsrModel {
        get {
            AsrModel(rawValue: defaults.string(forKey: Keys.localModel) ?? "")
                ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.localModel) }
    }

    /// Skip opening the Settings window on a manual launch; the menu bar item
    /// stays, and reopening the app or ⌘, still brings the window up.
    public var launchHidden: Bool {
        get { defaults.bool(forKey: Keys.launchHidden) }
        set { defaults.set(newValue, forKey: Keys.launchHidden) }
    }

    /// The user's mode choice. Stored raw so a stale value degrades to the default.
    public var transcriptionMode: TranscriptionMode {
        get {
            TranscriptionMode(rawValue: defaults.string(forKey: Keys.transcriptionMode) ?? "")
                ?? .cloud
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.transcriptionMode) }
    }

    /// The mode dictation actually runs in: every mode needs its own credential,
    /// so a missing one degrades to the next mode that works.
    public var effectiveTranscriptionMode: TranscriptionMode {
        let fallback: TranscriptionMode = cloudCredentials == nil ? .local : .cloud
        switch transcriptionMode {
        case .local: return .local
        case .cloud: return fallback
        case .gemini: return geminiApiKey == nil ? fallback : .gemini
        }
    }

    /// The user's own Google AI Studio key for `.gemini`. Trimmed on write and read
    /// as absent when blank: a pasted key carries the clipboard's whitespace, and an
    /// empty string must mean "no key", not "a key that is empty".
    public var geminiApiKey: String? {
        get {
            let trimmed = defaults.string(forKey: Keys.geminiApiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Keys.geminiApiKey)
            } else {
                defaults.removeObject(forKey: Keys.geminiApiKey)
            }
        }
    }

    /// Gemini cleans up the transcript (filler words, profanity, punctuation).
    /// Default on: that is why one would pick this engine over the others.
    public var geminiSmartMode: Bool {
        get { defaults.object(forKey: Keys.geminiSmartMode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.geminiSmartMode) }
    }

    /// Hold (push-to-talk) vs toggle for the dictation hotkey. Stored raw; an absent or stale
    /// value degrades to `.hold` — which is the whole migration: existing users keep today's
    /// behavior without ever having had the key.
    public var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Keys.hotkeyMode) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode) }
    }

    /// Start-of-recording chimes (dictation and meeting). Default on.
    public var playSounds: Bool {
        get { defaults.object(forKey: Keys.playSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.playSounds) }
    }

    /// Meeting-detector escape hatch, no UI: bundle-id prefixes that never count
    /// as a call. `defaults write com.smixs.sezish extraDenyApps -array "com.foo.app"`.
    public var extraDenyApps: [String] {
        defaults.stringArray(forKey: Keys.extraDenyApps) ?? []
    }

    /// Hidden power-user hook, no UI: a shell command spawned with the path of each
    /// finished meeting's .md as its argument.
    /// `defaults write com.smixs.sezish meetingHook '<command>'`.
    /// An empty string reads as unset, so the hook can be silenced without deleting the key.
    public var meetingHook: String? {
        guard let command = defaults.string(forKey: Keys.meetingHook), !command.isEmpty
        else { return nil }
        return command
    }

    /// Which locally installed CLI writes the meeting summaries. Stored raw so a value
    /// from a newer build (or a typo in `defaults write`) degrades to the default.
    public var summaryEngine: SummaryEngineKind {
        get {
            SummaryEngineKind(rawValue: defaults.string(forKey: Keys.summaryEngine) ?? "")
                ?? .claude
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.summaryEngine) }
    }

    /// Meeting summaries. Default on: the feature is inert until an engine CLI is
    /// available and a notesFolder is set, so on-by-default costs nothing meanwhile
    /// and gives instant magic the moment both are in place — no switch to discover.
    public var summaryEnabled: Bool {
        get { defaults.object(forKey: Keys.summaryEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.summaryEnabled) }
    }

    /// Explicit UI language choice; `nil` follows the system.
    public var appLanguage: AppLanguage? {
        get { AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Keys.appLanguage)
            } else {
                defaults.removeObject(forKey: Keys.appLanguage)
            }
        }
    }

    private enum Keys {
        static let autoRecordMeetings = "autoRecordMeetings"
        static let notesFolder = "notesFolder"
        static let shortcut = "shortcut"
        static let hotkeyMode = "hotkeyMode"
        static let cloudEndpoint = "cloudEndpoint"
        static let cloudApiKey = "cloudApiKey"
        static let transcriptionMode = "transcriptionMode"
        static let geminiApiKey = "geminiApiKey"
        static let geminiSmartMode = "geminiSmartMode"
        static let localModel = "localModel"
        static let launchHidden = "launchHidden"
        static let appLanguage = "appLanguage"
        static let playSounds = "playSounds"
        static let extraDenyApps = "extraDenyApps"
        static let meetingHook = "meetingHook"
        static let summaryEngine = "summaryEngine"
        static let summaryEnabled = "summaryEnabled"
    }
}
