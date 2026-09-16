import AudioToolbox
import Foundation
import SezishCore

// Minimal CoreAudio property helpers for the process tap and meeting detector.
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

/// Which of the live processes a family scope covers. An empty list is a real
/// answer — nothing of that family is running — and what an empty list means for
/// the recording is the tap's call, not this helper's. Throws only when the
/// system-wide process list cannot be read at all.
extension MeetingAudioScope {
    nonisolated func liveProcessIDs() throws -> [AudioObjectID] {
        guard case .family(let family) = self else { return [] }
        return try AudioObjectID.readProcessList().filter { object in
            guard let bundleID = object.readProcessBundleID() else { return false }
            return CallAppFamily.belongs(bundleID, to: family)
        }
    }
}
