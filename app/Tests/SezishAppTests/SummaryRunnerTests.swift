import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The summary runner hands a finished meeting to somebody else's CLI, so the only
/// honest fixture is a real process: shell scripts that answer `--version` and the
/// login probe the way the real binaries do, then act out one way the run can end.
/// Every case here is a rule that costs the user something when it breaks — a
/// meeting summarized twice, an engine invoked while logged out, a marker stamped
/// over a run that failed, or their API key quietly billed instead of their plan.
///
/// `.serialized` because one test mutates the process environment (the only way to
/// prove the ANTHROPIC_API_KEY scrub), and because a dozen concurrent `sh` fixtures
/// make the timing test flaky for reasons that are not the code's fault.
@Suite(.serialized) struct SummaryRunnerTests {

    // MARK: - Fixtures

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an executable `/bin/sh` script and runs it once.
    ///
    /// The throwaway run is what keeps the timings honest: the first exec of a newly
    /// written file pays a system scan worth hundreds of milliseconds, and those scans
    /// serialize machine-wide. `warmup` matches no branch in any fixture, so nothing
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

    /// A fake `claude`: the two detection branches the locator needs, plus a `-p`
    /// branch the test supplies. Every `-p` bumps a counter file, which is how a test
    /// proves the CLI was *not* run.
    private static func claudeScript(
        counter: URL, loggedIn: Bool = true, onPrompt: String
    ) -> String {
        let auth =
            loggedIn
            ? "auth) echo '{\"loggedIn\": true}' ;;"
            : "auth) echo '{\"loggedIn\": false}'; exit 1 ;;"
        return """
            case "$1" in
              --version) echo '2.1.211 (Claude Code)' ;;
              \(auth)
              -p)
                echo x >> '\(counter.path)'
            \(onPrompt)
                ;;
            esac
            """
    }

    /// The success branch: records the inherited API key and the full argument vector,
    /// writes a card into the vault WITHOUT creating the directory (that is the
    /// runner's job — see the vault test), and prints an envelope.
    ///
    /// - Parameters:
    ///   - argvSink: every argument, `\u{1F}`-separated. A prompt is multi-line, so a
    ///     line-per-argument dump could not be split back apart.
    ///   - envelope: what the fixture prints on stdout. The default is the ARRAY of
    ///     events claude 2.1.220 actually emits under `--output-format json`.
    private static func claudeSuccessBranch(
        envSink: URL,
        argvSink: URL? = nil,
        envelope: String = #"[{"type":"system"},{"type":"result","is_error":false}]"#
    ) -> String {
        let dumpArgv =
            argvSink.map {
                """
                    : > '\($0.path)'
                    for a in "$@"; do printf '%s\\037' "$a" >> '\($0.path)'; done
                """
            } ?? ""
        return """
            \(dumpArgv)
                printf '%s' "${ANTHROPIC_API_KEY:-UNSET}" > '\(envSink.path)'
                printf 'card' > "$PWD/sezish/meetings/card.md"
                cat <<'ENVELOPE'
            \(envelope)
            ENVELOPE
            """
    }

    /// Splits the `\u{1F}`-separated dump back into the argv the fixture received.
    private static func capturedArgv(_ url: URL) -> [String] {
        let raw = read(url)
        guard !raw.isEmpty else { return [] }
        // Every argument is written WITH a trailing separator, so the split leaves one
        // empty tail element behind.
        return Array(raw.components(separatedBy: "\u{1F}").dropLast())
    }

    /// A meeting .md the transcript heuristic accepts: header plus spoken lines.
    private static func writeMeetingMd(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("2026-07-30 11-00 call.md")
        try """
            # Запись звонка - 30 июля 2026 г. в 11:00

            Длительность: 12:30
            Распознано локально на устройстве
            Audio: [call.m4a](call.m4a)

            [0:00] Я: Давай зафиксируем сроки релиза.

            [0:30] Они: Сдвигаем на неделю, тестирование не успевает.

            [1:00] Я: Хорошо, я пишу это в карточку.

            """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Missing counter file means the branch never ran, which is exactly what the
    /// guard tests assert.
    private static func invocationCount(_ url: URL) -> Int {
        read(url).split(separator: "\n").count
    }

    // MARK: - 1. Happy path

    @Test func writesCardsStampsTheMarkerAndLogs() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let argvSink = root.appendingPathComponent("seen-argv.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter,
                onPrompt: Self.claudeSuccessBranch(envSink: envSink, argvSink: argvSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let meetings = root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: meetings)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        #expect(outcome == .done)
        #expect(Self.invocationCount(counter) == 1)
        // The agent worked in the vault, not wherever the app happened to be.
        #expect(Self.read(notes.appendingPathComponent("sezish/meetings/card.md")) == "card")
        #expect(SummaryMarker.isPresent(in: Self.read(md)))
        #expect(Self.read(log).contains("summary claude:"))

        // The prompt must survive `--add-dir`, which is variadic: without the `--`
        // terminator the real CLI (2.1.220) reads the prompt as one more directory and
        // aborts for want of a prompt. Asserting on the tail of argv is the only way to
        // catch that regression without the real binary.
        let argv = Self.capturedArgv(argvSink)
        let prompt = SummaryPromptBuilder.build(
            outputLanguage: .ru, meetingMdPath: md.path, notesFolderPath: notes.path)
        #expect(argv.last == prompt)
        #expect(argv.dropLast().last == "--")
        let addDir = try #require(argv.firstIndex(of: "--add-dir"))
        #expect(
            URL(fileURLWithPath: argv[addDir + 1]).standardizedFileURL
                == meetings.standardizedFileURL)
        #expect(argv[addDir + 2] == "--")
        // No MCP server from the user's own config gets near the summary agent.
        #expect(argv.contains("--strict-mcp-config"))
    }

