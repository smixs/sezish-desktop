import Foundation
import Testing

@testable import SezishApp

/// Installing a CLI and signing it in is the one place sezish *drives* somebody
/// else's tool instead of merely calling it, so the rules under test are the ones
/// that break in the field: escape codes around the URL we need, banner links that
/// look like the OAuth link, a child that blocks on stdin, a framing we cannot pin
/// from the outside, and a config file a re-install must not eat.
///
/// Fixtures are shell scripts and a locally built tarball: the contract under test is
/// exactly "what the process printed, what it read, and how it exited", and none of
/// it needs a network.
@Suite struct EngineSetupTests {

    // MARK: - Fixtures

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-\(UUID().uuidString)", isDirectory: true)
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
    /// Unlike the `EngineLocatorTests` copy, the warmup gets a CLOSED stdin: these
    /// fixtures block on `read`, and a warmup inheriting the test runner's stdin would
    /// hang the suite instead of warming it.
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

    @discardableResult
    private static func runTar(_ arguments: [String]) throws -> Int32 {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = arguments
        let pipe = Pipe()
        tar.standardOutput = pipe
        tar.standardError = pipe
        try tar.run()
        _ = try? pipe.fileHandleForReading.readToEnd()
        // EOF means the child closed the pipe, not that it has been reaped — and
        // `terminationStatus` throws on a task that is still running. Spinning for the
        // last microseconds beats `waitUntilExit()`, which can miss its wake-up.
        while tar.isRunning { Thread.sleep(forTimeInterval: 0.001) }
        return tar.terminationStatus
    }

    /// Collects the events a session emits from its private queue, for a test that
    /// reads them from another thread entirely.
    private final class EventLog: @unchecked Sendable {
        struct Finish {
            let success: Bool
            let message: String
        }

        private let lock = NSLock()
        private var events: [LoginEvent] = []

        func record(_ event: LoginEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        var all: [LoginEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var authURLs: [URL] {
            all.compactMap {
                if case .authURL(let url) = $0 { return url } else { return nil }
            }
        }

        var finishes: [Finish] {
            all.compactMap {
                if case .finished(let success, let message) = $0 {
                    return Finish(success: success, message: message)
                }
                return nil
            }
        }
    }

    /// Expectation-style waiting: these flows finish on their own queue, so a test can
    /// only ask "yet?" until it happens or the ceiling is hit.
    private static func wait(
        upTo seconds: TimeInterval = 15, for condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - 1. ANSI stripping

    @Test func stripsAnsiColourAndHyperlinkSequences() {
        #expect(ClaudeLoginSession.stripANSI("\u{1B}[31mred\u{1B}[0m") == "red")
        // Erase-line and cursor-column: what a spinner leaves behind.
        #expect(
            ClaudeLoginSession.stripANSI("\u{1B}[2K\u{1B}[1GOpen \u{1B}[4mhttps://claude.ai/x\u{1B}[0m now")
                == "Open https://claude.ai/x now"
        )
        // OSC 8 hyperlink, BEL-terminated: the URL hides INSIDE the escape, so the
        // visible text is all that is left.
        #expect(
            ClaudeLoginSession.stripANSI(
                "\u{1B}]8;;https://claude.ai/oauth\u{07}click here\u{1B}]8;;\u{07}"
            ) == "click here"
        )
        // OSC terminated by ST (ESC \) rather than BEL.
        #expect(ClaudeLoginSession.stripANSI("\u{1B}]0;window title\u{1B}\\plain") == "plain")
        #expect(ClaudeLoginSession.stripANSI("nothing to strip") == "nothing to strip")
    }

    // MARK: - 2. Auth URL matching

