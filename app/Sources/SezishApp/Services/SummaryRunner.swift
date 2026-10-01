import Foundation
import SezishCore

/// Result of one summary attempt, for the caller's notification decision.
///
/// `nonisolated` for the same reason as `EngineStatus`: the app target defaults to
/// MainActor isolation, which would isolate the synthesized `Equatable` too and put
/// it out of reach of the detached task that produces this value.
nonisolated enum SummaryOutcome: Equatable, Sendable {
    case done
    /// Marker already there, or a guard not met. Not an error — and never notified:
    /// a user who has not logged the engine in must not get a complaint after every
    /// call they record.
    case skipped
    /// Short reason, already written to the log.
    case failed(String)
}

/// Hands one finished meeting to the user's own Claude Code / Codex CLI and lets it
/// write cards into their notes vault.
///
/// Everything here is built around one fact: the run is optional. The meeting, its
/// audio and its transcript are already safe on disk before this type is ever called,
/// so no failure it can produce is worth breaking anything over. It guards, it runs,
/// it stamps, it logs — and on any doubt it does nothing at all rather than run twice
/// or claim a summary that does not exist.
///
/// The marker is written by US, never by the agent (see `SummaryMarker`): the prompt
/// does not mention the syntax, so a model cannot stamp a meeting it never read.
nonisolated struct SummaryRunner {
    private let locator: EngineLocator
    private let codexHome: URL
    private let fixedTimeout: TimeInterval?
    private let now: @Sendable () -> Date
    private let logURL: URL

    /// - Parameters:
    ///   - codexHome: `CODEX_HOME` for our own private codex install; ignored for a
    ///     codex the user installed themselves. Same default as `EngineLocator`.
    ///   - timeout: fixed per-attempt ceiling; nil (the app) sizes it from the transcript
    ///     with `timeout(forTranscriptBytes:)`. Tests pass a short one for a wedged CLI.
    ///   - now: the clock behind the "card is newer than the attempt" check.
    ///   - logURL: the field-diagnostics log. There is no UI for any of this, so the
    ///     file is the only place a user can find out what their CLI said.
    init(
        locator: EngineLocator = EngineLocator(),
        codexHome: URL? = nil,
        timeout: TimeInterval? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        logURL: URL? = nil
    ) {
        self.locator = locator
        self.codexHome = codexHome ?? EngineLocator.defaultCodexHome
        self.fixedTimeout = timeout
        self.now = now
        self.logURL = logURL ?? Self.defaultLogURL
    }

    /// Fixed models for every user (owner's decision 01.10.2026).
    static let claudeModel = "claude-sonnet-5-5"
    static let claudeEffort = "high"
    static let codexModel = "gpt-6-luna"
    static let codexEffort = "max"

    /// First try plus two retries (owner's decision 01.10.2026).
    static let maxAttempts = 3

    /// The old 15 turns ran out on long meetings: a transcript read in chunks takes a
    /// turn per chunk (an hour is a handful, two hours about twenty), then one Write per
    /// card (a meeting plus a few people, projects and decisions), then Edits to link
    /// them. 60 leaves that room with slack; the wall-clock timeout, not the turn cap,
    /// is what ends a wedged run.
    static let maxTurns = 60

    /// Wall-clock ceiling for one attempt. 600 s is what a short meeting needed (the
    /// old fixed ceiling). A transcript is about 100 KB per hour of speech, and with
    /// `high` effort the agent needs roughly ten more minutes for every such hour, so
    /// each 100 KB adds 600 s. 1800 s is the ceiling: past half an hour a run is more
    /// likely stuck than slow, and three attempts at it already cost an hour and a half.
    static func timeout(forTranscriptBytes bytes: Int) -> TimeInterval {
        min(1800, 600 + 600 * Double(max(0, bytes)) / 100_000)
    }

    private static var defaultLogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("sezish/summary.log")
    }

    // MARK: - Flow

    /// The whole post-meeting flow: guards → prompt → CLI → marker.
    func summarize(
        meetingMd: URL,
        notesFolder: URL,
        engine: SummaryEngineKind,
        language: AppLanguage
    ) async -> SummaryOutcome {
        let name = meetingMd.lastPathComponent

        guard let md = try? String(contentsOf: meetingMd, encoding: .utf8) else {
            // Not a guard but a real break: the pipeline just wrote this file.
            return failure("cannot read \(name)", engine: engine)
        }
        guard Self.hasTranscript(md) else {
            log("skip \(name): no transcript to summarize", engine: engine)
            return .skipped
        }
        // Before any guard that can skip: the vault copy is the app's own job and does
        // not depend on the engine, a previous stamp or the outcome of the run.
        copyTranscript(md, from: meetingMd, to: notesFolder, engine: engine)
        guard !SummaryMarker.isPresent(in: md) else {
            log("skip \(name): already summarized", engine: engine)
            return .skipped
        }

        let status = await locator.status(of: engine)
        guard case .ready = status, let binary = locator.binaryURL(of: engine) else {
            log("skip \(name): engine not ready (\(status))", engine: engine)
            return .skipped
        }

        ensureVaultDirectories(in: notesFolder, engine: engine)

        let prompt = SummaryPromptBuilder.build(
            outputLanguage: language,
            meetingMdPath: meetingMd.path,
            notesFolderPath: notesFolder.path
        )
        let attemptTimeout =
            fixedTimeout ?? Self.timeout(forTranscriptBytes: md.utf8.count)
        let base = meetingMd.deletingPathExtension().lastPathComponent
        let card = notesFolder
            .appendingPathComponent("\(SummaryVault.subdirectory)/\(SummaryVault.meetingsDir)")
            .appendingPathComponent(base + ".md")

        for attempt in 1...Self.maxAttempts {
            let started = now()
            log(
                "attempt \(attempt)/\(Self.maxAttempts) \(name) via \(binary.path) (timeout \(Int(attemptTimeout))s)",
                engine: engine)

            let reason: String? =
                switch engine {
                case .claude:
                    await runClaude(
                        binary: binary, prompt: prompt, meetingMd: meetingMd,
                        notesFolder: notesFolder, timeout: attemptTimeout)
                case .codex:
                    await runCodex(
                        binary: binary, prompt: prompt, notesFolder: notesFolder,
                        timeout: attemptTimeout)
                }
            // A clean exit proves nothing: the agent can finish happily having written
            // no card at all. The card itself, fresh for THIS attempt, is the proof.
            let failed = reason ?? (Self.cardIsFresh(card, since: started) ? nil : "no meeting card written")
            guard let failed else { break }
            log("attempt \(attempt)/\(Self.maxAttempts) failed: \(failed)", engine: engine)
            if attempt == Self.maxAttempts { return failure(failed, engine: engine) }
        }

        do {
            try SummaryMarker.append(to: meetingMd, date: Date())
        } catch {
            // The cards exist, so the run WAS a success — the user just paid for a
            // summary and must be told it is ready. The cost of the missing stamp is
            // one duplicate run later, which is cheaper than hiding a finished summary.
            log("warning: marker not written to \(name): \(error)", engine: engine)
        }
        log("done \(name)", engine: engine)
        return .done
    }

    private static func cardIsFresh(_ card: URL, since started: Date) -> Bool {
        guard
            let modified = (try? FileManager.default.attributesOfItem(atPath: card.path))?[
                .modificationDate] as? Date
        else { return false }
        return modified >= started
    }

    /// Puts `<notesFolder>/transcripts/YYYY/MM/<base>-transcript.md` in place: the
    /// meeting file as is, minus the marker line. Atomic, and it only ever replaces
    /// this same file. Best-effort: a failed copy is logged and never stops the run.
    private func copyTranscript(
        _ md: String, from meetingMd: URL, to notesFolder: URL, engine: SummaryEngineKind
    ) {
        let base = meetingMd.deletingPathExtension().lastPathComponent
        let modified = (try? FileManager.default.attributesOfItem(atPath: meetingMd.path))?[
            .modificationDate] as? Date ?? Date()
        let target = notesFolder.appendingPathComponent(
            SummaryTranscriptCopy.relativePath(baseName: base, fallbackDate: modified))
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(SummaryMarker.stripped(from: md).utf8).write(to: target, options: .atomic)
        } catch {
            log("warning: transcript copy to vault failed: \(error)", engine: engine)
        }
    }

    /// A transcript segment always renders as "[m:ss] …" — our own format, so the
    /// bracket is a contract, not a guess. A transcript-less meeting has no such line
    /// (its body is the italic apology), and counting lines instead mis-skips a short
    /// real meeting whose transcript is a single segment (found live: 16s recording).
    static func hasTranscript(_ md: String) -> Bool {
        md.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // The digit check is what keeps a stray "[link](x)" out of the count.
            return t.first == "[" && t.dropFirst().first?.isNumber == true
        }
    }

    /// The agent must not spend a turn on `mkdir`, so the vault skeleton is here before
    /// it starts. The hub note stays its job: that one has content.
    private func ensureVaultDirectories(in notesFolder: URL, engine: SummaryEngineKind) {
        let vault = notesFolder.appendingPathComponent(SummaryVault.subdirectory, isDirectory: true)
        let dirs = [
            SummaryVault.meetingsDir, SummaryVault.peopleDir,
            SummaryVault.projectsDir, SummaryVault.decisionsDir,
        ]
        for dir in dirs {
            do {
                try FileManager.default.createDirectory(
                    at: vault.appendingPathComponent(dir, isDirectory: true),
                    withIntermediateDirectories: true
                )
            } catch {
                // Logged, not fatal: the agent runs as the same user and may still
                // manage what we could not.
                log("warning: cannot create \(dir) in vault: \(error)", engine: engine)
            }
        }
    }

    // MARK: - Claude adapter

    /// - Returns: `nil` when the engine did its job, otherwise why we think it did not.
    private func runClaude(
        binary: URL, prompt: String, meetingMd: URL, notesFolder: URL, timeout: TimeInterval
    ) async -> String? {
        let arguments = [
            "-p",
            "--safe-mode",
            // --safe-mode alone still let the user's own plugins load (seen live), and
            // an MCP server in someone's config is a network egress and a tool surface
            // this run has no business with. With no --mcp-config of our own, "strict"
            // means exactly zero servers.
            "--strict-mcp-config",
            "--tools", "Read,Write,Edit,Grep,Glob",
            "--permission-mode", "dontAsk",
            "--allowedTools", "Read,Write,Edit,Grep,Glob",
            "--model", Self.claudeModel,
            "--effort", Self.claudeEffort,
            "--max-turns", String(Self.maxTurns),
            "--no-session-persistence",
            "--output-format", "json",
            // The transcript lives in the app's meetings folder, outside the vault the
            // run is chrooted to by its working directory.
            "--add-dir", meetingMd.deletingLastPathComponent().path,
            // `--` is the end-of-options marker; without it the variadic --add-dir eats
            // the prompt (found live, claude 2.1.220: the CLI then aborts with "Input
            // must be provided either through stdin or as a prompt argument").
            "--", prompt,
        ]

        guard
            let output = await ProcessRunner.run(
                binary,
                arguments: arguments,
                // A stray ANTHROPIC_API_KEY silently outranks the user's subscription in
                // `-p` mode: the run would bill their API account for work they believe
                // their Claude plan already covers. It is scrubbed, never overridden —
                // sezish supplies no key of its own and never will.
                extraEnv: ["ANTHROPIC_API_KEY": nil],
                currentDirectory: notesFolder,
                timeout: timeout
            )
        else { return "claude failed to launch" }

        if output.timedOut { return "timed out after \(Int(timeout))s" }
        guard output.exitCode == 0 else {
            return "exit \(output.exitCode): \(Self.tail(output.stderr))"
        }

        guard let envelope = Self.claudeResultEnvelope(output.stdout) else {
            // Exit 0 with an envelope we cannot read: the CLI's own verdict is that it
            // succeeded, and calling that a failure would re-run a finished summary
            // every time the JSON format shifts under us. Noted, trusted.
            log("warning: exit 0 but stdout was not the json envelope", engine: .claude)
            return nil
        }
        if envelope["is_error"] as? Bool == true {
            let detail = envelope["result"] as? String ?? output.stderr
            return "is_error: \(Self.tail(detail))"
        }
        return nil
    }

    /// Digs the verdict out of whatever `--output-format json` printed.
    ///
    /// claude 2.1.220 prints an ARRAY of events and puts the answer in the last one
    /// tagged `"type": "result"`; the documented shape is that object on its own. Both
    /// are accepted, because the CLI updates itself behind our back and a format bump
    /// must not start reporting finished summaries as failures.
    private static func claudeResultEnvelope(_ stdout: String) -> [String: Any]? {
        guard
            let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let object = json as? [String: Any] { return object }
        guard let events = json as? [Any] else { return nil }
        let objects = events.compactMap { $0 as? [String: Any] }
        // Last, not first: a stream replays everything that happened, and only the tail
        // knows how it ended. The plain-last fallback covers a rename of the tag.
        return objects.last { $0["type"] as? String == "result" } ?? objects.last
    }

    // MARK: - Codex adapter

    private func runCodex(
        binary: URL, prompt: String, notesFolder: URL, timeout: TimeInterval
    ) async -> String? {
        let lastMessage = FileManager.default.temporaryDirectory
            .appendingPathComponent("sezish-summary-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessage) }

        let arguments = [
            "exec",
            "--sandbox", "workspace-write",
            "--cd", notesFolder.path,
            // The vault is a notes folder, not a checkout; codex refuses to touch an
            // unversioned directory otherwise.
            "--skip-git-repo-check",
            // No session files: this is a one-shot batch job, not a conversation the
            // user will resume.
            "--ephemeral",
            // The quotes are part of the value: codex parses it as TOML, where a quoted
            // string is unambiguous in every version (the bare-word fallback is only a
            // fallback). Everything the summary needs is on disk.
            "-c", "web_search=\"disabled\"",
            "-m", Self.codexModel,
            "-c", "model_reasoning_effort=\"\(Self.codexEffort)\"",
            "--output-last-message", lastMessage.path,
            prompt,
        ]

        guard
            let output = await ProcessRunner.run(
                binary,
                arguments: arguments,
                // Only OUR install reads OUR home; a codex the user installed keeps its
                // own `~/.codex`, or it would suddenly look logged out to them. Suffix
                // rule duplicated from EngineLocator — keep the two in sync.
                extraEnv: Self.isPrivateInstall(binary) ? ["CODEX_HOME": codexHome.path] : [:],
                timeout: timeout
            )
        else { return "codex failed to launch" }

        if output.timedOut { return "timed out after \(Int(timeout))s" }
        guard output.exitCode == 0 else {
            return "exit \(output.exitCode): \(Self.tail(output.stderr))"
        }

        // codex's exit codes are undocumented and it happily exits 0 on runs that did
        // nothing, so the last-message file is the reliable signal: no final message,
        // no work.
        let last = (try? String(contentsOf: lastMessage, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !last.isEmpty else {
            return "no final message from codex: \(Self.tail(output.stderr))"
        }
        return nil
    }

    /// The tail that marks our own codex install, copied from
    /// `EngineLocator.privateInstallTail` because that one is private and this file may
    /// not touch EngineLocator.swift. Two places, one rule — change both together.
    private static let privateInstallTail = ["sezish", "bin", "codex"]

    private static func isPrivateInstall(_ binary: URL) -> Bool {
        binary.standardizedFileURL.pathComponents.suffix(3).elementsEqual(privateInstallTail)
    }

    // MARK: - Log

    /// Appends one timestamped line, same shape as the Windows port's `obs.rs`:
    /// `[<unix-ts>] summary <engine>: <message>`. Best-effort from top to bottom — a
    /// summary must never fail because its log could not be written.
    private func log(_ message: String, engine: SummaryEngineKind) {
        let line = "[\(Int(Date().timeIntervalSince1970))] summary \(engine.rawValue): \(message)\n"
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    /// Logs and packages the one thing the caller does with a failure.
    private func failure(_ reason: String, engine: SummaryEngineKind) -> SummaryOutcome {
        log("failed: \(reason)", engine: engine)
        return .failed(reason)
    }

    /// Enough of the CLI's complaint to recognise it, not enough to bloat the log: a
    /// crashing node process can print megabytes of stack.
    private static func tail(_ text: String, limit: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "…\(trimmed.suffix(limit))" : trimmed
    }
}
