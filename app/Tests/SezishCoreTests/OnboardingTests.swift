import Foundation
import Testing
@testable import SezishCore

/// The first-run tour: permissions → engine → done. Each test named after an
/// invariant replays the counterexample its witness config finds in
/// `specs/tla/Onboarding.tla`, on the real flow.
struct OnboardingFlowTests {
    private let allOn = OnboardingStatus(microphone: .granted, accessibility: .on)
    private let nothing = OnboardingStatus(microphone: .notDetermined, accessibility: .off)

    @Test func aFreshMacStartsOnPermissionsAndAReadyOneSkipsThem() {
        let fresh = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        #expect(fresh.step == .permissions)
        let ready = OnboardingFlow(status: allOn, engine: .cloud, model: .missing)
        #expect(ready.step == .engine)
    }

    @Test func theTourIsNeededOnlyWhenSomethingIsMissing() {
        #expect(!OnboardingFlow.needed(status: allOn, engine: .cloud, model: .missing))
        #expect(!OnboardingFlow.needed(status: allOn, engine: .local, model: .ready))
        #expect(OnboardingFlow.needed(status: allOn, engine: .local, model: .missing))
        #expect(OnboardingFlow.needed(
            status: OnboardingStatus(microphone: .granted, accessibility: .needsRestart),
            engine: .cloud, model: .ready))
        #expect(OnboardingFlow.needed(status: nothing, engine: .cloud, model: .ready))
    }

    @Test func microphoneAsksOnceThenOpensSettingsWhenRefused() {
        var flow = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        do { let r = flow.on(.grantMicrophone); #expect(r == .requestMicrophone) }
        #expect(flow.rows.microphone == .waiting)
        _ = flow.on(.status(OnboardingStatus(microphone: .denied, accessibility: .off)))
        #expect(flow.rows.microphone == .denied)
        do { let r = flow.on(.grantMicrophone) == .showGuide(.microphone); #expect(r) }
        #expect(flow.rows.microphone == .waiting)
    }

    @Test func bothGrantsAdvanceAfterABeat() {
        var flow = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        do { let r = flow.on(.continue); #expect(r == .none) } // nothing granted yet
        #expect(flow.step == .permissions)
        do { let r = flow.on(.status(allOn)); #expect(r == .advanceSoon) }
        do { let r = flow.on(.continue); #expect(r == .none) }
        #expect(flow.step == .engine)
    }

    // FinishOnlyWhenReady (Onboarding-nofinishguard).
    @Test func finishWaitsForTheEngine() {
        var flow = OnboardingFlow(status: allOn, engine: .local, model: .missing)
        do { let r = flow.on(.continue); #expect(r == .none) }
        #expect(flow.step == .done)
        _ = flow.on(.model(.downloading(0.4)))
        do { let r = flow.on(.continue); #expect(r == .none) }
        #expect(flow.step == .done)
        _ = flow.on(.model(.ready))
        do { let r = flow.on(.continue); #expect(r == .finish) }
        #expect(flow.step == .finished)
    }

    @Test func cloudIsReadyAtOnce() {
        var flow = OnboardingFlow(status: allOn, engine: .local, model: .failed)
        do { let r = flow.on(.chooseEngine(.cloud)); #expect(r == .none) }
        _ = flow.on(.continue)
        do { let r = flow.on(.continue); #expect(r == .finish) }
    }

    // PastPermissionsOnlyWhenGranted (Onboarding-noback).
    @Test func aGrantTurnedOffMidTourSendsThePersonBack() {
        var flow = OnboardingFlow(status: allOn, engine: .cloud, model: .missing)
        _ = flow.on(.continue)
        #expect(flow.step == .done)
        _ = flow.on(.status(OnboardingStatus(microphone: .denied, accessibility: .on)))
        #expect(flow.step == .permissions)
        do { let r = flow.on(.continue); #expect(r == .none) }
    }

    // AtMostOneDownload (Onboarding-doubledownload).
    @Test func oneDownloadAtATime() {
        var flow = OnboardingFlow(status: allOn, engine: .cloud, model: .missing)
        do { let r = flow.on(.chooseEngine(.local)); #expect(r == .downloadModel) }
        do { let r = flow.on(.chooseEngine(.cloud)); #expect(r == .none) }
        do { let r = flow.on(.chooseEngine(.local)); #expect(r == .none) } // still downloading
        do { let r = flow.on(.retryDownload); #expect(r == .none) }
        _ = flow.on(.model(.downloading(0.5)))
        do { let r = flow.on(.status(allOn)); #expect(r == .none) }
        _ = flow.on(.model(.failed))
        do { let r = flow.on(.retryDownload); #expect(r == .downloadModel) }
        do { let r = flow.on(.retryDownload); #expect(r == .none) }
    }

    @Test func aMissingLocalModelStartsDownloadingOnAnyScreen() {
        var flow = OnboardingFlow(status: nothing, engine: .local, model: .missing)
        #expect(flow.step == .permissions)
        do { let r = flow.on(.status(nothing)); #expect(r == .downloadModel) }
        #expect(flow.model == .downloading(0))
        do { let r = flow.on(.status(nothing)); #expect(r == .none) }
    }

    @Test func aDownloadFirstThenTheAdvanceOnTheNextPoll() {
        var flow = OnboardingFlow(status: nothing, engine: .local, model: .missing)
        do { let r = flow.on(.status(allOn)); #expect(r == .downloadModel) }
        do { let r = flow.on(.status(allOn)); #expect(r == .advanceSoon) }
    }

    // StaleOnlyWhenGrey.
    @Test func staleNeedsAnAskedUntrustedRow() {
        var flow = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        flow.setAccessibilityStale(true)
        #expect(flow.rows.accessibility == .todo)
        do { let r = flow.on(.grantAccessibility(trustedNow: false)) == .showGuide(.accessibility); #expect(r) }
        #expect(flow.rows.accessibility == .waiting)
        flow.setAccessibilityStale(true)
        #expect(flow.rows.accessibility == .stale)
        _ = flow.on(.status(OnboardingStatus(microphone: .granted, accessibility: .on)))
        #expect(flow.rows.accessibility == .ready)
        flow.setAccessibilityStale(true)
        #expect(flow.rows.accessibility == .ready)
    }

    // NoResetOfWorkingGrant (Onboarding-stalereset): the grant lands after the
    // last poll, before the click.
    @Test func fixItNeverClearsAGrantThatAlreadyWorks() {
        var flow = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        _ = flow.on(.grantAccessibility(trustedNow: false))
        flow.setAccessibilityStale(true)
        do { let r = flow.on(.grantAccessibility(trustedNow: true)); #expect(r == .none) }
        #expect(flow.rows.accessibility == .ready)
    }

    // Termination (Onboarding-nofix): an old grey row needs the reset.
    @Test func fixItResetsAGreyRowAndWaitsAgain() {
        var flow = OnboardingFlow(status: nothing, engine: .cloud, model: .missing)
        _ = flow.on(.grantAccessibility(trustedNow: false))
        flow.setAccessibilityStale(true)
        do { let r = flow.on(.grantAccessibility(trustedNow: false)); #expect(r == .resetAccessibility) }
        #expect(flow.rows.accessibility == .waiting)
        do { let r = flow.on(.grantAccessibility(trustedNow: false)) == .showGuide(.accessibility); #expect(r) }
    }

    // RelaunchBounded (Onboarding-relaunchloop).
    @Test func theListenerRelaunchesOnceThenAsksThePerson() {
        let restart = OnboardingStatus(microphone: .granted, accessibility: .needsRestart)
        var flow = OnboardingFlow(status: restart, engine: .cloud, model: .missing)
        #expect(flow.rows.accessibility == .restart)
        do { let r = flow.on(.listenerFailed(relaunchAllowed: true)); #expect(r == .relaunch) }
        do { let r = flow.on(.listenerFailed(relaunchAllowed: true)); #expect(r == .none) }

        var held = OnboardingFlow(status: restart, engine: .cloud, model: .missing)
        do { let r = held.on(.reopen); #expect(r == .none) }
        do { let r = held.on(.listenerFailed(relaunchAllowed: false)); #expect(r == .none) }
        #expect(held.reopen)
        do { let r = held.on(.reopen); #expect(r == .relaunch) }
        #expect(!held.reopen)
    }

    @Test func backWalksTheScreensInReverse() {
        var flow = OnboardingFlow(status: allOn, engine: .cloud, model: .missing)
        _ = flow.on(.continue)
        do { let r = flow.on(.back); #expect(r == .none) }
        #expect(flow.step == .engine)
        _ = flow.on(.back)
        #expect(flow.step == .permissions)
        _ = flow.on(.back)
        #expect(flow.step == .permissions)
    }
}

/// "Still grey? Fix it" appears only after the person went to System Settings,
/// came back (or closed it), and the app is still untrusted. Port of hex's test.
struct StalePermissionTrackerTests {
    private let inSettings = SettingsFocus(settingsOpen: true, settingsFrontmost: true, appActive: false)
    private let touchIdOverSettings = SettingsFocus(settingsOpen: true, settingsFrontmost: false, appActive: false)
    private let backInApp = SettingsFocus(settingsOpen: true, settingsFrontmost: false, appActive: true)
    private let settingsClosed = SettingsFocus(settingsOpen: false, settingsFrontmost: false, appActive: false)

    @Test func waitsForTheReturnAndIgnoresTouchIdFocus() {
        var tracker = StalePermissionTracker()
        let t0: TimeInterval = 100
        do { let r = tracker.poll(now: t0, untrusted: true, focus: backInApp); #expect(!r) }
        tracker.noteAsked(now: t0)
        #expect(tracker.isWaiting)

        do { let r = tracker.poll(now: t0 + 1, untrusted: true, focus: inSettings); #expect(!r) }
        do { let r = tracker.poll(now: t0 + 12, untrusted: true, focus: touchIdOverSettings); #expect(!r) }

        do { let r = tracker.poll(now: t0 + 13, untrusted: true, focus: backInApp); #expect(!r) }
        do { let r = tracker.poll(now: t0 + 14.9, untrusted: true, focus: backInApp); #expect(!r) }
        do { let r = tracker.poll(now: t0 + 15, untrusted: true, focus: backInApp); #expect(r) }
        do { let r = tracker.poll(now: t0 + 16, untrusted: false, focus: backInApp); #expect(!r) }
        #expect(!tracker.isWaiting)
    }

    @Test func closingSettingsWithoutAGrantAlsoCounts() {
        var tracker = StalePermissionTracker()
        tracker.noteAsked(now: 0)
        do { let r = tracker.poll(now: 1, untrusted: true, focus: inSettings); #expect(!r) }
        do { let r = tracker.poll(now: 2, untrusted: true, focus: settingsClosed); #expect(!r) }
        do { let r = tracker.poll(now: 4, untrusted: true, focus: settingsClosed); #expect(r) }
    }

    @Test func sideBySideFallsBackAfterSixSeconds() {
        var tracker = StalePermissionTracker()
        tracker.noteAsked(now: 0)
        do { let r = tracker.poll(now: 5, untrusted: true, focus: backInApp); #expect(!r) }
        do { let r = tracker.poll(now: StalePermissionTracker.sideBySideDelay, untrusted: true, focus: backInApp); #expect(r) }
    }
}

/// A relaunch the tour started less than 120 s ago blocks another one, and the
/// tour resumes once after it.
struct OnboardingRelaunchGuardTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaunch-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func blocksASecondRelaunchForTwoMinutes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let guardFile = OnboardingRelaunchGuard(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(guardFile.allowed(now: t0))
        try guardFile.record(now: t0)
        #expect(!guardFile.allowed(now: t0.addingTimeInterval(119)))
        #expect(guardFile.allowed(now: t0.addingTimeInterval(120)))
    }

    @Test func resumesOnceAndOnlyRightAfterTheRelaunch() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let guardFile = OnboardingRelaunchGuard(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!guardFile.takeResume(now: t0))
        try guardFile.record(now: t0)
        #expect(guardFile.takeResume(now: t0.addingTimeInterval(3)))
        #expect(!guardFile.takeResume(now: t0.addingTimeInterval(4)))

        try guardFile.record(now: t0)
        #expect(!guardFile.takeResume(now: t0.addingTimeInterval(500))) // quit and reopened later
    }
}

struct TccResetTests {
    @Test func classifiesTccutilExits() {
        #expect(TccResetOutcome(exitCode: 0, stderr: "") == .cleared)
        #expect(TccResetOutcome(exitCode: 64, stderr: "") == .nothingToClear)
        #expect(TccResetOutcome(exitCode: 1, stderr: "OSStatus error -10814") == .nothingToClear)
        #expect(TccResetOutcome(exitCode: 1, stderr: "No such bundle identifier") == .nothingToClear)
        #expect(TccResetOutcome(exitCode: 1, stderr: "boom") == .failed)
    }
}
