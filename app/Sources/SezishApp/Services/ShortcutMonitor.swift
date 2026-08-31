import ApplicationServices
import CoreGraphics
import Foundation
import SezishCore

enum ShortcutMonitorError: LocalizedError {
    case accessibilityNotTrusted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            "sezish needs Accessibility permission to watch the push-to-talk key. Enable it in System Settings → Privacy & Security → Accessibility."
        case .tapCreationFailed:
            "Could not install the keyboard event tap."
        }
    }
}

/// Dictation hotkey over a `CGEventTap`, generalized to any ``Shortcut``: a modifier-only key
/// (right ⌘) or a key combination (⌥Space). Created as a `.defaultTap` so a `.key` combo
/// can be *swallowed* — otherwise the chosen hotkey (e.g. ⌥Space) would still reach the focused
/// app on every dictation. Only a positive `.key` match is dropped; modifier-only holds and
/// every other event pass straight through, so this is safe for the default right-⌘ path too.
/// The run-loop source lives on the main run loop, so the C callback fires on the main thread —
/// hence `MainActor.assumeIsolated` in the trampoline.
@MainActor
final class ShortcutMonitor: HotkeyMonitor {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    /// Armed by AppState only while dictation is recording. When armed, a *plain* Esc keyDown
    /// is swallowed and reported via `onEscapeCancel`; its keyUp (and auto-repeats until then)
    /// are swallowed too, so the focused app never sees half of an Esc pair.
    var isEscapeArmed = false
    var onEscapeCancel: (() -> Void)?

    private(set) var shortcut: Shortcut
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var isHolding = false
    private var isSwallowingEscape = false
    private static let escKeyCode = 53

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    /// Swaps the active shortcut without rebuilding the tap: the event mask is identical for
    /// every shortcut. A hold in progress is cancelled so no downstream state gets stuck.
    func updateShortcut(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        if isHolding {
            isHolding = false
            onReleased?()
        }
    }

    func startMonitoring() throws {
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            throw ShortcutMonitorError.accessibilityNotTrusted
        }
        try createTap()
        startHealthCheck()
    }

    func stopMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
        teardownTap()
        isHolding = false
        isEscapeArmed = false
        isSwallowingEscape = false
    }

    // MARK: - Callback entry points (invoked on the main thread)

    fileprivate func handleFlagsChanged(keyCode: Int, flagsRaw: UInt64) {
        guard shortcut.kind == .modifierOnly else { return }
        if !isHolding, shortcut.matchesModifierBegin(eventKeyCode: keyCode, eventFlagsRaw: flagsRaw) {
            isHolding = true
            onPressed?()
        } else if isHolding, shortcut.matchesModifierEnd(eventKeyCode: keyCode, eventFlagsRaw: flagsRaw) {
            isHolding = false
            onReleased?()
        }
    }

    /// Returns `true` when the keyDown must be swallowed: an armed plain Esc (cancel), or a
    /// matched `.key` shortcut. The press fires on the first match; auto-repeat keyDowns while
    /// held are still swallowed but do not re-fire `onPressed`.
    func handleKeyDown(keyCode: Int, flagsRaw: UInt64) -> Bool {
        if keyCode == Self.escKeyCode, flagsRaw & Shortcut.allModifierFlags == 0 {
            if isSwallowingEscape { return true } // auto-repeat while Esc is held
            if isEscapeArmed {
                isSwallowingEscape = true
                onEscapeCancel?()
                return true
            }
        }
        guard shortcut.kind == .key,
              shortcut.matchesKeyDown(eventKeyCode: keyCode, eventFlagsRaw: flagsRaw) else { return false }
        if !isHolding {
            isHolding = true
            onPressed?()
        }
        return true
    }

    /// Returns `true` when the keyUp ends an in-progress `.key` press (or closes a swallowed
    /// Esc pair) and must be swallowed. Gated on `isHolding` so a non-matching keyDown (e.g.
    /// plain Space, whose keyUp shares the keycode) is never eaten one-sidedly, which would
    /// strand a keyDown in the focused app.
    func handleKeyUp(keyCode: Int) -> Bool {
        if keyCode == Self.escKeyCode, isSwallowingEscape {
            isSwallowingEscape = false
            return true
        }
        guard shortcut.kind == .key, isHolding,
              shortcut.matchesKeyUp(eventKeyCode: keyCode) else { return false }
        isHolding = false
        onReleased?()
        return true
    }

    fileprivate func reEnableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        // The tap died mid-hold: events were lost, so the release may never arrive. Synthesize
        // it — otherwise push-to-talk records forever (the classic stuck-PTT bug).
        if isHolding {
            isHolding = false
            onReleased?()
        }
    }

    // MARK: - Tap lifecycle

    private func createTap() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // `.defaultTap` (not `.listenOnly`) so the callback can drop a matched `.key` combo.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ShortcutMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func teardownTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Fault tolerance

    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
    }

    private func healthCheck() {
        guard let eventTap else {
            try? createTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func promptForAccessibility() {
        // `kAXTrustedCheckOptionPrompt` is imported as a mutable global var, which Swift 6
        // rejects as non-concurrency-safe; its ABI-stable value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// C trampoline: `CGEventTap` callbacks are `@convention(c)` and cannot capture context,
/// so it recovers the monitor from `userInfo` and hops onto the main actor.
private nonisolated func shortcutTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flagsRaw = event.flags.rawValue

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { monitor.reEnableTap() }
    case .flagsChanged:
        MainActor.assumeIsolated { monitor.handleFlagsChanged(keyCode: keyCode, flagsRaw: flagsRaw) }
    case .keyDown:
        let swallow = MainActor.assumeIsolated { monitor.handleKeyDown(keyCode: keyCode, flagsRaw: flagsRaw) }
        if swallow { return nil }
    case .keyUp:
        let swallow = MainActor.assumeIsolated { monitor.handleKeyUp(keyCode: keyCode) }
        if swallow { return nil }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
