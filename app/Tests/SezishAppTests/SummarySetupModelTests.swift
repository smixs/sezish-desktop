import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The settings pane is a switch over `SummarySetupModel.phase`, so every rule the
/// user can see is really a rule about this state machine: what a probe means, what
/// a login event means, and what happens after the CLI says it is done.
///
/// Nothing is mocked at the type level. The locator, the installer and both login
/// sessions are the production ones, pointed at fixture shell scripts — the same
/// trick `EngineLocatorTests` and `EngineSetupTests` use, because the contract under
/// test is exactly "what the process printed, what it read, and how it exited". Only
/// two things are injected: the browser (a test must see that a URL was opened
/// without a browser opening) and the session timeouts.
@MainActor @Suite struct SummarySetupModelTests {

    // MARK: - Fixtures

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an executable `/bin/sh` script and runs it once.
    ///
    /// Permissions are set after the write because an atomic write lands a fresh inode
    /// and drops the old mode bits. The throwaway run is what keeps the timeouts
    /// honest: the first exec of a newly written file pays a system scan worth
    /// hundreds of milliseconds, and those scans serialize machine-wide.
    ///
    /// The warmup gets a CLOSED stdin, as in `EngineSetupTests`: these fixtures block
    /// on `read`, and a warmup inheriting the test runner's stdin would hang the suite
    /// instead of warming it.
    private static func writeScript(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )

