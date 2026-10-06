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
///
/// The second half holds the stop (incident 06.10.2026): a capture that never comes
/// back from its stop can no longer hang the app, the take is kept with what reached
/// the disk, late deliveries of a dead capture go nowhere, and a recorder whose
/// capture had to be abandoned refuses to start another one.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MeetingRecorderTests {
    /// What the factory was handed. A class because the factory is `@Sendable` and the
    /// test reads the value back after the recorder ran.
    private final class HandedOver: @unchecked Sendable {
        var deviceID: AudioDeviceID?
        var seen = false
        var micSamples: (@Sendable ([Float]) -> Void)?
        var micBuilds = 0
    }

    /// Every test gets its own meetings directory: a leftover `.rec-` spool in the real
    /// one would come back as a "recovered meeting" on the next launch.
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spoolDirectories(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(".rec-") }
    }

    private func frames(_ capture: MeetingRecorder.Capture, _ stem: String) throws -> Int {
        try PCMSpoolReader(url: capture.tempDir.appendingPathComponent(stem)).frameCount
    }

    /// A recorder on fakes for both tracks; `system` decides how the system stop ends.
    private func makeRecorder(
        dir: URL, watchdog: ManualWatchdog, handedOver: HandedOver = HandedOver(),
        mic: @escaping @Sendable () -> FakeMeetingMic = { FakeMeetingMic() },
        systems: SystemCaptures = SystemCaptures(),
        systemResult: CaptureStopResult = .stopped
    ) -> MeetingRecorder {
        MeetingRecorder(
            meetingsDir: dir,
            makeMic: { deviceID, onSamples in
                handedOver.deviceID = deviceID
                handedOver.seen = true
                handedOver.micSamples = onSamples
                handedOver.micBuilds += 1
                return mic()
            },
            makeSystem: { onSamples in
                let capture = FakeSystemCapture(result: systemResult, onSamples: onSamples)
                systems.add(capture)
                return capture
            },
            stopTimeout: 5,
            watchdog: watchdog.schedule
        )
    }

    /// The whole feature in one assertion: the device the call app listens to is what
    /// the mic is built for. Off by one line (`makeMic(nil)`), the meeting records the
    /// engine's default and nothing in the app can tell.
    @Test func theCallAppDeviceReachesTheMic() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handedOver = HandedOver()
        let recorder = makeRecorder(dir: dir, watchdog: ManualWatchdog(), handedOver: handedOver)

        _ = try recorder.start(coverage: .global, device: 42)
        #expect(handedOver.seen)
        #expect(handedOver.deviceID == 42)
        _ = try await recorder.stop()
    }

    /// A mic that cannot start fails the start with its own cause and takes the spool
    /// directory with it: a half-written take nobody can identify must not survive.
    @Test func aMicThatRefusesToStartLeavesNothingBehind() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = makeRecorder(
            dir: dir, watchdog: ManualWatchdog(), mic: { FakeMeetingMic(refuses: true) })

        #expect(throws: FakeMeetingMic.Refused.self) {
            try recorder.start(coverage: .global, device: 42)
        }
        #expect(spoolDirectories(in: dir).isEmpty)
    }

    /// The ordinary stop is unchanged: each capture is stopped exactly once, both under
    /// the owner's 5 s watchdog, and the capture reports what each stem holds.
    @Test func aNormalStopStopsEachCaptureOnceAndCountsTheFrames() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watchdog = ManualWatchdog()
        let handedOver = HandedOver()
        let mic = FakeMeetingMic()
        let systems = SystemCaptures()
        let recorder = makeRecorder(
            dir: dir, watchdog: watchdog, handedOver: handedOver, mic: { mic },
            systems: systems)

        _ = try recorder.start(coverage: .global, device: nil)
        handedOver.micSamples?(loudTone(frames: 8_000))
        systems.all.first?.onSamples(loudTone(frames: 4_800))
        let capture = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: capture.tempDir) }

        #expect(mic.stops == 1)
        #expect(systems.all.map(\.stops) == [1])
        #expect(watchdog.scheduledTimeouts == [5])
        #expect(capture.integrity.micFrames == 8_000)
        #expect(capture.integrity.systemFrames == 4_800)
        #expect(!capture.integrity.abandoned)
        #expect(!capture.integrity.systemLost)
        #expect(try frames(capture, "mic.wav") == 8_000)
        #expect(try frames(capture, "system.wav") == 4_800)
        #expect(!recorder.captureBroken)
        #expect(!recorder.isRecording)
    }

    /// `AudioDeviceStop` stuck on the HAL mutex: the stop returns when the watchdog
    /// fires, the take carries the abandoned flag, and both spools are finalized.
    @Test func theStopReturnsWhenTheSystemCaptureHangs() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watchdog = ManualWatchdog()
        let backend = FakeTapBackend()
        let stuck = Hold()
        defer { stuck.release() }
        let recorder = MeetingRecorder(
            meetingsDir: dir,
            makeMic: { _, _ in FakeMeetingMic() },
            makeSystem: { onSamples in
                SystemAudioTap(backend: backend, watchdog: watchdog.schedule, onSamples16k: onSamples)
            },
            stopTimeout: 5,
            watchdog: watchdog.schedule
        )

        _ = try recorder.start(coverage: .global, device: nil)
        backend.holdStops = stuck
        let stop = Task { try await recorder.stop() }
        await watchdog.waitForScheduled(2)
        watchdog.fireAll()
        let capture = try await stop.value

        #expect(watchdog.scheduledTimeouts == [5, 5])
        #expect(capture.integrity.systemAbandoned)
        #expect(!capture.integrity.micAbandoned)
        #expect(!recorder.isRecording)
        #expect(try frames(capture, "mic.wav") == 0)
        #expect(try frames(capture, "system.wav") == 0)
    }

    /// While the stop waits on a capture that hangs, the main actor keeps running: the
    /// old stop held it inside `queue.sync` forever.
    @Test func aHangingStopDoesNotBlockTheMainActor() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watchdog = ManualWatchdog()
        let stuck = Hold()
        defer { stuck.release() }
        let recorder = makeRecorder(
            dir: dir, watchdog: watchdog, mic: { FakeMeetingMic(stopHold: stuck) })

        _ = try recorder.start(coverage: .global, device: nil)
        let stop = Task { try await recorder.stop() }
        await watchdog.waitForScheduled(1)
        let mainActorRan = await Task { @MainActor in true }.value
        #expect(mainActorRan)
        watchdog.fireAll()
        _ = try await stop.value
    }

    /// The microphone's stop hangs (AVAudioEngine on a broken HAL): the watchdog ends
    /// it the same way, and the take says the mic was abandoned.
    @Test func theStopReturnsWhenTheMicHangs() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watchdog = ManualWatchdog()
        let stuck = Hold()
        defer { stuck.release() }
        let recorder = makeRecorder(
            dir: dir, watchdog: watchdog, mic: { FakeMeetingMic(stopHold: stuck) })

        _ = try recorder.start(coverage: .global, device: nil)
        let stop = Task { try await recorder.stop() }
        await watchdog.waitForScheduled(1)
        watchdog.fireAll()
        let capture = try await stop.value
        defer { try? FileManager.default.removeItem(at: capture.tempDir) }

        #expect(capture.integrity.micAbandoned)
        #expect(!capture.integrity.systemAbandoned)
        #expect(recorder.captureBroken)
    }

    /// An abandoned capture that comes back to life delivers into a closed gate: the
    /// finalized stem does not grow.
    @Test func lateSamplesAfterAnAbandonedStopAreDropped() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let systems = SystemCaptures()
        let recorder = makeRecorder(
            dir: dir, watchdog: ManualWatchdog(), systems: systems, systemResult: .abandoned)

        _ = try recorder.start(coverage: .global, device: nil)
        let system = try #require(systems.all.first)
        system.onSamples(loudTone(frames: 16_000))
        let capture = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: capture.tempDir) }
        system.onSamples(loudTone(frames: 32_000))

        #expect(capture.integrity.systemAbandoned)
        #expect(capture.integrity.systemFrames == 16_000)
        #expect(try frames(capture, "system.wav") == 16_000)
    }

    /// The loudness signals outlive every recording, so a stopped capture that still
    /// delivers must not reach them: otherwise the next take's silence clock would
    /// read a dead call's audio as speech.
    @Test func lateSamplesFromAStoppedCaptureNeverReachTheNextTake() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let systems = SystemCaptures()
        let recorder = makeRecorder(dir: dir, watchdog: ManualWatchdog(), systems: systems)

        _ = try recorder.start(coverage: .global, device: nil)
        let first = try await recorder.stop()
        try? FileManager.default.removeItem(at: first.tempDir)

        _ = try recorder.start(coverage: .global, device: nil)
        try #require(systems.all.count == 2)
        systems.all[0].onSamples(loudTone(frames: 3_200))
        #expect(recorder.loudness(at: Date()).system == false)
        // The live capture still counts: the gate shuts only the old one.
        systems.all[1].onSamples(loudTone(frames: 3_200))
        #expect(recorder.loudness(at: Date()).system == true)

        let second = try await recorder.stop()
        try? FileManager.default.removeItem(at: second.tempDir)
    }

    /// Owner decision D3: once a capture had to be abandoned, CoreAudio in this process
    /// is not trusted until the app restarts. The next start refuses at once, before a
    /// single CoreAudio call, so it can neither hang the main thread nor pile up taps.
    @Test func aStartIsRefusedAfterAnAbandonedStop() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handedOver = HandedOver()
        let systems = SystemCaptures()
        let recorder = makeRecorder(
            dir: dir, watchdog: ManualWatchdog(), handedOver: handedOver, systems: systems,
            systemResult: .abandoned)

        _ = try recorder.start(coverage: .global, device: nil)
        let capture = try await recorder.stop()
        try? FileManager.default.removeItem(at: capture.tempDir)
        #expect(recorder.captureBroken)

        #expect(throws: MeetingRecorder.MeetingRecorderError.captureBroken) {
            try recorder.start(coverage: .global, device: nil)
        }
        #expect(handedOver.micBuilds == 1)
        #expect(systems.all.count == 1)
        #expect(spoolDirectories(in: dir).isEmpty)
        #expect(!recorder.isRecording)
    }

    /// A system track a device change left without an aggregate reaches the take.
    @Test func aLostSystemTrackReachesTheTake() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder(
            meetingsDir: dir,
            makeMic: { _, _ in FakeMeetingMic() },
            makeSystem: { FakeSystemCapture(lost: true, onSamples: $0) },
            stopTimeout: 5,
            watchdog: ManualWatchdog().schedule
        )

        _ = try recorder.start(coverage: .global, device: nil)
        let capture = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: capture.tempDir) }
        #expect(capture.integrity.systemLost)
        #expect(!recorder.captureBroken)
    }
}
