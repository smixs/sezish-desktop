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
            fading: "Тихо уже %d с"
        )
    }

    @Test func telegramHoldingOneOfTwoSecondsIsCandidate() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: true, debounce: debounce,
            candidateName: "Telegram", deniedNames: [], at: t0 + 1)
        #expect(status == .candidate(name: "Telegram", seconds: 1))
        #expect(meetingStatusLine(status, text: ru) == "Telegram держит микрофон 1 с")
    }

    @Test func handyAloneOnMicIsDenied() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: false, at: t0)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: true, debounce: debounce,
            candidateName: nil, deniedNames: ["Handy"], at: t0)
        #expect(status == .denied(names: ["Handy"]))
        #expect(meetingStatusLine(status, text: ru) == "Микрофон занят: Handy — это не звонок")
    }

    @Test func nobodyOnMicIsReady() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: false, at: t0)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: true, debounce: debounce,
            candidateName: nil, deniedNames: [], at: t0)
        #expect(status == .ready)
        #expect(meetingStatusLine(status, text: ru) == "Готов, жду звонок")
    }

    @Test func disabledToggleYieldsNoLine() {
        let debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: false, debounce: debounce,
            candidateName: "Telegram", deniedNames: [], at: t0)
        #expect(status == .disabled)
        #expect(meetingStatusLine(status, text: ru) == nil)
    }

    @Test func activeDebounceIsRecording() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        _ = debounce.tick(externalMicActive: true, at: t0 + 2)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: true, debounce: debounce,
            candidateName: "Telegram", deniedNames: [], at: t0 + 3)
        #expect(status == .recording)
        #expect(meetingStatusLine(status, text: ru) == "Идёт встреча")
    }

    @Test func quietCallIsFading() {
        var debounce = MeetingDebounce(startAfter: 2, stopAfter: 10)
        _ = debounce.tick(externalMicActive: true, at: t0)
        _ = debounce.tick(externalMicActive: true, at: t0 + 2)
        _ = debounce.tick(externalMicActive: false, at: t0 + 5)
        let status = MeetingDetectorStatus.resolve(
            autoRecord: true, debounce: debounce,
            candidateName: nil, deniedNames: [], at: t0 + 9)
        #expect(status == .fading(seconds: 4))
        #expect(meetingStatusLine(status, text: ru) == "Тихо уже 4 с")
    }
}
