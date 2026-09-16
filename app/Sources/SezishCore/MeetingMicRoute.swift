import Foundation

/// An input device a meeting can be recorded from: the id CoreAudio needs to open
/// it, the name the log speaks, and whether it is a real microphone at all.
public struct MicDevice: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    /// A virtual or aggregate device (`kAudioDeviceTransportTypeVirtual` and
    /// friends). A call app always holds at least one — Zoom's own loopback — and it
    /// answers to the input scope while handing the engine zero frames, so it can
    /// never be the mic track's device.
    public let isVirtual: Bool

    public init(id: UInt32, name: String, isVirtual: Bool) {
        self.id = id
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Which input the mic track records from.
public enum MeetingMicRoute {
    /// The call app's own input, first one that is a real microphone. Zoom can listen
    /// to the headset while the system sits on the built-in mic: recording the system
    /// default there would capture the room around the call. With nothing usable from
    /// the call app the answer is nil — the engine picks its own input, exactly what
    /// dictation has always done, and a device nobody asked for is never pinned.
    public static func device(callAppInputs: [MicDevice]) -> MicDevice? {
        callAppInputs.first { !$0.isVirtual }
    }
}
