import Foundation
import Testing
@testable import SezishCore

struct MeetingDetectorStatusTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var ru: MeetingStatusText {
        MeetingStatusText(
            ready: "Готов, жду звонок",
            denied: "Микрофон занят: %@ — это не звонок",
            candidate: "%@ держит микрофон %d с",
            recording: "Идёт встреча",
            processing: "Обрабатываю запись",
            fading: "Тихо уже %d с"
        )
    }

    private func startedDebounce() -> MeetingDebounce {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        _ = debounce.tick(externalMicActive: true, at: t0 + 2)
        return debounce
    }

    @Test func telegramHoldingOneOfTwoSecondsIsCandidate() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        let status = MeetingDetectorStatus.resolve(
            appStatus: .idle, debounce: debounce,
            candidateName: "Telegram", deniedNames: [], at: t0 + 1)
        #expect(status == .candidate(name: "Telegram", seconds: 1))
        #expect(meetingStatusLine(status, text: ru) == "Telegram держит микрофон 1 с")
    }

    @Test func handyAloneOnMicIsDenied() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: false, at: t0)
        let status = MeetingDetectorStatus.resolve(
            appStatus: .idle, debounce: debounce,
            candidateName: nil, deniedNames: ["Handy"], at: t0)
        #expect(status == .denied(names: ["Handy"]))
        #expect(meetingStatusLine(status, text: ru) == "Микрофон занят: Handy — это не звонок")
    }

    @Test func nobodyOnMicIsReady() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: false, at: t0)
        let status = MeetingDetectorStatus.resolve(
            appStatus: .idle, debounce: debounce,
            candidateName: nil, deniedNames: [], at: t0)
        #expect(status == .ready)
        #expect(meetingStatusLine(status, text: ru) == "Готов, жду звонок")
    }

    @Test func idleWithActiveDebounceIsNotRecording() {
        // Manual stop, failed start, gated auto-start: the mic is still held,
        // but nothing records — and the line must not claim otherwise.
        let status = MeetingDetectorStatus.resolve(
            appStatus: .idle, debounce: startedDebounce(),
            candidateName: "Telegram", deniedNames: [], at: t0 + 60)
        #expect(status == .ready)
        #expect(meetingStatusLine(status, text: ru) == "Готов, жду звонок")
    }

    @Test func recordingStatusWinsOverDebounce() {
        let status = MeetingDetectorStatus.resolve(
            appStatus: .recording, debounce: startedDebounce(),
            candidateName: "Telegram", deniedNames: [], at: t0 + 60)
        #expect(status == .recording)
        #expect(meetingStatusLine(status, text: ru) == "Идёт встреча")
    }

    @Test func processingStatusShowsProgress() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: false, at: t0)
        let status = MeetingDetectorStatus.resolve(
            appStatus: .processing, debounce: debounce,
            candidateName: nil, deniedNames: [], at: t0)
        #expect(status == .processing)
        #expect(meetingStatusLine(status, text: ru) == "Обрабатываю запись")
    }

    @Test func quietCallIsFading() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        _ = debounce.tick(externalMicActive: true, at: t0 + 2)
        _ = debounce.tick(externalMicActive: false, at: t0 + 5)
        let status = MeetingDetectorStatus.resolve(
            appStatus: .idle, debounce: debounce,
            candidateName: nil, deniedNames: [], at: t0 + 9)
        #expect(status == .fading(seconds: 4))
        #expect(meetingStatusLine(status, text: ru) == "Тихо уже 4 с")
    }
}

struct MeetingDeniedNamesTests {
    private let policy = MeetingDetectionPolicy(ownBundleID: "com.smixs.sezish")

    @Test func ownProcessIsFilteredOut() {
        let holders = [
            (bundleID: "com.smixs.sezish", displayName: "sezish"),
            (bundleID: "cc.handy", displayName: "Handy"),
            (bundleID: "us.zoom.xos", displayName: "zoom.us"),
        ]
        #expect(policy.deniedNames(among: holders) == ["Handy"])
    }

    @Test func duplicateNamesCollapseToOne() {
        let holders = [
            (bundleID: "com.anthropic.claudefordesktop", displayName: "Claude"),
            (bundleID: "com.anthropic.claudefordesktop.helper", displayName: "Claude"),
            (bundleID: "com.anthropic.claudefordesktop.helper.GPU", displayName: "Claude"),
        ]
        #expect(policy.deniedNames(among: holders) == ["Claude"])
    }
}
