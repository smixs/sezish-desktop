import Foundation
import Observation
import SezishCore

/// Everything it takes to get one summary CLI ready: probe it, install it, sign it
/// in, probe it again.
///
/// It lives outside the view on purpose. Every interesting step here is asynchronous
/// and comes back from somebody else's process, and a state machine that only exists
/// inside a `body` cannot be tested — so the pane is reduced to a switch over
/// `phase`, and this type is what the tests drive.
///
/// MainActor is spelled out rather than left to the target default because it is load
/// bearing: the locator, the installer and both login sessions call back from their
/// own queues, and every one of those callbacks hops here before touching state. That
/// hop is the only thing keeping `phase` consistent.
@MainActor @Observable final class SummarySetupModel {
    /// What the pane can show, in the order a first-time user meets it.
    enum Phase: Equatable {
        /// Nothing has been probed yet — the pane has not appeared.
        case unknown
        case probing
        case notInstalled
        case installing
        /// The binary is there, the account is not.
        case installed(version: String)
        /// A login is running; the URL appears as soon as the CLI prints it.
        case loggingIn(authURL: URL?)
        /// Claude's fallback: the browser showed a code to paste back.
        case awaitingCode
        /// Codex's fallback: the user types `code` into the page at `url`.
        case deviceCode(url: String, code: String)
        case ready(version: String)
        /// The last operation failed. Always recoverable — the pane offers a retry.
        case failed(message: String)
    }

    private(set) var phase: Phase = .unknown

    /// Rolling tail of what the CLIs said, shown under the status section. It is a
    /// reassurance line, not a transcript: the full record of a summary run is
    /// `summary.log`, and an install prints more than a settings pane can hold.
    var logLines: [String] = []

    private static let logLimit = 20

    @ObservationIgnored private let locator: EngineLocator
    @ObservationIgnored private let installer: EngineInstaller
    @ObservationIgnored private let openURL: @Sendable (URL) -> Void
    @ObservationIgnored private let makeClaudeSession: (URL) -> ClaudeLoginSession
    @ObservationIgnored private let makeCodexSession: (URL, URL?) -> CodexLoginSession

    @ObservationIgnored private var liveSession: LiveSession?
    @ObservationIgnored private var loginEngine: SummaryEngineKind?
    /// Kept so the paste-code detour can put the user back on the browser step with
    /// the same link, instead of stranding them with a spinner and no way back.
    @ObservationIgnored private var lastAuthURL: URL?
    /// Bumped whenever a session is dropped, so an event already in flight from the
    /// old one cannot land on the new one's phase.
    @ObservationIgnored private var loginGeneration = 0
    /// Same idea for probes: switching the engine mid-probe must not let the previous
    /// engine's answer describe the new one.
    @ObservationIgnored private var probeGeneration = 0

    /// - Parameters:
    ///   - openURL: how a sign-in link reaches the browser. Injected because the tests
    ///     must see *that* it was opened without a browser opening.
    ///   - claudeSession: session factories, injectable for the same reason — a test
    ///     points them at a fixture script instead of the real CLI.
    init(
        locator: EngineLocator = EngineLocator(),
        installer: EngineInstaller = EngineInstaller(),
        openURL: @escaping @Sendable (URL) -> Void,
        claudeSession: ((URL) -> ClaudeLoginSession)? = nil,
        codexSession: ((URL, URL?) -> CodexLoginSession)? = nil
    ) {
        self.locator = locator
        self.installer = installer
        self.openURL = openURL
        self.makeClaudeSession = claudeSession ?? { ClaudeLoginSession(binary: $0) }
        self.makeCodexSession = codexSession ?? { CodexLoginSession(binary: $0, codexHome: $1) }
    }

    // MARK: - Probing

    /// Asks the CLI itself, never the cache: this runs while the user is looking at
    /// the pane, and the five-minute-old answer is exactly the one they came to change.
    func refresh(engine: SummaryEngineKind) async {
        probeGeneration += 1
        let generation = probeGeneration
        phase = .probing

        let status = await locator.status(of: engine, bypassCache: true)
        // A probe started for another engine (or superseded by a newer one) has
        // nothing to say about what the pane shows now.
        guard generation == probeGeneration else { return }
        phase = Self.phase(for: status)
    }

    private static func phase(for status: EngineStatus) -> Phase {
        switch status {
        case .notInstalled: .notInstalled
        case .installed(let version): .installed(version: version)
        case .ready(let version): .ready(version: version)
        }
    }