    @Test func picksOnlyTheClaudeOauthURL() {
        // The banner links are the trap: opening the docs instead of the OAuth page is
        // the reported failure this matcher exists for.
        #expect(
            ClaudeLoginSession.firstAuthURL(
                in: "Docs: https://docs.anthropic.com/en/docs/claude-code — "
                    + "issues: https://github.com/anthropics/claude-code/issues"
            ) == nil
        )
        #expect(
            ClaudeLoginSession.firstAuthURL(
                in: "See https://github.com/anthropics/claude-code then open "
                    + "https://claude.ai/oauth/authorize?code=abc to sign in"
            )?.absoluteString == "https://claude.ai/oauth/authorize?code=abc"
        )
        // claude.com is the same account, and www. is a legal spelling of both.
        #expect(
            ClaudeLoginSession.firstAuthURL(in: "https://www.claude.com/oauth/authorize?x=1")?
                .absoluteString == "https://www.claude.com/oauth/authorize?x=1"
        )
        // First one wins: the earliest match is the one the CLI meant.
        #expect(
            ClaudeLoginSession.firstAuthURL(
                in: "https://claude.ai/first https://claude.ai/second"
            )?.absoluteString == "https://claude.ai/first"
        )
        #expect(ClaudeLoginSession.firstAuthURL(in: "no url here at all") == nil)
        // A host that merely ends in claude.ai is a different host.
        #expect(ClaudeLoginSession.firstAuthURL(in: "https://notclaude.ai/oauth") == nil)
    }

    // MARK: - 3. JSON-RPC framing

    @Test func decodesBothJsonRpcFramings() {
        let framing = JsonRpcFraming()

        // (a) two newline-delimited messages arriving in one read.
        let pair = framing.append(Data((#"{"id":1}"# + "\n" + #"{"id":2}"# + "\n").utf8))
        #expect(pair.count == 2)
        #expect(pair.first?["id"] as? Int == 1)
        #expect(pair.last?["id"] as? Int == 2)

        // One message split across reads: a pipe boundary is not a message boundary.
        #expect(framing.append(Data(#"{"id":"#.utf8)).isEmpty)
        let completed = framing.append(Data("3}\n".utf8))
        #expect(completed.count == 1)
        #expect(completed.first?["id"] as? Int == 3)

        // (b) LSP-style Content-Length framing, detected per message.
        let body = #"{"id":4,"method":"account/login/completed"}"#
        let framed = framing.append(Data("Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        #expect(framed.count == 1)
        #expect(framed.first?["method"] as? String == "account/login/completed")

        // Garbage is skipped, not fatal: the server may log to stdout and the login
        // must survive it.
        let afterGarbage = framing.append(Data(("this is not json\n" + #"{"id":5}"# + "\n").utf8))
        #expect(afterGarbage.count == 1)
        #expect(afterGarbage.first?["id"] as? Int == 5)
    }

    // MARK: - 4. The installer one-liner

    @Test func claudeInstallCommandIsTheOfficialOneLiner() {
        // A constant guard, not a tautology: this string is piped into bash, so it may
        // only ever be the line Anthropic documents.
        #expect(EngineInstaller.claudeInstallCommand.contains("https://claude.ai/install.sh"))
        #expect(
            EngineInstaller.claudeInstallCommand == "curl -fsSL https://claude.ai/install.sh | bash"
        )
    }

    // MARK: - 5. Codex tarball install

    @Test func installsCodexFromATarballWithoutClobberingTheConfig() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // The archive holds one entry named after the target triple, exactly like the
        // real release asset — and the installer must rename it to `codex`.
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try Self.writeScript(
            """
            case "$1" in
              --version) echo 'codex-cli 0.146.0' ;;
            esac
            """,
            to: payload.appendingPathComponent("codex-aarch64-apple-darwin")
        )

        let tarball = root.appendingPathComponent("codex.tar.gz")
        #expect(
            try Self.runTar([
                "-czf", tarball.path, "-C", payload.path, "codex-aarch64-apple-darwin",
            ]) == 0
        )

        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let installer = EngineInstaller(
            binDir: binDir, codexHome: codexHome, codexTarballURL: tarball
        )

        // Bound to a local so a failure prints the reason instead of the call.
        let firstInstall = await installer.installCodex { _ in }
        #expect(firstInstall == .installed)

        let binary = binDir.appendingPathComponent("codex")
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))

        let config = codexHome.appendingPathComponent("config.toml")
        let written = try String(contentsOf: config, encoding: .utf8)
        // Without this line codex writes the tokens to a plaintext auth.json.
        #expect(written.contains("cli_auth_credentials_store = \"keyring\""))

        // A second install is the upgrade path, and by then the config may carry the
        // user's own settings — or the login itself.
        try (written + "\nmodel = \"gpt-5\"\n").write(to: config, atomically: true, encoding: .utf8)
        let secondInstall = await installer.installCodex { _ in }
        #expect(secondInstall == .installed)
        #expect(try String(contentsOf: config, encoding: .utf8).contains("model = \"gpt-5\""))
    }

    // MARK: - 6-7. Claude login session

    @Test func claudeLoginEmitsTheOauthURLThenFinishesOnTheSubmittedCode() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // The shape of the real thing: banner links first, the OAuth URL wrapped in
        // escape codes, then a blocking read for the pasted code.
        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; esac
            echo 'Docs https://docs.anthropic.com/en/docs/claude-code'
            echo 'Issues https://github.com/anthropics/claude-code/issues'
            printf 'Open \\033[4mthis url\\033[0m: https://claude.ai/oauth/authorize?code=abc\\n'
            printf 'Paste code here: '
            read code
            [ -n "$code" ] || exit 3
            echo 'Signed in'
            exit 0
            """,
            to: script
        )

        let log = EventLog()
        let session = ClaudeLoginSession(binary: script, timeout: 20)
        session.start { log.record($0) }

        #expect(await Self.wait { !log.authURLs.isEmpty })
        // Exactly one, and not one of the banner's.
        #expect(
            log.authURLs.map(\.absoluteString) == ["https://claude.ai/oauth/authorize?code=abc"]
        )
        #expect(log.finishes.isEmpty)

        // The child is still alive only because its stdin was never closed.
        session.submitCode("XYZ")
        #expect(await Self.wait { !log.finishes.isEmpty })
        #expect(log.finishes.count == 1)
        #expect(log.finishes.first?.success == true)
    }

    @Test func claudeLoginReportsAFailureWithoutAURL() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; esac
            echo 'error: cannot reach anthropic' >&2
            exit 2
            """,
            to: script
        )

        let log = EventLog()
        let session = ClaudeLoginSession(binary: script, timeout: 20)
        session.start { log.record($0) }

        #expect(await Self.wait { !log.finishes.isEmpty })
        #expect(log.finishes.count == 1)
        #expect(log.finishes.first?.success == false)
        // The CLI's own words reach the UI log: exit 2 alone explains nothing.
        #expect(log.finishes.first?.message.contains("cannot reach anthropic") == true)
        #expect(log.authURLs.isEmpty)
    }

    // MARK: - 8-9. Codex login session

    @Test func codexLoginEmitsTheAuthURLThenTheCompletedNotification() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A minimal `codex app-server`: answers each request it recognises on the line
        // it arrived on, then pushes the completion notification the real one sends.
        let script = root.appendingPathComponent("codex")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; esac
            while IFS= read -r line; do
              case "$line" in
                *'"account/read"'*)
                  echo '{"jsonrpc":"2.0","id":1,"result":{"account":null}}'
                  ;;
                *'"account/login/start"'*)
                  echo '{"jsonrpc":"2.0","id":2,"result":{"authUrl":"https://auth.openai.com/oauth/authorize?x=1","loginId":"L1"}}'
                  echo '{"jsonrpc":"2.0","method":"account/login/completed","params":{"loginId":"L1","success":true}}'
                  exit 0
                  ;;
              esac
            done
            """,
            to: script
        )

        let log = EventLog()
        let session = CodexLoginSession(binary: script, codexHome: nil, timeout: 20)
        session.start { log.record($0) }

        #expect(await Self.wait { !log.finishes.isEmpty })
        #expect(
            log.authURLs.map(\.absoluteString) == ["https://auth.openai.com/oauth/authorize?x=1"]
        )
        #expect(log.finishes.count == 1)
        #expect(log.finishes.first?.success == true)

        // Order matters to the UI: the browser opens before the sheet closes.
        let indexOfURL = log.all.firstIndex { if case .authURL = $0 { true } else { false } }
        let indexOfFinish = log.all.firstIndex { if case .finished = $0 { true } else { false } }
        #expect(indexOfURL != nil && indexOfFinish != nil && indexOfURL! < indexOfFinish!)
    }

    @Test func codexLoginStopsAtOnceWhenTheAccountIsAlreadySignedIn() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A non-null account means there is nothing to do — and no browser to open.
        let script = root.appendingPathComponent("codex")
        try Self.writeScript(
            """
            case "$1" in warmup) exit 0 ;; esac
            while IFS= read -r line; do
              case "$line" in
                *'"account/read"'*)
                  echo '{"jsonrpc":"2.0","id":1,"result":{"account":{"email":"a@b.c"}}}'
                  ;;
              esac
            done
            """,
            to: script
        )

        let log = EventLog()
        let session = CodexLoginSession(binary: script, codexHome: nil, timeout: 20)
        session.start { log.record($0) }

        #expect(await Self.wait { !log.finishes.isEmpty })
        #expect(log.finishes.count == 1)
        #expect(log.finishes.first?.success == true)
        #expect(log.authURLs.isEmpty)
    }
}
