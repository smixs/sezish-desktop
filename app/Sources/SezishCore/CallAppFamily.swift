import Foundation

/// Bundle-id family of a call app: a helper process belongs to the app it
/// serves (`com.google.Chrome.helper.Renderer` → `com.google.Chrome`), and that
/// family is the granularity a process tap can be scoped to — the call is then
/// recorded without the music playing in the next tab.
///
/// Matching is case-insensitive, like `MeetingDetectionPolicy`: helper ids flip
/// case against their main app.
public enum CallAppFamily {
    // RED: surface only, the behaviour lands in the next commit.
    public static func of(_ bundleID: String) -> String { "" }

    public static func belongs(_ bundleID: String, to family: String) -> Bool { false }
}

/// Who is on the call. Decided once, when a meeting starts: the system stem is
/// scoped to `family` instead of the whole Mac, and later stages name the
/// meeting after this app.
public struct MeetingCallApp: Equatable, Sendable {
    public let bundleID: String
    /// The live process behind `bundleID`; nil when only the detector could name
    /// the app and no current process matched it.
    public let pid: pid_t?
    public let family: String

    public init(bundleID: String, pid: pid_t?, family: String) {
        self.bundleID = bundleID
        self.pid = pid
        self.family = family
    }

    /// Where the system stem comes from, once the app is known.
    public var scope: MeetingAudioScope { .family(family) }
}

/// Where the system stem of a meeting comes from.
public enum MeetingAudioScope: Equatable, Sendable {
    /// No call app was named: everything that plays is recorded, as before.
    case all
    /// Only the live processes of one app family (`CallAppFamily`).
    case family(String)
}

/// What started a meeting recording.
public enum MeetingStartSource: Equatable, Sendable {
    case manual
    /// The detector saw a call — with the bundle id it could name, if any.
    case auto(bundleID: String?)
}

/// Decides whose audio a meeting records, from inputs only (the caller supplies
/// CoreAudio's mic holders and the detector's answer).
public enum MeetingCallAppResolver {
    /// A mic holder as CoreAudio reports it.
    public struct Holder: Equatable, Sendable {
        public let bundleID: String
        public let pid: pid_t

        public init(bundleID: String, pid: pid_t) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    // RED: surface only, the behaviour lands in the next commit.
    public static func resolve(
        source: MeetingStartSource, holders: [Holder], policy: MeetingDetectionPolicy
    ) -> MeetingCallApp? { nil }
}