    // MARK: - Installing

    func install(engine: SummaryEngineKind) async {
        phase = .installing

        // The installer reports progress from its own task; the log is MainActor state.
        let progress: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        let outcome: InstallOutcome
        switch engine {
        case .claude: outcome = await installer.installClaude(progress: progress)
        case .codex: outcome = await installer.installCodex(progress: progress)
        }

        switch outcome {
        case .installed:
            // "Installed" is the installer's opinion; the probe is the fact, and it is
            // also what tells the user whether a login is still owed.
            await refresh(engine: engine)
        case .failed(let message):
            append(message)
            phase = .failed(message: message)
        }
    }

    // MARK: - Login

    func login(engine: SummaryEngineKind) {
        discardLiveSession()

        // Defensive: the binary answered a probe moments ago. If it is gone now,
        // something removed it between two clicks and there is nothing to drive.
        guard let binary = locator.binaryURL(of: engine) else {
            phase = .failed(message: "binary disappeared")
            return
        }

        loginEngine = engine
        lastAuthURL = nil
        phase = .loggingIn(authURL: nil)

        let generation = loginGeneration
        switch engine {
        case .claude:
            let session = makeClaudeSession(binary)
            liveSession = .claude(session)
            session.start { [weak self] event in
                Task { @MainActor in
                    self?.handle(event, engine: engine, generation: generation)
                }
            }
        case .codex:
            // Our own install gets our own home; `CodexLoginSession` ignores it for a
            // codex the user installed themselves.
            let session = makeCodexSession(binary, EngineLocator.defaultCodexHome)
            liveSession = .codex(session)
            session.start { [weak self] event in
                Task { @MainActor in
                    self?.handle(event, engine: engine, generation: generation)
                }
            }
        }
    }

    /// Shows the paste field. Deliberately manual: the browser flow finishes on its
    /// own in the happy path, and flipping the UI on a ten-second timer would tell a
    /// user who is mid-login that something went wrong.
    func revealCodeEntry() {
        guard case .loggingIn = phase else { return }
        phase = .awaitingCode
    }

    /// The code the browser printed, handed back to the claude session's stdin — the
    /// documented way that CLI accepts it. Codex has no such channel: it answers with
    /// a device code instead.
    func submitPastedCode(_ code: String) {
        guard case .claude(let session) = liveSession else { return }
        session.submitCode(code)
        // Back to waiting: the CLI finishes on its own from here, and leaving the
        // field up invites a second submission of the same code.
        phase = .loggingIn(authURL: lastAuthURL)
    }

    func cancelLogin() {
        guard let engine = loginEngine else { return }
        discardLiveSession()
        // Ask the CLI where that left us instead of guessing: a login "cancelled" one
        // second late may well have completed in the browser already.
        Task { await refresh(engine: engine) }
    }

    /// Drops the live session without deciding what the UI shows next — both callers
    /// (an explicit cancel, and starting a second login) have their own answer.
    private func discardLiveSession() {
        guard let session = liveSession else { return }
        loginGeneration += 1
        session.cancel()
        liveSession = nil
        loginEngine = nil
    }

    private func handle(_ event: LoginEvent, engine: SummaryEngineKind, generation: Int) {
        guard generation == loginGeneration else { return }

        switch event {
        case .authURL(let url):
            lastAuthURL = url
            openURL(url)
            phase = .loggingIn(authURL: url)
        case .deviceCode(let url, let code):
            phase = .deviceCode(url: url, code: code)
        case .info(let line):
            append(line)
        case .finished(success: true, message: _):
            liveSession = nil
            loginEngine = nil
            // The session says it signed in; the probe says whether the CLI agrees.
            Task { await self.refresh(engine: engine) }
        case .finished(success: false, let message):
            liveSession = nil
            loginEngine = nil
            phase = .failed(message: message)
        }
    }

    // MARK: - Log

    private func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > Self.logLimit {
            logLines.removeFirst(logLines.count - Self.logLimit)
        }
    }

    /// The two session types share no protocol — deliberately, they have nothing in
    /// common beyond being cancellable — so the live one is kept in a box instead.
    private enum LiveSession {
        case claude(ClaudeLoginSession)
        case codex(CodexLoginSession)

        func cancel() {
            switch self {
            case .claude(let session): session.cancel()
            case .codex(let session): session.cancel()
            }
        }
    }
}
