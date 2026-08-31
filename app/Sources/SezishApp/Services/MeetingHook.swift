import Foundation

/// Fire-and-forget bridge to whatever comes after a meeting: the configured
/// shell command gets the finished .md path as "$0".
///
/// The hook fires only AFTER all artifacts are on disk, so the command always
/// sees a complete meeting (the audio sits next to the .md under the same base
/// name). Whatever the command then does — and whatever it fails at — is the
/// user's script's business, not the recorder's: nothing is awaited, nothing is
/// reported back, and a broken hook can never fail a recording.
nonisolated enum MeetingHook {
    static func fire(command: String?, mdURL: URL) {
        guard let command else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path travels as "$0" rather than being spliced into the string:
        // meeting file names contain spaces, and a user's command must not have
        // to quote them itself.
        task.arguments = ["-c", "\(command) \"$0\"", mdURL.path]
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data("meetingHook failed to launch: \(error)\n".utf8))
        }
    }
}
