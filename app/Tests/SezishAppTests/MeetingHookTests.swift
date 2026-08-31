import Foundation
import Testing
@testable import SezishApp

/// The hook is fire-and-forget, so its only observable contract is on disk:
/// a process ran and it was handed the .md path. Both tests poll rather than
/// wait on the Process, because `fire` deliberately keeps no handle to it.
@Suite struct MeetingHookTests {
    @Test func doesNothingWhenNoCommandIsConfigured() {
        // The overwhelmingly common case — no key in defaults, no process at all.
        MeetingHook.fire(
            command: nil, mdURL: URL(fileURLWithPath: "/tmp/sezish-no-such-meeting.md")
        )
    }

    @Test func handsTheMarkdownPathToTheCommand() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mdURL = dir.appendingPathComponent("meeting.md")
        try "hello".write(to: mdURL, atomically: true, encoding: .utf8)
        let sink = dir.appendingPathComponent("sink.txt")

        // `fire` appends the .md path as the command's last argument, so this runs
        // `cat <md> >> sink`: the sink holding the meeting's text proves the hook
        // received the real path (and that spaces in it would survive quoting).
        MeetingHook.fire(command: "cat >> '\(sink.path)'", mdURL: mdURL)

        var contents: String?
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            contents = try? String(contentsOf: sink, encoding: .utf8)
            if contents == "hello" { break }
        }
        #expect(contents == "hello")
    }
}
