import AudioToolbox
import Foundation
import SezishCore
import Testing

@testable import SezishApp

/// The system-audio tap's own threading, against a fake CoreAudio. The incident of
/// 06.10.2026: the HAL's IO thread held its mutex and dispatched the IOProc block
/// synchronously onto our queue, while the output-change listener on that same queue
/// sat in `AudioDeviceStop` waiting for the mutex. These tests hold the shape that
/// breaks that cycle and the stop that can no longer hang the app.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SystemAudioTapTests {
    private func makeTap(
        _ backend: FakeTapBackend, watchdog: ManualWatchdog = ManualWatchdog()
    ) -> SystemAudioTap {
        SystemAudioTap(backend: backend, watchdog: watchdog.schedule, onSamples16k: { _ in })
    }

    /// Waits until everything already queued on the tap's control queue has run.
    private func drainControl(_ tap: SystemAudioTap) {
        tap.controlQueue.sync {}
    }

    /// The structural half of the fix: the IOProc block goes on a queue of its own,
    /// never on the queue the listener (and with it `AudioDeviceStop`) runs on. Held
    /// for the first aggregate and for every rebuild after a device change.
    @Test func theIOProcNeverSharesTheListenersQueue() throws {
        let backend = FakeTapBackend()
        let tap = makeTap(backend)
        try tap.start(coverage: .global)

        backend.fireOutputChanges(2)
        drainControl(tap)

        #expect(backend.aggregatesStarted == 3)
        let listenerQueue = try #require(backend.listenerQueue)
        #expect(listenerQueue === tap.controlQueue)
        #expect(backend.ioQueues.count == 3)
        for ioQueue in backend.ioQueues {
            #expect(ioQueue !== listenerQueue)
            #expect(ioQueue === tap.ioQueue)
        }
        #expect(tap.ioQueue !== tap.controlQueue)
    }

    /// A stop that arrives in a storm of output changes: every listener block already
    /// queued ahead of it must become a no-op the moment the stop is asked for. Each
    /// rebuild took ~0.7 s in the incident, so a queue of them alone would outlast the
    /// 5 s watchdog and a healthy stop would be reported as abandoned.
    @Test func listenerBlocksQueuedBeforeAStopDoNothing() async throws {
        let backend = FakeTapBackend()
        let watchdog = ManualWatchdog()
        let tap = makeTap(backend, watchdog: watchdog)
        try tap.start(coverage: .global)

        let rebuild = Hold()
        backend.holdNextStart = rebuild
        backend.fireOutputChanges(10)
        rebuild.waitUntilParked()

        let stop = Task { await tap.stop(timeout: 5) }
        await watchdog.waitForScheduled(1)
        rebuild.release()
        let result = await stop.value

        #expect(result == .stopped)
        #expect(watchdog.scheduledTimeouts == [5])
        // The first aggregate plus the one rebuild that was already in flight; the
        // nine blocks behind it never touched CoreAudio.
        #expect(backend.aggregatesStarted == 2)
        #expect(backend.aggregatesStopped == 2)
        #expect(backend.tapsDestroyed == 1)
        #expect(backend.listenerRemoved)
    }

    /// `AudioDeviceStop` never comes back: the stop gives up when the watchdog fires,
    /// the tap is marked abandoned, and nothing on it can block a caller again.
    @Test func aStopThatHangsIsAbandonedAndTheTapStaysDead() async throws {
        let backend = FakeTapBackend()
        let watchdog = ManualWatchdog()
        let tap = makeTap(backend, watchdog: watchdog)
        try tap.start(coverage: .global)
        let stuck = Hold()
        backend.holdStops = stuck
        defer { stuck.release() }

        let stop = Task { await tap.stop(timeout: 5) }
        await watchdog.waitForScheduled(1)
        watchdog.fireAll()
        #expect(await stop.value == .abandoned)
        #expect(tap.isAbandoned)

        // A second stop answers at once, without another watchdog or another hop
        // onto the stuck queue, and a start refuses instead of queueing behind it.
        #expect(await tap.stop(timeout: 5) == .abandoned)
        #expect(watchdog.scheduledTimeouts == [5])
        #expect(throws: SystemAudioTapError.self) { try tap.start(coverage: .global) }
    }

    /// A stop that completes before its watchdog leaves the tap healthy: the late
    /// watchdog cannot flip it to abandoned.
    @Test func aWatchdogAfterACompletedStopChangesNothing() async throws {
        let backend = FakeTapBackend()
        let watchdog = ManualWatchdog()
        let tap = makeTap(backend, watchdog: watchdog)
        try tap.start(coverage: .global)

        #expect(await tap.stop(timeout: 5) == .stopped)
        watchdog.fireAll()
        #expect(!tap.isAbandoned)
        #expect(backend.aggregatesStopped == 1)
        #expect(backend.tapsDestroyed == 1)
    }

    /// A rebuild CoreAudio refuses leaves the system track without an aggregate: the
    /// tap says so instead of swallowing the error, and still stops cleanly.
    @Test func aRefusedRebuildMarksTheTrackLost() async throws {
        let backend = FakeTapBackend()
        let tap = makeTap(backend)
        try tap.start(coverage: .global)
        #expect(!tap.lostDuringRecording)

        backend.failNextStart = true
        backend.fireOutputChanges(1)
        drainControl(tap)

        #expect(tap.lostDuringRecording)
        #expect(await tap.stop(timeout: 5) == .stopped)
        #expect(backend.tapsDestroyed == 1)
    }
}