        let warmup = Process()
        warmup.executableURL = url
        warmup.arguments = ["warmup"]
        let output = Pipe()
        warmup.standardOutput = output
        warmup.standardError = output
        let input = Pipe()
        warmup.standardInput = input
        try input.fileHandleForWriting.close()
        try warmup.run()
        // EOF on the pipe means the child is gone. Deliberately not `waitUntilExit()`,
        // which can miss its wake-up and block forever.
        _ = try? output.fileHandleForReading.readToEnd()
    }

    /// Captures what the model handed to the browser. `@unchecked Sendable` with a
    /// lock because the model takes the closure as `@Sendable`.
    private final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    /// Empty candidate lists by default: a test must never reach the developer's own
    /// `claude` in `~/.local/bin`. Session timeouts are short so a wedged fixture
    /// fails the suite in seconds instead of holding it for the five-minute default.
    private static func makeModel(
        claude: [URL] = [],
        codex: [URL] = [],
        openURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) -> SummarySetupModel {
        SummarySetupModel(
            locator: EngineLocator(claudeCandidates: claude, codexCandidates: codex),
            openURL: openURL,
            claudeSession: { ClaudeLoginSession(binary: $0, timeout: 20) },
            codexSession: { CodexLoginSession(binary: $0, codexHome: $1, timeout: 20) }
        )
    }

    /// Expectation-style waiting: the sessions finish on their own queues and hop back
    /// here, so a test can only ask "yet?" until it happens or the ceiling is hit. The
    /// sleep is what yields the main actor for those hops.
    private static func wait(
        upTo seconds: TimeInterval = 20, for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - 1. Probe → phase

    @Test func refreshMapsEveryEngineStatusOntoAPhase() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let signedIn = root.appendingPathComponent("ready/claude")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.220 (Claude Code)' ;;
              auth) echo '{"loggedIn": true}' ;;
            esac
            """,
            to: signedIn
        )
        let readyModel = Self.makeModel(claude: [signedIn])
        #expect(readyModel.phase == .unknown)
        await readyModel.refresh(engine: .claude)
        #expect(readyModel.phase == .ready(version: "2.1.220"))

        // Logged out is the state that owes a login, not a broken install.
        let signedOut = root.appendingPathComponent("installed/claude")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.220 (Claude Code)' ;;
              auth) echo '{"loggedIn": false}'; exit 1 ;;
            esac
            """,
            to: signedOut
        )
        let installedModel = Self.makeModel(claude: [signedOut])
        await installedModel.refresh(engine: .claude)
        #expect(installedModel.phase == .installed(version: "2.1.220"))

        let absentModel = Self.makeModel(claude: [root.appendingPathComponent("nowhere/claude")])
        await absentModel.refresh(engine: .claude)
        #expect(absentModel.phase == .notInstalled)
    }

    // MARK: - 2. The whole claude login

    @Test func claudeLoginOpensTheURLAndTheSubmittedCodeLandsOnReady() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // One script plays the whole CLI: it reports itself logged out until the login
        // subcommand receives a code, and logged in afterwards. That marker file is
        // what makes the final re-probe prove the state machine, not just the parser.
        let marker = root.appendingPathComponent("signed-in")
        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; --version) echo '2.1.220 (Claude Code)'; exit 0 ;; esac
            case "$2" in
              status)
                if [ -f '\(marker.path)' ]; then
                  echo '{"loggedIn": true}'
                else
                  echo '{"loggedIn": false}'; exit 1
                fi
                ;;
              login)
                echo 'Docs https://docs.anthropic.com/en/docs/claude-code'
                printf 'Open \\033[4mthis url\\033[0m: https://claude.ai/oauth/authorize?code=abc\\n'
                read code
                [ -n "$code" ] || exit 3
                : > '\(marker.path)'
                echo 'Signed in'
                exit 0
                ;;
            esac
            """,
            to: script
        )

        let opened = OpenedURLs()
        let model = Self.makeModel(claude: [script], openURL: { opened.record($0) })

        await model.refresh(engine: .claude)
        #expect(model.phase == .installed(version: "2.1.220"))

        model.login(engine: .claude)
        let authURL = URL(string: "https://claude.ai/oauth/authorize?code=abc")
        #expect(await Self.wait { model.phase == .loggingIn(authURL: authURL) })
        // Opened once, and not the banner's docs link.
        #expect(opened.all == [authURL])

        // The browser fallback: the child is still alive only because its stdin was
        // never closed, and the code goes back through it.
        model.revealCodeEntry()
        #expect(model.phase == .awaitingCode)
        model.submitPastedCode("XYZ")

        // Success is not asserted by the session's word: the model re-probes, and the
        // CLI's own `auth status` is what flips the pane to ready.
        #expect(await Self.wait { model.phase == .ready(version: "2.1.220") })
    }

    // MARK: - 3. Codex device code

    @Test func codexLoginSurfacesTheDeviceCodeAndCancelReprobes() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A minimal `codex app-server` that answers the login with the device-code
        // pair instead of a URL — the fallback for a machine with no usable browser.
        let script = root.appendingPathComponent("codex")
        try Self.writeScript(
            """
            case "$1" in
              warmup) exit 0 ;;
              --version) echo 'codex-cli 0.146.0'; exit 0 ;;
              login) exit 1 ;;
            esac
            while IFS= read -r line; do
              case "$line" in
                *'"account/read"'*)
                  echo '{"jsonrpc":"2.0","id":1,"result":{"account":null}}'
                  ;;
                *'"account/login/start"'*)
                  echo '{"jsonrpc":"2.0","id":2,"result":{"verificationUrl":"https://auth.openai.com/device","userCode":"ABCD-1234"}}'
                  ;;
              esac
            done
            """,
            to: script
        )

        let opened = OpenedURLs()
        let model = Self.makeModel(codex: [script], openURL: { opened.record($0) })

        model.login(engine: .codex)
        #expect(
            await Self.wait {
                model.phase == .deviceCode(url: "https://auth.openai.com/device", code: "ABCD-1234")
            }
        )
        // A device code is typed by hand: nothing was sent to the browser.
        #expect(opened.all.isEmpty)

        // Cancelling asks the CLI where that left us rather than guessing — here,
        // still installed and still logged out.
        model.cancelLogin()
        #expect(await Self.wait { model.phase == .installed(version: "0.146.0") })
    }

    // MARK: - 4. A login that fails

    @Test func aFailedLoginIsRecoverableWithARetry() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; --version) echo '2.1.220 (Claude Code)'; exit 0 ;; esac
            case "$2" in
              status) echo '{"loggedIn": false}'; exit 1 ;;
              login) echo 'error: cannot reach anthropic' >&2; exit 2 ;;
            esac
            """,
            to: script
        )

        let model = Self.makeModel(claude: [script])
        model.login(engine: .claude)

        #expect(await Self.wait { if case .failed = model.phase { true } else { false } })
        // The CLI's own words reach the pane: exit 2 alone explains nothing.
        if case .failed(let message) = model.phase {
            #expect(message.contains("cannot reach anthropic"))
        }

        // Retry is the pane's «Повторить»: a plain re-probe, which must find the
        // install again instead of leaving the user parked on the error.
        await model.refresh(engine: .claude)
        #expect(model.phase == .installed(version: "2.1.220"))
    }

    // MARK: - 5. The log

    @Test func logLinesAreCappedAtTwenty() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A chatty CLI: 30 lines of progress. The pane's footer is four lines tall and
        // the model keeps the last twenty — an install must not grow unbounded state.
        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; --version) echo '2.1.220 (Claude Code)'; exit 0 ;; esac
            i=1
            while [ $i -le 30 ]; do echo "line-$i"; i=$((i + 1)); done
            exit 3
            """,
            to: script
        )

        let model = Self.makeModel(claude: [script])
        model.login(engine: .claude)

        #expect(await Self.wait { if case .failed = model.phase { true } else { false } })
        #expect(model.logLines.count == 20)
        // The newest survive, the oldest are gone.
        #expect(model.logLines.last == "line-30")
        #expect(!model.logLines.contains("line-1"))
    }
}
