import Foundation

/// An input device a meeting can be recorded from: the id CoreAudio needs to open
/// it, and the name the log speaks.
public struct MicDevice: Equatable, Sendable {
    public let id: UInt32
    public let name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which input the mic track records from.
public enum MeetingMicRoute {
    /// The call app's own input wins: if Zoom listens to the headset while the
    /// system sits on the built-in mic, recording the system default would capture
    /// the room around the call. With nothing from the call app the system default
    /// is the honest answer, and with neither the engine picks its own — exactly
    /// what dictation has always done.
    public static func device(
        callAppInputs: [MicDevice], default defaultDevice: MicDevice?
    ) -> MicDevice? {
        callAppInputs.first ?? defaultDevice
    }
}
