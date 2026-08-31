import Foundation

/// How the dictation hotkey drives recording.
public enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Push-to-talk: press starts, release stops.
    case hold
    /// Press once to start, press again to stop; the release is ignored.
    case toggle
}

/// Pure interpreter between the event tap's press/release edges and dictation commands.
/// Instead of a "hands-free" latch (VoiceInk) it consults a live `isRecording` closure, so an
/// externally ended take (Esc cancel, failed start, mode flip) can never strand stale state.
/// Not Sendable by design: owned and driven exclusively by the MainActor `AppState`.
public final class HotkeyModeInterpreter {
    public enum Command: Equatable, Sendable {
        case start, stop, none
    }

    /// Toggle-mode debounce (VoiceInk's press cooldown): a second press within this window is
    /// tap-bounce, not intent, and would stop the recording the instant it started. Hold mode
    /// is exempt — a fast consecutive push-to-talk press must never be eaten.
    public static let toggleCooldown: TimeInterval = 0.5

    public var mode: HotkeyMode

    private let isRecording: () -> Bool
    private let now: () -> TimeInterval
    private var isPressed = false
    private var lastAcceptedPress: TimeInterval?

    public init(
        mode: HotkeyMode,
        isRecording: @escaping () -> Bool,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.mode = mode
        self.isRecording = isRecording
        self.now = now
    }

    public func keyPressed() -> Command {
        guard !isPressed else { return .none } // auto-repeat / double-fire guard
        if mode == .toggle, let last = lastAcceptedPress, now() - last < Self.toggleCooldown {
            return .none // debounced; its release is a no-op via the isPressed gate
        }
        isPressed = true
        lastAcceptedPress = now()
        if isRecording() {
            return mode == .toggle ? .stop : .none
        }
        return .start
    }

    public func keyReleased() -> Command {
        guard isPressed else { return .none } // release of a debounced press
        isPressed = false
        switch mode {
        case .hold: return isRecording() ? .stop : .none
        case .toggle: return .none
        }
    }

    /// Forgets any in-flight press and cooldown (mode flip, monitor reinstall).
    public func reset() {
        isPressed = false
        lastAcceptedPress = nil
    }
}
