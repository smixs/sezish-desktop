import Foundation
import SezishCore

/// What sezish knows about one summary CLI right now.
///
/// `nonisolated` because the app target defaults to MainActor isolation, which
/// would otherwise isolate the synthesized `Equatable` conformance too and put
/// it out of reach of the detection code (and its tests) running off-main.
nonisolated enum EngineStatus: Equatable, Sendable {
    /// No usable binary on any known path — or one that answered `--version`
    /// with something we cannot read.
    case notInstalled
    /// Binary found and identified, but its account is not logged in.
    case installed(version: String)
    /// Binary found and logged in: summaries can run.
    case ready(version: String)
}

/// Finds the user's own Claude Code / Codex CLI and asks *it* whether it is
/// logged in.
///
/// sezish never reads `~/.claude/.credentials.json`, the Codex auth file, or the
/// Keychain. That is deliberate ToS mitigation as much as engineering: another
/// vendor's credential store is theirs to change without notice, and reading it
/// is not a use their terms invite. The official `auth status` / `login status`
/// subcommands are the supported contract, so they are the only oracle here.
///
/// Detection is also allowed to be *unsure*. A probe that times out proves
/// nothing about the account, so it never demotes what we last saw — a flaky
/// network must not flip a working setup to "please log in".
nonisolated struct EngineLocator {
    /// How long a probe result stays good. Login state changes rarely and each
    /// check costs a process launch, so the UI can ask as often as it likes.
    static let cacheTTL: TimeInterval = 5 * 60

    private let claudeCandidates: [URL]
    private let codexCandidates: [URL]
    private let codexHome: URL
    private let probeTimeout: TimeInterval
    private let versionTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let cache = Cache()

    /// - Parameters:
    ///   - claudeCandidates: overrides the default search path (tests point it at
    ///     fixture scripts).
    ///   - codexHome: `CODEX_HOME` for our own private codex install; ignored for
    ///     a codex the user installed themselves.
    ///   - probeTimeout: ceiling for `auth status` / `login status`. Generous by
    ///     default: these commands can hit the network.
    ///   - versionTimeout: ceiling for `--version`, which is local and instant.
    init(
        claudeCandidates: [URL]? = nil,
        codexCandidates: [URL]? = nil,
        codexHome: URL? = nil,
        probeTimeout: TimeInterval = 15,
        versionTimeout: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.claudeCandidates = claudeCandidates ?? Self.defaultClaudeCandidates
        self.codexCandidates = codexCandidates ?? Self.defaultCodexCandidates
        self.codexHome = codexHome ?? Self.defaultCodexHome
        self.probeTimeout = probeTimeout
        self.versionTimeout = versionTimeout
        self.now = now
    }

    // MARK: - Search paths

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Claude Code's own installer lands in `~/.local/bin`, so that wins over a
    /// Homebrew copy: it is the one the CLI keeps up to date.
    static let defaultClaudeCandidates: [URL] = [
        home.appendingPathComponent(".local/bin/claude"),
        URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        URL(fileURLWithPath: "/usr/local/bin/claude"),
    ]

    /// Ours comes late on purpose: if the user already has a codex, we use theirs
    /// with their account rather than a second install they never asked for.
    static let defaultCodexCandidates: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        home.appendingPathComponent(".local/bin/codex"),
        applicationSupport.appendingPathComponent("sezish/bin/codex"),
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
    ]

    /// A private install needs a private home, or it would read (and write) the
    /// user's `~/.codex` — quietly entangling our state with their own CLI.
    static let defaultCodexHome: URL =
        applicationSupport.appendingPathComponent("sezish/codex-home", isDirectory: true)

    /// The tail that marks our own install. Matching a suffix rather than one
    /// absolute string keeps the rule testable from a temp dir.
    private static let privateInstallTail = ["sezish", "bin", "codex"]

    private func isPrivateInstall(_ binary: URL) -> Bool {
        binary.standardizedFileURL.pathComponents.suffix(3)
            .elementsEqual(Self.privateInstallTail)
    }

    private func candidates(for kind: SummaryEngineKind) -> [URL] {
        switch kind {
        case .claude: claudeCandidates
        case .codex: codexCandidates
        }
    }

    /// First candidate that exists on disk. Order is the tie-breaker when a
    /// machine carries two installs.
    func binaryURL(of kind: SummaryEngineKind) -> URL? {
        candidates(for: kind).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Version parsing

    /// Computed, not stored: `Regex` is not `Sendable`, and building one per call
    /// costs nothing next to the process launch it guards.
    private static var claudeVersionPattern: Regex<(Substring, Substring)> {
        /^(\d+\.\d+\.\d+)\s+\(Claude Code\)$/
    }

    private static let codexVersionPrefix = "codex-cli "

    /// `2.1.211 (Claude Code)` → `2.1.211`. Anything else → nil, and a binary we
    /// cannot identify counts as not installed: a broken or shadowed `claude` on
    /// the path must not present itself as a working engine.
    static func parseClaudeVersion(_ raw: String) -> String? {
        guard let line = firstTrimmedLine(raw),
            let match = try? claudeVersionPattern.wholeMatch(in: line)
        else { return nil }
        return String(match.1)
    }

    /// `codex-cli 0.146.0` → `0.146.0`.
    static func parseCodexVersion(_ raw: String) -> String? {
        guard let line = firstTrimmedLine(raw), line.hasPrefix(codexVersionPrefix) else {
            return nil
        }
        let version = line.dropFirst(codexVersionPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    private static func firstTrimmedLine(_ raw: String) -> String? {
        let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }

    // MARK: - Status

    func status(of kind: SummaryEngineKind, bypassCache: Bool = false) async -> EngineStatus {
        let cached = cache.entry(for: kind)
        if !bypassCache, let cached,
            now().timeIntervalSince(cached.probedAt) < Self.cacheTTL
        {
            return cached.status
        }

        guard let binary = binaryURL(of: kind),
            let version = await detectVersion(of: kind, binary: binary)
        else {
            cache.store(.notInstalled, for: kind, at: now())
            return .notInstalled
        }

        switch await probeLogin(kind, binary: binary) {
        case .loggedIn:
            return cache.store(.ready(version: version), for: kind, at: now())
        case .loggedOut:
            return cache.store(.installed(version: version), for: kind, at: now())
        case .inconclusive:
            // Nothing was learned, so nothing is written: neither the status nor
            // the timestamp. Falling back to the last known answer is what keeps a
            // hung probe from telling a logged-in user to log in again.
            return cached?.status ?? .installed(version: version)
        }
    }

    private func detectVersion(of kind: SummaryEngineKind, binary: URL) async -> String? {
        guard let output = await ProcessRunner.run(
            binary, arguments: ["--version"], timeout: versionTimeout
        ), !output.timedOut else { return nil }

        return switch kind {
        case .claude: Self.parseClaudeVersion(output.stdout)
        case .codex: Self.parseCodexVersion(output.stdout)
        }
    }

    private enum LoginProbe {
        case loggedIn
        case loggedOut
        /// The probe itself failed. Says nothing about the account.
        case inconclusive
    }

    private func probeLogin(_ kind: SummaryEngineKind, binary: URL) async -> LoginProbe {
        switch kind {
        case .claude:
            guard let output = await ProcessRunner.run(
                binary, arguments: ["auth", "status"], timeout: probeTimeout
            ), !output.timedOut else { return .inconclusive }

            // The body decides, NOT the exit code: `claude auth status` answers a
            // logged-out user with exit 1 *and* valid JSON. Reading exit 1 as a
            // failure would report "detection broken" to everyone who simply has
            // not logged in yet — which is exactly the user we need to prompt.
            guard let data = output.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let loggedIn = json["loggedIn"] as? Bool
            else { return .inconclusive }
            return loggedIn ? .loggedIn : .loggedOut

        case .codex:
            // Our own install reads our own home; the user's install is left alone
            // with theirs, or it would suddenly look logged out to them.
            let extraEnv: [String: String?] =
                isPrivateInstall(binary) ? ["CODEX_HOME": codexHome.path] : [:]
            guard let output = await ProcessRunner.run(
                binary, arguments: ["login", "status"], extraEnv: extraEnv,
                timeout: probeTimeout
            ), !output.timedOut else { return .inconclusive }

            // codex has no machine-readable body here; exit 0 is the signal.
            return output.exitCode == 0 ? .loggedIn : .loggedOut
        }
    }

    // MARK: - Cache

    /// Shared by value copies of the locator on purpose: the cost being cached is
    /// process launches, and which struct copy asked for them is irrelevant.
    private final class Cache: @unchecked Sendable {
        struct Entry {
            let status: EngineStatus
            let probedAt: Date
        }

        private let lock = NSLock()
        private var entries: [SummaryEngineKind: Entry] = [:]

        func entry(for kind: SummaryEngineKind) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[kind]
        }

        /// Returns what it stored, so callers read as "record and answer".
        @discardableResult
        func store(
            _ status: EngineStatus, for kind: SummaryEngineKind, at date: Date
        ) -> EngineStatus {
            lock.lock()
            defer { lock.unlock() }
            entries[kind] = Entry(status: status, probedAt: date)
            return status
        }
    }
}
