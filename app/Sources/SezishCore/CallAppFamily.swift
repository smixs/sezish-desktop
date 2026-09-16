import Foundation

/// Bundle-id family of a call app: a helper process belongs to the app it
/// serves (`com.google.Chrome.helper.Renderer` → `com.google.Chrome`), and that
/// family is the granularity a process tap can be scoped to — the call is then
/// recorded without the music playing in the next tab.
///
/// Matching is case-insensitive, like `MeetingDetectionPolicy`: helper ids flip
/// case against their main app.
public enum CallAppFamily {
    private static let helperMarker = ".helper"

    /// `com.google.Chrome.helper.Renderer` → `com.google.Chrome`; an id with no
    /// `.helper` segment is its own family (`us.zoom.xos`). Lowercased, since
    /// that is how families are compared. A marker with nothing in front of it
    /// would leave nothing to match on, so such an id is kept whole.
    public static func of(_ bundleID: String) -> String {
        let id = bundleID.lowercased()
        guard let marker = id.range(of: helperMarker), marker.lowerBound != id.startIndex else {
            return id
        }
        return String(id[..<marker.lowerBound])
    }

    /// True when `bundleID` is that app itself or any helper under it.
    public static func belongs(_ bundleID: String, to family: String) -> Bool {
        bundleID.lowercased().hasPrefix(family.lowercased())
    }
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

    /// What the tap records for a start, whatever the resolver came back with.
    public static func forCallApp(_ callApp: MeetingCallApp?) -> MeetingAudioScope {
        callApp?.scope ?? .all
    }
}

/// What started a meeting recording.
public enum MeetingStartSource: Equatable, Sendable {
    case manual
    /// The detector saw a call — with the bundle id it could name, if any.
    case auto(bundleID: String?)

    /// Auto-started meetings are the only ones the detector may stop.
    public var isAuto: Bool {
        if case .auto = self { true } else { false }
    }
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

    /// The detector's answer is authoritative; the pid only names it for the
    /// user, so a holder that vanished costs the name and not the scope.
    public static func resolve(
        source: MeetingStartSource, holders: [Holder], policy: MeetingDetectionPolicy
    ) -> MeetingCallApp? {
        switch source {
        case .auto(let bundleID): return bundleID.map { auto(bundleID: $0, holders: holders) }
        case .manual: return manual(holders: holders, policy: policy)
        }
    }

    /// A helper id is a fine answer here: the tap is scoped to the family, and
    /// every helper of that app is inside it.
    private static func auto(bundleID: String, holders: [Holder]) -> MeetingCallApp {
        let family = CallAppFamily.of(bundleID)
        let pid = holders.first { CallAppFamily.belongs($0.bundleID, to: family) }?.pid
        return MeetingCallApp(bundleID: bundleID, pid: pid, family: family)
    }

    /// No detector answer, so the first mic holder the policy would record is
    /// the call app — the same judgement the detector itself makes.
    private static func manual(holders: [Holder], policy: MeetingDetectionPolicy) -> MeetingCallApp? {
        let chosen = holders.first { policy.classify($0.bundleID) == .record }
        return chosen.map {
            MeetingCallApp(bundleID: $0.bundleID, pid: $0.pid, family: CallAppFamily.of($0.bundleID))
        }
    }
}
