import Foundation

/// What one install attempt produced.
///
/// `nonisolated` for the same reason as `EngineStatus`: the app target defaults to
/// MainActor isolation, which would otherwise isolate the synthesized `Equatable`
/// too and put it out of reach of the install task running off-main.
nonisolated enum InstallOutcome: Equatable, Sendable {
    case installed
    /// Short reason, already shown in the install log.
    case failed(String)
}

/// Puts a summary CLI on the machine for a user who does not have one, without
/// ever asking them to open a terminal.
///
/// The two engines get deliberately different treatment, because their vendors
/// ship them differently:
///
/// - Claude Code has an official one-line installer that lands a signed and
///   notarized native binary in `~/.local/bin` (no Node, no npm) and keeps itself
///   updated from then on. We run *theirs*: a home-grown unpack would be a second,
///   worse installer that Anthropic never tests against.
/// - codex has no such script, so we fetch one PINNED GitHub release asset. The pin
///   is not distrust of GitHub — it is the only way the build we tested is the build
///   the user gets. The tarball is a self-contained Rust binary with nothing to
///   configure and no runtime to drag along.
///
/// Nothing here ever touches an install the user already has: codex lands in our own
/// `Application Support/sezish/bin` with its own home, which is exactly the
/// "private install" `EngineLocator` and `SummaryRunner` recognise by path suffix.
nonisolated struct EngineInstaller {
    private let binDir: URL
    private let codexHome: URL
    private let codexTarballURL: URL

    /// - Parameters:
    ///   - binDir: where our own codex binary lands. Tests point it at a temp dir.
    ///   - codexHome: `CODEX_HOME` for that private install. Same default as
    ///     `EngineLocator`, or the two would disagree about where the login lives.
    ///   - codexTarballURL: the release asset to unpack. A `file://` URL works too,
    ///     which is how the install path is tested without a network.
    init(binDir: URL? = nil, codexHome: URL? = nil, codexTarballURL: URL? = nil) {
        self.binDir = binDir ?? Self.defaultBinDir
        self.codexHome = codexHome ?? EngineLocator.defaultCodexHome
        self.codexTarballURL = codexTarballURL ?? Self.defaultCodexTarballURL
    }

    // MARK: - Defaults

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The exact directory `EngineLocator.defaultCodexCandidates` already probes —
    /// installing anywhere else would leave a binary nothing looks for.
    static var defaultBinDir: URL {
        applicationSupport.appendingPathComponent("sezish/bin", isDirectory: true)
    }

    /// Pinned release, aarch64 only: sezish ships arm64 and its Sparkle feed declares
    /// `hardwareRequirements` arm64, so an x86_64 asset could never be the right one
    /// to fetch on a machine that can run us.
    static let defaultCodexTarballURL = URL(
        string: "https://github.com/openai/codex/releases/download/rust-v0.146.0/"
            + "codex-aarch64-apple-darwin.tar.gz"
    )!

    /// Ten minutes: the Claude installer downloads a ~50 MB binary over whatever
    /// connection the user has, and a hotel wifi is slow, not broken.
    private static let installTimeout: TimeInterval = 600
    private static let unpackTimeout: TimeInterval = 120
    /// `--version` on a binary that already lives on the machine costs milliseconds,
    /// which is why `EngineLocator` probes it at 3s. This one is the FIRST exec of a
    /// file that appeared a moment ago: macOS scans it before letting it run, the
    /// scans serialize machine-wide, and a 40 MB Rust binary is the expensive end of
    /// that. Same cost the fixture warmup in `EngineLocatorTests` exists to pay
    /// outside a timed window — here there is nowhere to move it to, so the ceiling
    /// has to be the generous one.
    private static let versionTimeout: TimeInterval = 15

    // MARK: - Claude

    /// The official installer line from Anthropic's docs, verbatim. Kept as a
    /// constant rather than inlined so a test can guard it: the day this string
    /// drifts is the day we start piping something unreviewed into `bash`.
    static let claudeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// Runs Anthropic's installer and confirms a binary actually appeared.
    ///
    /// `ProcessRunner` buffers, so there is no line-by-line stream to forward: the
    /// UI log gets a "starting" line and the tail of whatever the installer said.
    /// That is enough to tell a stall from a failure, and a real progress bar would
    /// mean re-implementing the process plumbing for a job that runs once.
    func installClaude(progress: @escaping @Sendable (String) -> Void) async -> InstallOutcome {
        progress("installing claude code…")

        // A login shell (`-l`): the installer writes to `~/.local/bin` and expects
        // the user's own profile, the same environment they would have typed this in.
        guard
            let output = await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-lc", Self.claudeInstallCommand],
                timeout: Self.installTimeout
            )
        else { return .failed("cannot launch /bin/bash") }

        if output.timedOut {
            return .failed("the installer timed out after \(Int(Self.installTimeout))s")
        }

        let said = Self.tail(output.stdout.isEmpty ? output.stderr : output.stdout)
        if !said.isEmpty { progress(said) }

        guard output.exitCode == 0 else {
            return .failed("the installer exited \(output.exitCode): \(Self.tail(output.stderr))")
        }
        // Exit 0 is the installer's opinion; a binary on a path we search is the fact.
        // Without this re-probe a "successful" install could still leave the engine
        // undetectable, and the user would be told to log into something absent.
        guard EngineLocator().binaryURL(of: .claude) != nil else {
            return .failed("the installer finished but left no claude binary we can find")
        }

        progress("claude code installed")
        return .installed
    }

    // MARK: - Codex

    /// The one setting our private codex home must carry.
    ///
    /// Without it codex writes the ChatGPT tokens to a plaintext `auth.json` inside
    /// this folder; with it they go to the macOS Keychain, where the rest of the
    /// user's credentials already live.
    static let codexConfigContents = """
        # Written by sezish. Keep the ChatGPT tokens in the macOS Keychain instead of
        # a plaintext auth.json next to this file.
        cli_auth_credentials_store = "keyring"
        """

    /// Downloads, unpacks, installs and verifies the pinned codex release.
    ///
    /// Every step can fail on somebody else's terms — no network, a truncated
    /// tarball, a read-only directory — so each one answers with a reason instead of
    /// throwing, and the staging directory is removed either way.
    func installCodex(progress: @escaping @Sendable (String) -> Void) async -> InstallOutcome {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sezish-codex-\(UUID().uuidString)", isDirectory: true)
        // Best-effort cleanup on every exit path, including the failures.
        defer { try? FileManager.default.removeItem(at: staging) }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        } catch {
            return .failed("cannot create a staging directory: \(error.localizedDescription)")
        }

        progress("downloading codex…")
        let tarball = staging.appendingPathComponent("codex.tar.gz")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: codexTarballURL)
            // A 404 from a moved release would otherwise be unpacked as if it were the
            // asset. Only checked when there IS an HTTP response: a file:// download
            // has none.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed("download failed: HTTP \(http.statusCode)")
            }
            // Moved out of URLSession's temp slot at once — that file is the session's
            // to delete the moment this call returns.
            try FileManager.default.moveItem(at: downloaded, to: tarball)
        } catch {
            return .failed("download failed: \(error.localizedDescription)")
        }

        progress("unpacking…")
        guard
            let tar = await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", tarball.path, "-C", unpacked.path],
                timeout: Self.unpackTimeout
            )
        else { return .failed("cannot launch /usr/bin/tar") }

        if tar.timedOut { return .failed("unpacking timed out") }
        guard tar.exitCode == 0 else {
            return .failed("tar exited \(tar.exitCode): \(Self.tail(tar.stderr))")
        }

        // The archive holds a single entry named after the target triple, so the name
        // is not worth matching on: whatever regular file came out IS the binary, and
        // it gets our name rather than theirs.
        guard let unpackedBinary = Self.firstRegularFile(in: unpacked) else {
            return .failed("the archive contained no binary")
        }

        let destination = binDir.appendingPathComponent("codex")
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            // `moveItem` refuses an occupied destination, and an occupied destination
            // is the normal case: re-installing over an older build.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: unpackedBinary, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path
            )
        } catch {
            return .failed("cannot install the binary: \(error.localizedDescription)")
        }

        if let reason = writeCodexConfigIfMissing() { return .failed(reason) }

        progress("verifying…")
        guard let version = await verifyCodex(at: destination) else {
            return .failed("the installed codex did not answer --version")
        }

        progress("codex \(version) installed")
        return .installed
    }

    /// - Returns: why it could not be written, or `nil` when the file is in place.
    private func writeCodexConfigIfMissing() -> String? {
        do {
            try FileManager.default.createDirectory(
                at: codexHome, withIntermediateDirectories: true
            )
        } catch {
            return "cannot create the codex home: \(error.localizedDescription)"
        }

        // Never overwritten. By the time a second install runs, this file may carry a
        // finished login's settings and whatever else the user put there — a fresh
        // copy would silently throw that away.
        let config = codexHome.appendingPathComponent("config.toml")
        guard !FileManager.default.fileExists(atPath: config.path) else { return nil }

        do {
            try (Self.codexConfigContents + "\n")
                .write(to: config, atomically: true, encoding: .utf8)
        } catch {
            return "cannot write config.toml: \(error.localizedDescription)"
        }
        return nil
    }

    /// The install is only done when the binary identifies itself: a truncated
    /// download unpacks fine and fails at exec.
    private func verifyCodex(at binary: URL) async -> String? {
        guard
            let output = await ProcessRunner.run(
                binary,
                arguments: ["--version"],
                // Our install reads our home — the same rule `EngineLocator` and
                // `SummaryRunner` apply, so even this probe cannot create a stray
                // `~/.codex` behind the user's back.
                extraEnv: ["CODEX_HOME": codexHome.path],
                timeout: Self.versionTimeout
            ), !output.timedOut
        else { return nil }
        return EngineLocator.parseCodexVersion(output.stdout)
    }

    /// Depth-first so a tarball that wraps its payload in a directory still works.
    private static func firstRegularFile(in directory: URL) -> URL? {
        guard
            let entries = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }

        for case let url as URL in entries {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { return url }
        }
        return nil
    }

    /// Enough of the tool's own words to recognise the failure, not enough to fill
    /// the UI log with a download progress bar's worth of carriage returns.
    private static func tail(_ text: String, limit: Int = 300) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "…\(trimmed.suffix(limit))" : trimmed
    }
}
