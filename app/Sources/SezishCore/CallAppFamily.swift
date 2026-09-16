import Foundation

/// Bundle-id family of a call app: a helper process belongs to the app it
/// serves (`com.google.Chrome.helper.Renderer` → `com.google.Chrome`), and that
/// family is the granularity a process tap can be scoped to — the call is then
/// recorded without the music playing in the next tab.
///
/// Matching is case-insensitive, like `MeetingDetectionPolicy`: helper ids flip
/// case against their main app.
public enum CallAppFamily {
    /// The segment that marks a helper, not a substring: `com.helperbot.app` is
    /// one app's name, not a helper of `com`.
    private static let helperSegment: Substring = "helper"

    /// `com.google.Chrome.helper.Renderer` → `com.google.Chrome`; an id with no
    /// `.helper` segment is its own family (`us.zoom.xos`). Lowercased, since that
    /// is how families are compared. An id whose first segment is the marker
    /// itself stays whole: an empty family would be a prefix of every app on the
    /// Mac.
    public static func of(_ bundleID: String) -> String {
        let id = bundleID.lowercased()
        let segments = id.split(separator: ".")
        guard let marker = segments.firstIndex(of: helperSegment), marker > 0 else { return id }
        return segments[..<marker].joined(separator: ".")
    }

    /// True when `bundleID` is that app itself or a helper under it — the same
    /// segments `of` folds. `com.google.Chrome.canary` is a neighbour of Chrome and
    /// not a helper of it, and the empty family belongs to nobody.
    public static func belongs(_ bundleID: String, to family: String) -> Bool {
        guard !family.isEmpty else { return false }
        return of(bundleID) == family.lowercased()
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
    /// The app's display name, snapshotted once at the meeting start while the
    /// process is known alive: a pid read later may be dead or reused by now.
    /// Nil when no live process matched — then the meeting stays nameless.
    public let displayName: String?

    public init(bundleID: String, pid: pid_t?, family: String, displayName: String? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.family = family
        self.displayName = displayName
    }

    /// Where the system stem comes from, once the app is known.
    public var scope: MeetingAudioScope { .family(family) }
}

/// What a process tap has to cover to hold a scope.
public enum TapCoverage: Equatable, Sendable {
    /// Everything that plays on the Mac.
    case global
    /// Only these CoreAudio process objects.
    case processes([UInt32])
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

    /// Which live processes a tap has to cover to hold exactly this scope. A
    /// family with nothing running — or a process CoreAudio would not name — leaves
    /// nothing to tap, and the whole Mac beats dropping the call: the one
    /// degradation this path allows, and the caller logs it.
    public func coverage(live: [(id: UInt32, bundleID: String?)]) -> TapCoverage {
        guard case .family(let family) = self else { return .global }
        let ids = live.filter { candidate in
            candidate.bundleID.map { CallAppFamily.belongs($0, to: family) } ?? false
        }.map { $0.id }
        return ids.isEmpty ? .global : .processes(ids)
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
        /// True when the process is playing audio as well — the remote side of a
        /// call, which is what the detector judges a call by.
        public let isRunningOutput: Bool

        public init(bundleID: String, pid: pid_t, isRunningOutput: Bool) {
            self.bundleID = bundleID
            self.pid = pid
            self.isRunningOutput = isRunningOutput
        }
    }

    /// The detector's answer is authoritative; the pid only names it for the
    /// user, so a holder that vanished costs the name and not the scope.
    /// `displayName` maps that pid to a name (AppKit on the caller's side) and
    /// is stored as is — the resolver never looks names up itself.
    public static func resolve(
        source: MeetingStartSource, holders: [Holder], policy: MeetingDetectionPolicy,
        displayName: (pid_t?) -> String? = { _ in nil }
    ) -> MeetingCallApp? {
        switch source {
        case .auto(let bundleID):
            return bundleID.map { auto(bundleID: $0, holders: holders, displayName: displayName) }
        case .manual: return manual(holders: holders, policy: policy, displayName: displayName)
        }
    }

    /// A helper id is a fine answer here: the tap is scoped to the family, and
    /// every helper of that app is inside it.
    private static func auto(
        bundleID: String, holders: [Holder], displayName: (pid_t?) -> String?
    ) -> MeetingCallApp {
        let family = CallAppFamily.of(bundleID)
        let pid = holders.first { CallAppFamily.belongs($0.bundleID, to: family) }?.pid
        return MeetingCallApp(
            bundleID: bundleID, pid: pid, family: family, displayName: displayName(pid)
        )
    }

    /// No detector answer, so the call app is the mic holder the policy would
    /// record — the same judgement the detector itself makes. A holder that is also
    /// playing audio comes first: a call is full-duplex, while an input-only holder
    /// (a voice search, a recorder the deny list missed) renders no remote audio
    /// for the tap to capture.
    private static func manual(
        holders: [Holder], policy: MeetingDetectionPolicy, displayName: (pid_t?) -> String?
    ) -> MeetingCallApp? {
        let recordable = holders.filter { policy.classify($0.bundleID) == .record }
        let chosen = recordable.first { $0.isRunningOutput } ?? recordable.first
        return chosen.map {
            MeetingCallApp(
                bundleID: $0.bundleID, pid: $0.pid, family: CallAppFamily.of($0.bundleID),
                displayName: displayName($0.pid)
            )
        }
    }
}
