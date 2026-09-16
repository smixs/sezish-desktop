import AppKit
import AudioToolbox
import Foundation
import SezishCore

// Minimal CoreAudio property helpers for the process tap, the meeting detector
// and the mic route.
// Adapted from insidegui/AudioCap (https://github.com/insidegui/AudioCap,
// BSD-2-Clause license).

struct CoreAudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AudioObjectID {
    nonisolated static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
    nonisolated var isValid: Bool { self != kAudioObjectUnknown }

    /// `kAudioHardwarePropertyProcessObjectList` on the system object.
    nonisolated static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw CoreAudioError(message: "process list size failed: \(err)") }
        var value = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw CoreAudioError(message: "process list read failed: \(err)") }
        return value
    }

    /// The device regular audio plays through (not the alerts device).
    nonisolated static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
    }

    nonisolated func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    nonisolated func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    nonisolated func readProcessBundleID() -> String? {
        guard let value = try? readString(kAudioProcessPropertyBundleID), !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated func readProcessPID() -> pid_t? {
        guard let value = try? read(kAudioProcessPropertyPID, defaultValue: Int32(-1)), value > 0
        else { return nil }
        return pid_t(value)
    }

    nonisolated func readProcessIsRunningInput() -> Bool {
        (try? read(kAudioProcessPropertyIsRunningInput, defaultValue: UInt32(0))) == 1
    }

    nonisolated func readProcessIsRunningOutput() -> Bool {
        (try? read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0))) == 1
    }

    // MARK: - Generic property access

    nonisolated func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw CoreAudioError(message: "property \(selector) size failed: \(err)")
        }
        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw CoreAudioError(message: "property \(selector) read failed: \(err)")
        }
        return value
    }

    nonisolated func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, defaultValue: "" as CFString) as String
    }
}

/// One read of CoreAudio's process list, in the two shapes a meeting start needs:
/// the tap candidates (every process, with the bundle id CoreAudio gives it) and
/// the mic holders the call-app decision is made from. One read, because a second
/// one a moment later can name a process the first never saw.
struct AudioProcessSnapshot: Sendable {
    struct Process: Sendable {
        let id: UInt32
        let bundleID: String?
        let pid: pid_t?
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    let processes: [Process]

    /// Nothing could be read: the meeting then records the mic and every process,
    /// the same degradation as a call app with no live process of its own.
    static let empty = AudioProcessSnapshot(processes: [])

    /// Every live process, with the bundle id CoreAudio reports — or the one
    /// `NSRunningApplication` knows it by, exactly as the detector resolves it: the
    /// helper that renders the call's audio may not be named by CoreAudio at all.
    nonisolated static func read() throws -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            processes: try AudioObjectID.readProcessList().map { object in
                let pid = object.readProcessPID()
                return Process(
                    id: object,
                    bundleID: object.readProcessBundleID()
                        ?? pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                    pid: pid,
                    isRunningInput: object.readProcessIsRunningInput(),
                    isRunningOutput: object.readProcessIsRunningOutput()
                )
            }
        )
    }

    /// The pairs the tap coverage is decided over.
    nonisolated var tapCandidates: [(id: UInt32, bundleID: String?)] {
        processes.map { (id: $0.id, bundleID: $0.bundleID) }
    }

    /// The mic holders, as `MeetingCallAppResolver` and the detector both judge
    /// them: a process on the mic that nothing can name is not a call surface.
    nonisolated var inputHolders: [MeetingCallAppResolver.Holder] {
        processes.compactMap { process in
            guard process.isRunningInput, let bundleID = process.bundleID, let pid = process.pid
            else { return nil }
            return MeetingCallAppResolver.Holder(
                bundleID: bundleID, pid: pid, isRunningOutput: process.isRunningOutput
            )
        }
    }
}

/// The CoreAudio objects behind a scope: an adapter over the pure decision
/// `coverage(live:)`, which is where "what do we tap" is answered.
extension MeetingAudioScope {
    /// The objects this scope covers. `.all` has no list to begin with, and a family
    /// with nothing live is an empty one — both mean "the whole system" to a caller
    /// that asked for objects rather than for a coverage.
    nonisolated func liveProcessIDs() throws -> [AudioObjectID] {
        switch coverage(live: try AudioProcessSnapshot.read().tapCandidates) {
        case .global: return []
        case .processes(let ids): return ids
        }
    }
}