    // MARK: - 1a. Envelope shapes

    @Test func acceptsThePlainObjectEnvelope() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        // The documented single-object shape. Older builds print it, and a CLI that
        // updates itself behind our back may print it again.
        try Self.writeScript(
            Self.claudeScript(
                counter: counter,
                onPrompt: Self.claudeSuccessBranch(
                    envSink: envSink, envelope: #"{"type":"result","is_error":false}"#)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        #expect(
            await runner.summarize(
                meetingMd: md, notesFolder: notes, engine: .claude, language: .ru) == .done)
    }

    @Test func readsIsErrorOutOfTheEventArray() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        // Exit 0 with a failure buried in the last event — how the CLI reports hitting
        // the turn limit. A parser that only understood the object shape would swallow
        // this, stamp the marker, and lose the meeting to a summary that never was.
        try Self.writeScript(
            Self.claudeScript(
                counter: counter,
                onPrompt: Self.claudeSuccessBranch(
                    envSink: envSink,
                    envelope: """
                        [{"type":"system"},
                         {"type":"result","is_error":true,"result":"max turns reached"}]
                        """)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        #expect(outcome == .failed("is_error: max turns reached"))
        #expect(!SummaryMarker.isPresent(in: Self.read(md)))
    }

    // MARK: - 2. Idempotency

    @Test func doesNotSummarizeTheSameMeetingTwice() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        #expect(
            await runner.summarize(
                meetingMd: md, notesFolder: notes, engine: .claude, language: .ru) == .done)

        // A retry, a salvage pass, a second launch over the same notes folder: the
        // marker is the only thing standing between the user and a duplicate card set
        // (and a second bill for the tokens).
        #expect(
            await runner.summarize(
                meetingMd: md, notesFolder: notes, engine: .claude, language: .ru) == .skipped)
        #expect(Self.invocationCount(counter) == 1)
    }

    // MARK: - 3. Guards

    @Test func skipsWhenTheEngineIsNotLoggedIn() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, loggedIn: false,
                onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        // Silent, not failed: "log in first" is a state the login UI handles, not a
        // notification the user gets after every call they record.
        #expect(outcome == .skipped)
        #expect(Self.invocationCount(counter) == 0)
        #expect(!SummaryMarker.isPresent(in: Self.read(md)))
    }

    @Test func skipsAMeetingThatHasNoTranscript() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        // Exactly what the app writes when the local model was missing: header lines
        // and an apology, and not one "[m:ss]" line anywhere. There is nothing here to
        // summarize.
        let md = root.appendingPathComponent("empty.md")
        try """
            # Запись звонка - 30 июля 2026 г. в 11:00

            _Восстановлено после сбоя_

            Длительность: 0:42
            Audio: [call.m4a](call.m4a)

            _Текст не распознался — аудио встречи сохранено._

            """.write(to: md, atomically: true, encoding: .utf8)
        // The audio line carries brackets of its own, so a skip here also proves the
        // heuristic looks for a timestamp at the start of a line, not for "[".
        #expect(Self.read(md).contains("["))
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        // The engine here IS ready, so a skip can only come from the transcript guard.
        #expect(outcome == .skipped)
        #expect(Self.invocationCount(counter) == 0)
    }

    @Test func summarizesAMeetingWhoseTranscriptIsOneLine() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        // The exact shape of a real 16-second recording: four header lines and a single
        // rendered segment. A line-counting heuristic called this "no transcript" and
        // silently dropped the meeting — found in the field, and the reason the check
        // now looks for the "[m:ss]" label instead.
        let md = root.appendingPathComponent("short.md")
        try """
            # Запись звонка - 30 июля 2026 г. в 15:42

            Длительность: 0:16
            Распознано локально на устройстве
            Audio: [2026-07-30 15-42.m4a](2026-07-30 15-42.m4a)

            [0:00] Я: Проверка связи, дальше говорим по проекту.

            """.write(to: md, atomically: true, encoding: .utf8)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        #expect(outcome == .done)
        #expect(Self.invocationCount(counter) == 1)
        #expect(SummaryMarker.isPresent(in: Self.read(md)))
    }

    // MARK: - 4. Failure

    @Test func reportsFailureWithoutStampingTheMarker() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter,
                onPrompt: """
                        echo 'rate limit exceeded' >&2
                        exit 3
                    """),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        // Unstamped, so the next run retries instead of skipping a meeting that was
        // never summarized.
        #expect(!SummaryMarker.isPresent(in: Self.read(md)))
        // The log is the only place the user (and we) can see what the CLI said.
        #expect(Self.read(log).contains("rate limit exceeded"))
    }

    // MARK: - 5. Timeout

    @Test func treatsAWedgedEngineAsFailure() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let script = root.appendingPathComponent("bin/claude")
        // `exec` so the SIGTERM lands on the sleeper itself and not on a shell that
        // would leave it holding our stdout pipe open.
        try Self.writeScript(
            Self.claudeScript(counter: counter, onPrompt: "    exec sleep 30"),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), timeout: 0.5, logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .claude, language: .ru)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!SummaryMarker.isPresent(in: Self.read(md)))
    }

    // MARK: - 6. Codex

    @Test func codexSucceedsWhenItWritesItsLastMessage() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("bin/codex")
        // The flags carry the paths, so the fixture reads them out of `$@` exactly the
        // way the real binary does: `--cd` is where the vault is, and
        // `--output-last-message` is the file whose non-emptiness IS codex's success
        // signal (its exit codes are undocumented).
        try Self.writeScript(
            """
            case "$1" in
              --version) echo 'codex-cli 0.146.0' ;;
              login) exit 0 ;;
              exec)
                last=""
                cd_dir=""
                while [ $# -gt 0 ]; do
                  if [ "$1" = "--output-last-message" ]; then last="$2"; fi
                  if [ "$1" = "--cd" ]; then cd_dir="$2"; fi
                  shift
                done
                printf 'card' > "$cd_dir/sezish/meetings/card.md"
                printf 'Saved 1 meeting card.' > "$last"
                ;;
            esac
            """,
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(codexCandidates: [script]), logURL: log)
        let outcome = await runner.summarize(
            meetingMd: md, notesFolder: notes, engine: .codex, language: .uz)

        #expect(outcome == .done)
        #expect(Self.read(notes.appendingPathComponent("sezish/meetings/card.md")) == "card")
        #expect(SummaryMarker.isPresent(in: Self.read(md)))
        #expect(Self.read(log).contains("summary codex:"))
    }

    // MARK: - 7. API key scrub

    @Test func scrubsAnInheritedAnthropicApiKey() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        // Mutating the test process' own environment is the only way to reproduce the
        // machine we are defending against: a developer's shell where a stray
        // ANTHROPIC_API_KEY would silently bill the user's API account for work their
        // Claude subscription already covers. Safe here because the suite is
        // `.serialized`, and undone immediately after.
        setenv("ANTHROPIC_API_KEY", "sk-ant-sentinel", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        #expect(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == "sk-ant-sentinel")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        #expect(
            await runner.summarize(
                meetingMd: md, notesFolder: notes, engine: .claude, language: .ru) == .done)
        #expect(Self.read(envSink) == "UNSET")
    }

    // MARK: - 8. Vault directories

    @Test func createsTheVaultDirectoriesBeforeInvokingTheEngine() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("invocations.txt")
        let envSink = root.appendingPathComponent("seen-api-key.txt")
        let script = root.appendingPathComponent("bin/claude")
        // The fixture writes its card WITHOUT `mkdir -p`: if the runner had not made
        // the directory, the redirect fails and the card is simply not there.
        try Self.writeScript(
            Self.claudeScript(
                counter: counter, onPrompt: Self.claudeSuccessBranch(envSink: envSink)),
            to: script
        )

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let md = try Self.writeMeetingMd(in: root)
        let log = root.appendingPathComponent("logs/summary.log")

        let runner = SummaryRunner(
            locator: EngineLocator(claudeCandidates: [script]), logURL: log)
        #expect(
            await runner.summarize(
                meetingMd: md, notesFolder: notes, engine: .claude, language: .ru) == .done)

        // All four, not just the one the fixture used: the agent must never spend a
        // turn on `mkdir`.
        let fm = FileManager.default
        for dir in ["meetings", "people", "projects", "decisions"] {
            var isDirectory: ObjCBool = false
            let path = notes.appendingPathComponent("sezish/\(dir)").path
            #expect(fm.fileExists(atPath: path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        #expect(Self.read(notes.appendingPathComponent("sezish/meetings/card.md")) == "card")
    }
}
