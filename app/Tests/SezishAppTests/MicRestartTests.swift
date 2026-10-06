import AudioToolbox
import Foundation
import Testing

@testable import SezishApp

/// The meeting mic after a device change (owner decision D1, incident 06.10.2026):
/// `AVAudioEngine` stopped itself on `AVAudioEngineConfigurationChange` 3 s into the
/// meeting and nothing restarted it, so the take had no voice of its own. These tests
/// hold the restart against a fake engine: one restart per burst of changes, on the
/// same pinned device, never after a stop, never feeding buffers of a replaced
/// engine, and never in dictation.
@Suite(.timeLimit(.minutes(1))) struct MicRestartTests {
    private let device: AudioDeviceID = 827

    private func meetingMic(
        _ backend: FakeMicBackend, scheduler: ManualMicScheduler,
        clock: ManualClock = ManualClock(), delivered: Delivered = Delivered(),
        device: AudioDeviceID? = 827
    ) -> MicRecorder {
        MicRecorder(
            deviceID: device,
            onSamples16k: delivered.sink,
            restartsOnConfigurationChange: true,
            backend: backend,
            scheduler: scheduler.schedule,
            now: clock.now
        )
    }

    /// Waits until everything already queued on the recorder's control queue has run.
    private func drain(_ mic: MicRecorder) {
        mic.controlQueue.sync {}
    }

    /// A storm of configuration changes (the incident had 157 output changes in 48 s)
    /// coalesces into one restart, and only once the settle window has passed.
    @Test func aStormOfChangesRestartsOnceAfterTheWindow() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()
        let first = try #require(backend.engines.first)
        #expect(first.observed)

        first.stopBySystem()
        for _ in 0..<25 { first.fireConfigurationChange() }
        drain(mic)

        #expect(scheduler.delays == [MicRecorder.restartSettleWindow])
        #expect(backend.engines.count == 1)
        #expect(!first.retired)

        scheduler.fireAll()

        #expect(backend.engines.count == 2)
        #expect(first.retired)
        #expect(scheduler.pendingCount == 0)
        let second = backend.engines[1]
        #expect(second.isRunning)
    }

    /// The restart opens the device the meeting was pinned to (the engine itself had
    /// moved the input onto `CADefaultDeviceAggregate`), and reads the input format
    /// only after the pin: the format follows the device (24 kHz became 48 kHz in the
    /// incident), so a converter built before the pin would be wrong.
    @Test func theRestartPinsTheSameDeviceBeforeTheFormatIsRead() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()
        let first = backend.engines[0]

        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)
        scheduler.fireAll()

        let second = try #require(backend.engines.last)
        #expect(backend.engines.count == 2)
        #expect(second.calls == ["observe", "pin \(device)", "tap", "start"])
        #expect(first.calls.last == "retire")
    }

    /// The pinned device is gone: the mic is never quietly moved to another input (that
    /// would record the room instead of the call). The check is tried again later, and
    /// the device coming back gets its restart.
    @Test func aGonePinnedDeviceIsNeverSwappedForAnother() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()
        let first = backend.engines[0]

        backend.deviceAlive = false
        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)
        scheduler.fireAll()

        #expect(backend.engines.count == 1)
        #expect(scheduler.delays == [MicRecorder.restartSettleWindow, MicRecorder.restartSpacing])

        backend.deviceAlive = true
        scheduler.fireAll()

        #expect(backend.engines.count == 2)
        #expect(backend.engines[1].pins == ["pin \(device)"])
        #expect(backend.engines[1].isRunning)
    }

    /// A stop that lands while a restart is waiting out its window: the restart never
    /// runs, no engine is built after the stop.
    @Test func aStopBeforeThePendingRestartKeepsTheMicDead() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()
        let first = backend.engines[0]

        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)
        mic.stopSynchronously()
        #expect(first.retired)

        scheduler.fireAll()

        #expect(backend.engines.count == 1)
        #expect(scheduler.pendingCount == 0)
    }

    /// A stop that lands while a restart is in the middle of building its engine: the
    /// new engine is never started, and the stop retires it.
    @Test func aStopDuringARestartInFlightNeverStartsTheNewEngine() async throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let pin = Hold()
        backend.holdPin(ofEngine: 1, on: pin)
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()
        let first = backend.engines[0]

        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)
        DispatchQueue.global().async { scheduler.fireAll() }
        pin.waitUntilParked()

        let stop = Task.detached { mic.stopSynchronously() }
        while !mic.isStopping { await Task.yield() }
        pin.release()
        await stop.value

        #expect(backend.engines.count == 2)
        let second = backend.engines[1]
        #expect(second.starts == 0)
        #expect(second.retired)
        #expect(!second.isRunning)
    }

    /// A buffer the replaced engine still had in flight is dropped: only the current
    /// engine feeds the take, so no stretch of audio is written twice or out of order.
    @Test func buffersOfAReplacedEngineAreDropped() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let delivered = Delivered()
        let mic = meetingMic(backend, scheduler: scheduler, delivered: delivered)
        try mic.start()
        let first = backend.engines[0]
        first.play([1])
        let lateFromFirst = try #require(first.keptDelivery())

        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)
        scheduler.fireAll()
        lateFromFirst([2])
        backend.engines[1].play([3])

        #expect(delivered.all == [[1], [3]])
    }

    /// Restarts are spaced out: a change shortly after a restart waits for the spacing
    /// instead of the plain window, so a device that keeps flapping cannot make the
    /// engine churn.
    @Test func restartsAreSpacedOut() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let clock = ManualClock()
        let mic = meetingMic(backend, scheduler: scheduler, clock: clock)
        try mic.start()

        backend.engines[0].stopBySystem()
        backend.engines[0].fireConfigurationChange()
        drain(mic)
        scheduler.fireAll()
        #expect(backend.engines.count == 2)

        clock.advance(0.2)
        backend.engines[1].stopBySystem()
        backend.engines[1].fireConfigurationChange()
        drain(mic)

        let delay = try #require(scheduler.delays.last)
        #expect(abs(delay - (MicRecorder.restartSpacing - 0.2)) < 0.000_1)
        #expect(MicRecorder.restartSpacing > MicRecorder.restartSettleWindow)
    }

    /// A configuration change the engine lived through (it is still running when the
    /// window has passed) needs no restart.
    @Test func anEngineStillRunningIsLeftAlone() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()

        backend.engines[0].fireConfigurationChange()
        drain(mic)
        scheduler.fireAll()

        #expect(backend.engines.count == 1)
        #expect(!backend.engines[0].retired)
    }

    /// A restart CoreAudio refuses is tried again, spaced out, a bounded number of
    /// times, and then given up instead of looping for the rest of the meeting.
    @Test func aRefusedRestartIsRetriedABoundedNumberOfTimes() throws {
        let backend = FakeMicBackend()
        backend.failStarts(fromEngine: 1)
        let scheduler = ManualMicScheduler()
        let mic = meetingMic(backend, scheduler: scheduler)
        try mic.start()

        backend.engines[0].stopBySystem()
        backend.engines[0].fireConfigurationChange()
        drain(mic)
        for _ in 0..<(MicRecorder.restartAttemptLimit + 3) { scheduler.fireAll() }

        #expect(backend.engines.count == 1 + MicRecorder.restartAttemptLimit)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.delays.dropFirst().allSatisfy { $0 == MicRecorder.restartSpacing })
    }

    /// Dictation keeps its engine exactly as before: no observer, so a configuration
    /// change has nothing to restart.
    @Test func dictationNeverRestarts() throws {
        let backend = FakeMicBackend()
        let scheduler = ManualMicScheduler()
        let mic = MicRecorder(backend: backend, scheduler: scheduler.schedule)
        try mic.start()
        let first = try #require(backend.engines.first)

        #expect(!first.observed)
        #expect(!first.calls.contains("observe"))
        first.stopBySystem()
        first.fireConfigurationChange()
        drain(mic)

        #expect(scheduler.delays.isEmpty)
        #expect(backend.engines.count == 1)
    }

    /// Who gets the restart: the meeting mic is built with it, every dictation mic
    /// (the way `AppStateModel` builds them) without.
    @Test func onlyTheMeetingMicIsBuiltToRestart() {
        let meeting = MeetingRecorder.engineMic(deviceID: device, onSamples16k: { _ in })
        #expect((meeting as? MicRecorder)?.restartsOnConfigurationChange == true)
        #expect(!MicRecorder(onLevel: { _ in }).restartsOnConfigurationChange)
        #expect(
            !MicRecorder(onLevel: { _ in }, onSamples16k: { _ in }, keepsBuffer: true)
                .restartsOnConfigurationChange
        )
    }
}
