import Foundation

/// Decides whether a full-duplex audio process (mic in + audio out, see
/// `MeetingDetector`) counts as a call: every process does, except sezish
/// itself and a short deny list of dictation engines, voice-mode assistants,
/// screen recorders, IDEs and DAWs — the apps that are full-duplex without
/// being on a call. No call-app allowlist, no browser tab probing — a browser
/// helper on a call is a call, whichever browser it belongs to (Dia ships Arc's
/// helper bundle ids, which is what broke the old per-browser scheme).
/// Matching is case-insensitive prefix matching, since helper ids change case
/// against their main app.
public struct MeetingDetectionPolicy: Sendable {
    public enum Bucket: Equatable, Sendable {
        case deny
        case record
    }

    public struct Candidate: Equatable, Sendable {
        public let bundleID: String

        public init(bundleID: String) {
            self.bundleID = bundleID
        }
    }

    private let ownPrefix: String
    private let denyPrefixes: [String]

    /// `extraDenyPrefixes` is the `defaults write` escape hatch for silencing
    /// one more app without a release.
    public init(ownBundleID: String, extraDenyPrefixes: [String] = []) {
        ownPrefix = ownBundleID.lowercased()
        denyPrefixes = (Self.builtinDenyPrefixes + extraDenyPrefixes).map { $0.lowercased() }
    }

    public func classify(_ bundleID: String) -> Bucket {
        let id = bundleID.lowercased()
        if id.hasPrefix(ownPrefix) { return .deny }
        if denyPrefixes.contains(where: id.hasPrefix) { return .deny }
        return .record
    }

    /// The first non-deny mic holder this tick; nil when every holder is
    /// deny/own — that feeds the debounce as "mic inactive", so dictation
    /// tools can never even start a session.
    public func candidate(among bundleIDs: [String]) -> Candidate? {
        bundleIDs.first(where: { classify($0) == .record }).map(Candidate.init)
    }

    /// Never a call: dictation/STT engines (the false-positive class every
    /// previous design tripped on), voice-capable AI assistants, screen
    /// recorders, IDEs, and DAWs (full-duplex whenever their engine runs).
    /// Some ids are best-effort — a wrong one costs one unwanted recording,
    /// which the short-recording rule then leaves untranscribed.
    private static let builtinDenyPrefixes: [String] = [
        // Dictation / STT
        "com.electron.wispr-flow",
        "com.superduper.superwhisper",
        "com.prakashjoshipax.VoiceInk",
        "com.goodsnooze.macwhisper",
        "com.electron.aqua-voice",
        "com.fluidvoice.FluidVoice",
        "cc.handy",
        "com.pais.handy",
        "com.apple.VoiceMemos",
        // AI assistants with voice modes
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.raycast.macos",
        // Screen recorders
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "so.cap.desktop",
        "pl.maketheweb.cleanshotx",
        // IDEs / terminals with voice input
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.warp.Warp",
        "com.exafunction.windsurf",
        // DAWs / audio editors: mic in + monitoring out, never a call
        "com.apple.logic10",
        "com.apple.garageband10",
        "com.ableton.live",
        "com.cockos.reaper",
        "org.audacityteam.audacity",
        "com.avid.ProTools",
        "com.image-line.flstudio",
        "com.steinberg.cubase",
        "com.bitwig.BitwigStudio",
        "com.presonus.studioone",
    ]
}
