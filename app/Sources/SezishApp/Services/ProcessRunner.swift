import Foundation

/// Runs a child process to completion under a hard wall-clock ceiling.
///
/// Everything sezish shells out to is somebody else's binary — a CLI the user
/// installed, upgraded and configured behind our back. Such a binary can decide
/// to prompt, to stall on a network call, or to wait forever on a stdin that will
/// never arrive, and whatever waits on it hangs with it. Hence the three rules
/// baked in here:
///
/// - stdin is closed the moment the child is up, so a CLI that would have
///   stopped to ask a question reads EOF and gets on with exiting;
/// - both output pipes are drained *concurrently with* the run, because a chatty
///   child that fills the 64 KB pipe buffer blocks in `write()` forever if the
///   reader only starts after the child exits — the classic deadlock;
/// - the timeout escalates SIGTERM → grace → SIGKILL, so "it timed out" always
///   means the process is actually gone, not merely given up on.
///
/// No PTY: nothing here needs a terminal, and a PTY would hand the child a way to
/// draw interactive prompts we cannot answer.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// How long a timed-out child gets to die politely. Long enough for a CLI to
    /// flush and unwind, short enough that a stuck probe stays a probe.
    private static let terminationGrace: TimeInterval = 2

    /// - Parameter extraEnv: merged over the current environment; a key mapped to
    ///   `nil` is REMOVED, which is how callers scrub an inherited secret.
    /// - Returns: `nil` only when the process could not be launched at all.
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        extraEnv: [String: String?] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) async -> Output? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.environment = environment(mergedWith: extraEnv)

        // Armed BEFORE the launch: a child can be dead before `run()` even
        // returns, and a handler installed after that would never fire.
        let exit = ExitLatch()
        process.terminationHandler = { _ in exit.signal() }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        // Our end of stdin goes away immediately: the child sees an empty, closed
        // input rather than an open pipe it could wait on.
        try? stdinPipe.fileHandleForWriting.close()

        let box = UncheckedBox(process)
        async let stdoutData = readToEnd(UncheckedBox(stdoutPipe.fileHandleForReading))
        async let stderrData = readToEnd(UncheckedBox(stderrPipe.fileHandleForReading))

        // The killer races the child. Whoever loses is harmless: a cancelled killer
        // never signals, and a killed child still trips the latch.
        let killer = Task<Bool, Never> { await enforceTimeout(box, timeout: timeout) }
        await exit.wait()
        killer.cancel()
        let timedOut = await killer.value

        return Output(
            exitCode: process.terminationStatus,
            stdout: String(decoding: await stdoutData, as: UTF8.self),
            stderr: String(decoding: await stderrData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private static func environment(mergedWith extraEnv: [String: String?]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv {
            if let value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }
        return env
    }

    /// Waits out the timeout and, if the child is still there, kills it.
    /// Returns whether it had to — that answer *is* `Output.timedOut`, which keeps
    /// the flag out of shared mutable state.
    private static func enforceTimeout(
        _ box: UncheckedBox<Process>, timeout: TimeInterval
    ) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(timeout))
        } catch {
            return false  // Cancelled: the child finished on its own terms.
        }
        guard box.value.isRunning else { return false }

        box.value.terminate()
        // Cancellation of this sleep means the child died from the SIGTERM, in
        // which case the `isRunning` check below skips the SIGKILL.
        try? await Task.sleep(for: .seconds(terminationGrace))
        if box.value.isRunning { kill(box.value.processIdentifier, SIGKILL) }
        return true
    }

    /// One-shot gate between `terminationHandler` (fires on a Foundation-owned
    /// thread, possibly before anyone waits) and the awaiting task.
    ///
    /// Deliberately NOT `Process.waitUntilExit()`: on Darwin that spins the
    /// *calling thread's* run loop, and a child that exits before the loop is
    /// registered loses the wake-up — the caller then blocks forever. Observed
    /// hanging a whole test run; the sample pointed straight at
    /// `-[NSConcreteTask waitUntilExit]` sitting in `mach_msg2_trap` with the
    /// child already reaped.
    private final class ExitLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var hasExited = false
        private var waiter: CheckedContinuation<Void, Never>?

        func signal() {
            lock.lock()
            hasExited = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasExited {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private static func readToEnd(_ box: UncheckedBox<FileHandle>) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? box.value.readToEnd()) ?? Data())
            }
        }
    }

    /// Foundation's process plumbing predates `Sendable`, but every call made
    /// through this box — `terminate`, `isRunning`, `processIdentifier`, and a
    /// blocking read on one pipe end owned by exactly one task — is safe off the
    /// main thread. Stating that once beats scattering `@unchecked` captures over
    /// the file.
    private final class UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
