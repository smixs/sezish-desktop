import AppKit
import AudioToolbox
import Foundation
import SezishCore
import os

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
        try AudioObjectID.system.readIDs(kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal)
    }

    /// The device regular audio plays through (not the alerts device).
    nonisolated static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
    }

    /// The device new input streams open on by default.
    nonisolated static func readDefaultInputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice, defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
    }

    /// `kAudioProcessPropertyDevices` in the input scope: the devices this process
    /// listens to, which is not necessarily the system's default input — that
    /// difference is the whole point of asking.
    nonisolated func readProcessInputDevices() throws -> [AudioDeviceID] {
        try readIDs(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
    }

    /// True when the device exposes at least one input channel: a call app holds
    /// output devices too, and those are not microphones.
    nonisolated func readHasInputChannels() throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw CoreAudioError(message: "input configuration size failed: \(err)")
        }
        // The API writes a whole AudioBufferList, whose header is what the
        // channel count is read from: never allocate less than one.
        let bytes = Swift.max(Int(size), MemoryLayout<AudioBufferList>.size)
        let list = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { list.deallocate() }
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, list)
        guard err == noErr else {
            throw CoreAudioError(message: "input configuration read failed: \(err)")
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            list.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// This device as a route candidate: the id CoreAudio opens it by, and the
    /// name the user sees in System Settings.
    nonisolated func readMicDevice() throws -> MicDevice {
        MicDevice(id: self, name: try readDeviceName(), isVirtual: false)
    }

    nonisolated func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
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

    /// An array-valued property in a given scope, as raw ids — `AudioObjectID`,
    /// `AudioDeviceID` and `AudioStreamID` are all `UInt32`. `read` is
    /// global-scope only, which is what every other caller here wants.
    nonisolated func readIDs(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw CoreAudioError(message: "property \(selector) size failed: \(err)")
        }
        var value = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else {
            throw CoreAudioError(message: "property \(selector) read failed: \(err)")
        }
        return value
    }
}

/// Where a meeting's mic comes from: the device the call app listens to, which is
/// the reason process devices are read at all.
extension MeetingCallApp {
    /// Every microphone this app's family holds, in discovery order and without
    /// duplicates — several helpers normally share one device. The family's
    /// processes come from the snapshot the start already read: a second read a
    /// moment later can name a process the first never saw.
    nonisolated func inputDevices(in snapshot: AudioProcessSnapshot) -> [MicDevice] {
        do {
            return try readInputDevices(in: snapshot)
        } catch {
            // No better answer than the system default anyway (`MeetingMicRoute`),
            // so the cause is logged and the recording is not lost to it.
            Logger(subsystem: "com.smixs.sezish", category: "mic-route").error(
                "call app inputs unreadable for \(family, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private nonisolated func readInputDevices(in snapshot: AudioProcessSnapshot) throws -> [MicDevice] {
        var unique: [MicDevice] = []
        var seen: Set<UInt32> = []
        for device in try readMicDevices(in: snapshot) where seen.insert(device.id).inserted {
            unique.append(device)
        }
        return unique
    }

    private nonisolated func readMicDevices(in snapshot: AudioProcessSnapshot) throws -> [MicDevice] {
        try snapshot.processIDs(of: .family(family)).flatMap { process in
            try process.readProcessInputDevices()
                .filter { try $0.readHasInputChannels() }
                .map { try $0.readMicDevice() }
        }
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

/// The CoreAudio objects behind one scope, unpacked from a snapshot the caller
/// already has: `coverage(live:)` in `SezishCore` decides, this only translates.
extension AudioProcessSnapshot {
    /// The objects of a named family — an empty list for `.all`, which has no list to
    /// begin with, and for a family with nothing live. Reading the objects is the
    /// only reason to hold a snapshot at all; the tap gets a `TapCoverage` instead.
    nonisolated func processIDs(of scope: MeetingAudioScope) -> [AudioObjectID] {
        switch scope.coverage(live: tapCandidates) {
        case .global: return []
        case .processes(let ids): return ids
        }
    }
}
