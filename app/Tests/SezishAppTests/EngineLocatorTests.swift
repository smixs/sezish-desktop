import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// Detection is the one part of the summary feature that talks to somebody else's
/// binary, so every rule here comes from a way that conversation goes wrong in the
/// field: a CLI that answers "not logged in" with exit 1, a probe that hangs, a
/// second install shadowing the first, a private install that must not read the
/// user's own Codex home. Fixtures are shell scripts, because the contract under
/// test is exactly "what the process printed and how it exited".
@Suite struct EngineLocatorTests {

    // MARK: - Fixtures

    /// A temp dir that cleans itself up when the test's `defer` runs.
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an executable `/bin/sh` script and runs it once.
    ///
    /// Permissions are set after the write because an atomic write lands a fresh
    /// inode and drops the old mode bits — re-staging a script (see the
    /// soft-failure test) would otherwise lose +x.
    ///
    /// The throwaway run is what keeps the timeouts honest: the first exec of a
    /// newly written file pays a system scan worth hundreds of milliseconds, and
    /// those scans serialize machine-wide, so a suite full of fresh fixtures can
    /// push a `--version` past its 3s ceiling for reasons that have nothing to do
    /// with the code. `warmup` matches no branch in any fixture, so nothing
    /// observable happens — the scan is simply already paid when the test starts.
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
        let pipe = Pipe()
        warmup.standardOutput = pipe
        warmup.standardError = pipe
        try warmup.run()
        // EOF on the pipe means the child is gone. Deliberately not
        // `waitUntilExit()`, which can miss its wake-up and block forever.
        _ = try? pipe.fileHandleForReading.readToEnd()
    }

    /// Injectable clock. A test must be able to jump five minutes without sleeping
    /// for them, and the locator's cache reads time only through this closure.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    // MARK: - 1. Version parsers

    @Test func parsesClaudeVersionOutput() {
        #expect(EngineLocator.parseClaudeVersion("2.1.211 (Claude Code)") == "2.1.211")
        // The real CLI writes a trailing newline, and stdout may carry more lines.
        #expect(EngineLocator.parseClaudeVersion("2.1.211 (Claude Code)\n") == "2.1.211")
        #expect(EngineLocator.parseClaudeVersion("  2.1.211 (Claude Code)  \n") == "2.1.211")
        // Garbage must not read as a version: a broken binary is not an install.
        #expect(EngineLocator.parseClaudeVersion("2.1.211") == nil)
        #expect(EngineLocator.parseClaudeVersion("command not found") == nil)
        #expect(EngineLocator.parseClaudeVersion("") == nil)
    }

    @Test func parsesCodexVersionOutput() {
        #expect(EngineLocator.parseCodexVersion("codex-cli 0.146.0") == "0.146.0")
        #expect(EngineLocator.parseCodexVersion("codex-cli 0.146.0\n") == "0.146.0")
        #expect(EngineLocator.parseCodexVersion("0.146.0") == nil)
        #expect(EngineLocator.parseCodexVersion("codex-cli ") == nil)
        #expect(EngineLocator.parseCodexVersion("") == nil)
    }

    // MARK: - 2. Candidate resolution

    @Test func reportsNotInstalledWhenNoCandidateExists() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let locator = EngineLocator(
            claudeCandidates: [dir.appendingPathComponent("claude")]
        )
        #expect(locator.binaryURL(of: .claude) == nil)
        #expect(await locator.status(of: .claude) == .notInstalled)
    }

    @Test func picksTheFirstCandidateThatExists() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two installs on disk plus one path that was never there: order in the
        // candidate list is the tie-breaker, not "whichever we stumble on".
        let missing = root.appendingPathComponent("nowhere/claude")
        let first = root.appendingPathComponent("first/claude")
        let second = root.appendingPathComponent("second/claude")
        try Self.writeScript("echo '2.1.211 (Claude Code)'", to: first)
        try Self.writeScript("echo '9.9.9 (Claude Code)'", to: second)

        let locator = EngineLocator(claudeCandidates: [missing, first, second])
        #expect(locator.binaryURL(of: .claude) == first)
    }

    // MARK: - 3-4. Claude login probe

    @Test func claudeIsReadyWhenAuthStatusSaysLoggedIn() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.211 (Claude Code)' ;;
              auth) echo '{"loggedIn": true}' ;;
            esac
            """,
            to: script
        )

        let locator = EngineLocator(claudeCandidates: [script])
        #expect(await locator.status(of: .claude) == .ready(version: "2.1.211"))
    }

    @Test func claudeNeedsLoginWhenAuthStatusExitsOneWithJson() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // The bug this test exists for: `claude auth status` reports a logged-out
        // user with exit code 1 AND a perfectly valid body. Treating exit != 0 as a
        // probe failure would show every logged-out user a "detection broken" state
        // instead of the "log in" button they need.
        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.211 (Claude Code)' ;;
              auth) echo '{"loggedIn": false}'; exit 1 ;;
            esac
            """,
            to: script
        )

        let locator = EngineLocator(claudeCandidates: [script])
        #expect(await locator.status(of: .claude) == .installed(version: "2.1.211"))
    }

    // MARK: - 5. Codex login probe

    @Test func codexIsReadyWhenLoginStatusExitsZero() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("codex")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo 'codex-cli 0.146.0' ;;
              login) exit 0 ;;
            esac
            """,
            to: script
        )

        let locator = EngineLocator(codexCandidates: [script])
        #expect(await locator.status(of: .codex) == .ready(version: "0.146.0"))
    }

    @Test func codexNeedsLoginWhenLoginStatusExitsNonZero() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("codex")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo 'codex-cli 0.146.0' ;;
              login) exit 1 ;;
            esac
            """,
            to: script
        )

        let locator = EngineLocator(codexCandidates: [script])
        #expect(await locator.status(of: .codex) == .installed(version: "0.146.0"))
    }

    // MARK: - 6. Soft failure

    @Test func aTimedOutProbeKeepsTheLastGoodStatus() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("claude")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.211 (Claude Code)' ;;
              auth) echo '{"loggedIn": true}' ;;
            esac
            """,
            to: script
        )

        // The one timing in the suite: a spawn-and-echo costs single-digit
        // milliseconds, so 0.3s is comfortable for the fast branch and hopeless
        // for the wedged one.
        let locator = EngineLocator(claudeCandidates: [script], probeTimeout: 0.3)
        #expect(await locator.status(of: .claude) == .ready(version: "2.1.211"))

        // Same binary, now wedged on the auth probe only — the shape of a CLI that
        // stalls on a network call. `exec` so SIGTERM lands on the sleeper itself
        // and not on a shell that would leave it holding our stdout pipe open.
        try Self.writeScript(
            """
            case "$1" in
              --version) echo '2.1.211 (Claude Code)' ;;
              auth) exec sleep 5 ;;
            esac
            """,
            to: script
        )

        // A probe that could not answer is not evidence the user got logged out.
        #expect(await locator.status(of: .claude, bypassCache: true) == .ready(version: "2.1.211"))
    }

    // MARK: - 7. Cache

    @Test func cachesForFiveMinutesAgainstTheInjectedClock() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("claude")
        let calls = root.appendingPathComponent("version-calls.txt")
        // Counting `--version` counts probe rounds: one round runs it exactly once.
        try Self.writeScript(
            """
            case "$1" in
              --version) echo x >> '\(calls.path)'; echo '2.1.211 (Claude Code)' ;;
              auth) echo '{"loggedIn": true}' ;;
            esac
            """,
            to: script
        )

        let clock = TestClock(Date())
        let locator = EngineLocator(claudeCandidates: [script], now: { clock.now })

        #expect(await locator.status(of: .claude) == .ready(version: "2.1.211"))
        #expect(await locator.status(of: .claude) == .ready(version: "2.1.211"))
        #expect(Self.lineCount(of: calls) == 1)

        clock.advance(by: 6 * 60)
        #expect(await locator.status(of: .claude) == .ready(version: "2.1.211"))
        #expect(Self.lineCount(of: calls) == 2)
    }

    private static func lineCount(of url: URL) -> Int {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    // MARK: - 8. CODEX_HOME

    @Test func passesCodexHomeToOurPrivateInstall() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Only the binary WE install gets our CODEX_HOME; the path tail is what
        // marks it. A user's own codex must keep reading its own ~/.codex.
        let script = root.appendingPathComponent("sezish/bin/codex")
        let sink = root.appendingPathComponent("seen-codex-home.txt")
        try Self.writeScript(
            """
            case "$1" in
              --version) echo 'codex-cli 0.146.0' ;;
              login) printf '%s' "$CODEX_HOME" > '\(sink.path)' ;;
            esac
            """,
            to: script
        )

        let codexHome = root.appendingPathComponent("private-codex-home", isDirectory: true)
        let locator = EngineLocator(codexCandidates: [script], codexHome: codexHome)
        #expect(await locator.status(of: .codex) == .ready(version: "0.146.0"))
        #expect(try String(contentsOf: sink, encoding: .utf8) == codexHome.path)
    }
}
