import AudioToolbox
import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The seam that decides which device a meeting's mic opens: the recorder hands the
/// device id to a factory, and only a test can see what reached it. *Which* device is
/// chosen belongs to `SezishCore` (`MeetingMicRoute`); what is held here is that the
/// choice survives the trip to the engine, and that a mic which refuses to start fails
/// the whole recording instead of recording something else.
@MainActor @Suite struct MeetingRecorderTests {
    /// Stands in for a running mic and refuses to start on demand.
    private final class FakeMic: MicCapture, @unchecked Sendable {
        private let refuses: Bool

        init(refuses: Bool = false) {
            self.refuses = refuses
        }

        struct Refused: Error {}

        func start() throws {
            if refuses { throw Refused() }
        }

        func stop() async throws -> [Float] { [] }
    }

    /// What the factory was handed. A class because the factory is `@Sendable` and the
    /// test reads the value back after the recorder ran.
    private final class HandedOver: @unchecked Sendable {
        var deviceID: AudioDeviceID?
        var seen = false
    }

    /// Tests run against the real meetings directory (the recorder has no seam for it),
    /// so every one of them cleans up: a leftover `.rec-` spool would come back as a
    /// "recovered meeting" on the next launch.
    private func spoolDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: MeetingRecorder.meetingsDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix(".rec-") })
    }

    private func removeSpools(notIn before: Set<String>) {
        for name in spoolDirectories().subtracting(before) {
            try? FileManager.default.removeItem(
                at: MeetingRecorder.meetingsDirectory.appendingPathComponent(name)
            )
        }
    }

    /// The whole feature in one assertion: the device the call app listens to is what
    /// the mic is built for. Off by one line (`makeMic(nil)`), the meeting records the
    /// engine's default and nothing in the app can tell.
    @Test func theCallAppDeviceReachesTheMic() async throws {
        let before = spoolDirectories()
        defer { removeSpools(notIn: before) }
        let handedOver = HandedOver()
        let recorder = MeetingRecorder { deviceID, _ in
            handedOver.deviceID = deviceID
            handedOver.seen = true
            return FakeMic()
        }

        _ = try recorder.start(coverage: .global, device: 42)
        #expect(handedOver.seen)
        #expect(handedOver.deviceID == 42)
        _ = try await recorder.stop()
    }

    /// A mic that cannot start fails the start with its own cause and takes the spool
    /// directory with it: a half-written take nobody can identify must not survive.
    @Test func aMicThatRefusesToStartLeavesNothingBehind() async throws {
        let before = spoolDirectories()
        defer { removeSpools(notIn: before) }
        let recorder = MeetingRecorder { _, _ in FakeMic(refuses: true) }

        #expect(throws: FakeMic.Refused.self) {
            try recorder.start(coverage: .global, device: 42)
        }
        #expect(spoolDirectories() == before)
    }
}
