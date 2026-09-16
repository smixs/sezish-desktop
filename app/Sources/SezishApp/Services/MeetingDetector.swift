import AppKit
import AudioToolbox
import Foundation
import SezishCore

/// Watches CoreAudio's process list for a call: a non-deny process that holds
/// the mic AND plays audio at the same time (full-duplex — what every call app
/// and every browser on a call looks like, and what a screen recorder or a
/// dictation tool never does: those are input-only). Sustained for the
/// debounce window it starts a recording; the mic going quiet for the stop
/// window ends it. The autoRecordMeetings gate lives in AppState; the detector
/// itself only runs while that toggle is on. All decisions happen inside the
/// 1 Hz tick.
@MainActor
final class MeetingDetector {
    var onMeetingStart: ((_ bundleID: String?) -> Void)?
    var onMeetingEnd: (() -> Void)?
    /// Fires after every tick with what the detector thinks right now; AppState
    /// mirrors it into the one-line "why not recording" menu hint.
    var onStatus: ((MeetingDetectorStatus) -> Void)?

    private let policy: MeetingDetectionPolicy
    private var debounce = MeetingDebounce()
    private var poll: Timer?
    /// Processes seen playing audio while holding the mic during this mic
    /// session. Output is sticky: a browser on a quiet call closes its output
    /// stream within seconds (no remote audio yet), so one sighting is enough
    /// to keep treating the process as a call until the mic goes quiet.
    private var seenOutput: Set<String> = []

    init(policy: MeetingDetectionPolicy) {
        self.policy = policy
    }

    func start() {
        guard poll == nil else { return }
        // 1 Hz polling (same cadence as the permission poll): the debounce FSM
        // needs time ticks anyway, and per-process listeners buy nothing here.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        debounce.reset()
        seenOutput.removeAll()
    }

    private func tick() {
        let holders = AudioProcessList.activeInputHolders()
        noteOutput(holders: holders)
        let candidate = policy.candidate(among: duplexIDs(holders: holders))
        let event = debounce.tick(externalMicActive: candidate != nil, at: Date())
        publishStatus(holders: holders, candidate: candidate)
        handle(event: event, candidate: candidate, holdersEmpty: holders.isEmpty)
    }

    private func noteOutput(holders: [AudioProcessList.MicHolder]) {
        for holder in holders where holder.isRunningOutput {
            seenOutput.insert(holder.bundleID)
        }
    }

    private func duplexIDs(holders: [AudioProcessList.MicHolder]) -> [String] {
        holders.filter { seenOutput.contains($0.bundleID) }.map(\.bundleID)
    }

    private func handle(
        event: MeetingDebounce.Event?,
        candidate: MeetingDetectionPolicy.Candidate?,
        holdersEmpty: Bool
    ) {
        switch event {
        case .start:
            onMeetingStart?(candidate?.bundleID)
        case .stop:
            seenOutput.removeAll()
            onMeetingEnd?()
        case nil:
            noteSilence(holdersEmpty: holdersEmpty)
        }
    }

    private func noteSilence(holdersEmpty: Bool) {
        // Nobody on the mic at all: the next session starts with a clean slate.
        if holdersEmpty { seenOutput.removeAll() }
    }

    private func publishStatus(
        holders: [AudioProcessList.MicHolder],
        candidate: MeetingDetectionPolicy.Candidate?
    ) {
        guard let onStatus else { return }
        onStatus(MeetingDetectorStatus.resolve(
            autoRecord: true,
            debounce: debounce,
            candidateName: candidate.map { name(of: $0.bundleID, in: holders) },
            deniedNames: holders.filter { policy.classify($0.bundleID) == .deny }
                .map { AudioProcessList.displayName(for: $0) },
            at: Date()
        ))
    }

    private func name(of bundleID: String, in holders: [AudioProcessList.MicHolder]) -> String {
        if let holder = holders.first(where: { $0.bundleID == bundleID }) {
            return AudioProcessList.displayName(for: holder)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

/// CoreAudio process enumeration (macOS 14.2+ property set).
enum AudioProcessList {
    struct MicHolder: Sendable {
        let bundleID: String
        let pid: pid_t
        /// True when the same process also has an active output stream
        /// (`kAudioProcessPropertyIsRunningOutput`): the remote side of a call.
        let isRunningOutput: Bool
    }

    /// Display name for the menu line: the running app's name when the pid is
    /// known, else the last bundle id segment ("us.zoom.xos" reads as "xos").
    nonisolated static func displayName(for holder: MicHolder) -> String {
        if holder.pid > 0,
            let name = NSRunningApplication(processIdentifier: holder.pid)?.localizedName,
            !name.isEmpty {
            return name
        }
        return holder.bundleID.components(separatedBy: ".").last ?? holder.bundleID
    }

    /// Everyone currently holding the mic. Helpers without a CoreAudio bundle
    /// id resolve via NSRunningApplication; a process neither can name is a
    /// bare agent/daemon, not a call surface — dropped.
    nonisolated static func activeInputHolders() -> [MicHolder] {
        guard let objects = try? AudioObjectID.readProcessList() else { return [] }
        return objects.compactMap { object in
            guard object.readProcessIsRunningInput() else { return nil }
            let pid = object.readProcessPID() ?? -1
            let output = object.readProcessIsRunningOutput()
            if let bundleID = object.readProcessBundleID() {
                return MicHolder(bundleID: bundleID, pid: pid, isRunningOutput: output)
            }
            guard pid > 0,
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            else { return nil }
            return MicHolder(bundleID: bundleID, pid: pid, isRunningOutput: output)
        }
    }
}
