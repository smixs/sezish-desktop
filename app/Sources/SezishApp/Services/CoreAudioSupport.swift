import AppKit
import AudioToolbox
import Foundation
import SezishCore
import os

/// One line per meeting start about the mic: which input it follows and why, plus every
/// input that could not be read. Same subsystem and predicate as every other log.
/// `nonisolated` because the input reading runs off the main actor.
nonisolated let micRouteLog = Logger(subsystem: "com.smixs.sezish", category: "mic-route")

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

    /// This device as a route candidate: the id CoreAudio opens it by, the name the
    /// user sees in System Settings, and whether it is real hardware at all.
    nonisolated func readMicDevice() throws -> MicDevice {
        MicDevice(id: self, name: try readDeviceName(), isVirtual: try readIsVirtual())
    }

    /// A device that is not hardware: Zoom's own loopback, an aggregate, a virtual
    /// cable. They answer in the input scope and pass the input-channel filter, and
    /// then hand the engine zero frames — a mic track that is silence is as wrong as
    /// one that recorded the room.
    nonisolated func readIsVirtual() throws -> Bool {
        let transport = try read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
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
        // The call reports what it actually wrote: the property can shrink between the
        // size query and the read, and the tail would still hold `kAudioObjectUnknown`
        // (object #0) — an id that throws on every read it is passed to.
        return Array(value.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))
    }
}

/// Where a meeting's mic comes from: the device the call app listens to, which is
/// the reason process devices are read at all.
extension MeetingCallApp {
    /// Every microphone this app's family holds, in discovery order and without
    /// duplicates — several helpers normally share one device. The family's processes
    /// come from the snapshot the start already read: a second read a moment later can
    /// name a process the first never saw.
    nonisolated func inputDevices(in snapshot: AudioProcessSnapshot) -> [MicDevice] {
        var unique: [MicDevice] = []
        var seen: Set<UInt32> = []
        for device in snapshot.inputProcessIDs(of: .family(family)).flatMap(readDevices) {
            guard seen.insert(device.id).inserted else { continue }
            unique.append(device)
        }
        return unique
    }

    /// The devices of one process. Read on its own: a helper of the family that holds
    /// no audio, or a device that disappeared between the listing and the read, must
    /// cost the meeting that one entry — not every device of the app (an empty list is
    /// indistinguishable from "the app listens to nothing", and that answer records
    /// the room, which is the defect this route exists for).
    private nonisolated func readDevices(of process: AudioObjectID) -> [MicDevice] {
        do {
            return try process.readProcessInputDevices().compactMap(readDevice)
        } catch {
            micRouteLog.error(
                "input devices of process \(process, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// One device: without input channels it is not a microphone at all (a call app
    /// holds its outputs too), and one that cannot be read is skipped with its cause.
    private nonisolated func readDevice(_ device: AudioDeviceID) -> MicDevice? {
        do {
            guard try device.readHasInputChannels() else { return nil }
            return try device.readMicDevice()
        } catch {
            micRouteLog.error(
                "device \(device, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
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

    /// The family's objects that are actually on the mic. A helper that holds no input
    /// has nothing to read — asking it anyway is one throw away from losing every
    /// device of the family — so the snapshot's own flag decides who is asked.
    nonisolated func inputProcessIDs(of scope: MeetingAudioScope) -> [AudioObjectID] {
        let holdingInput = Set(processes.filter(\.isRunningInput).map(\.id))
        return processIDs(of: scope).filter { holdingInput.contains($0) }
    }
}
