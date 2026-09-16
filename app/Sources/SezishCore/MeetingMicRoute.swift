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
    // RED: surface only, the behaviour lands in the next commit.
    public static func device(
        callAppInputs: [MicDevice], default defaultDevice: MicDevice?
    ) -> MicDevice? {
        nil
    }
}
