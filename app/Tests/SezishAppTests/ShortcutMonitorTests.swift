import Testing
import SezishCore
@testable import SezishApp

/// Guards the tap's swallow decision: a `.key` combo must be consumed so it never leaks into
/// the focused app, while a `.modifierOnly` hold — and any non-matching key — must pass through.
/// The `CGEventTap` itself needs Accessibility permission, but the swallow *decision* lives in
/// the plain handlers, so it is unit-testable without a real tap.
@MainActor
@Suite struct ShortcutMonitorTests {
    @Test func keyShortcutSwallowsMatchingDownRepeatAndUp() {
        let monitor = ShortcutMonitor(shortcut: .key(keyCode: 49, flags: Shortcut.optionFlag)) // ⌥Space
        var began = 0
        var ended = 0
        monitor.onPressed = { began += 1 }
        monitor.onReleased = { ended += 1 }

        // ⌥Space down begins the press and is swallowed (must not reach the app).
        #expect(monitor.handleKeyDown(keyCode: 49, flagsRaw: Shortcut.optionFlag) == true)
        #expect(began == 1)
        // Auto-repeat keyDown while held stays swallowed, without re-firing onPressed.
        #expect(monitor.handleKeyDown(keyCode: 49, flagsRaw: Shortcut.optionFlag) == true)
        #expect(began == 1)
        // Space up ends the press and is swallowed too.
        #expect(monitor.handleKeyUp(keyCode: 49) == true)
        #expect(ended == 1)
    }

    @Test func plainKeyPassesThroughAndDoesNotEatKeyUp() {
        let monitor = ShortcutMonitor(shortcut: .key(keyCode: 49, flags: Shortcut.optionFlag)) // ⌥Space
        // Plain Space (no ⌥) is not the shortcut: its keyDown must reach the app…
        #expect(monitor.handleKeyDown(keyCode: 49, flagsRaw: 0) == false)
        // …and, since no hold started, its keyUp must not be swallowed either (else a stuck key).
        #expect(monitor.handleKeyUp(keyCode: 49) == false)
    }

    @Test func modifierOnlyShortcutNeverSwallowsKeyEvents() {
        let monitor = ShortcutMonitor(shortcut: .defaultShortcut) // right ⌘, delivered via flagsChanged
        #expect(monitor.handleKeyDown(keyCode: 54, flagsRaw: Shortcut.commandFlag) == false)
        #expect(monitor.handleKeyUp(keyCode: 54) == false)
    }

    // MARK: - Esc cancel

    @Test func armedEscapeSwallowsDownAndUpAndFiresCallbackOnce() {
        let monitor = ShortcutMonitor(shortcut: .defaultShortcut)
        var cancels = 0
        monitor.isEscapeArmed = true
        monitor.onEscapeCancel = {
            cancels += 1
            monitor.isEscapeArmed = false // mimic AppState: disarm inside the callback
        }

        #expect(monitor.handleKeyDown(keyCode: 53, flagsRaw: 0) == true)
        #expect(cancels == 1)
        // Auto-repeat downs after disarm stay swallowed until the pair is closed…
        #expect(monitor.handleKeyDown(keyCode: 53, flagsRaw: 0) == true)
        #expect(cancels == 1)
        // …the keyUp closes it, swallowed exactly once…
        #expect(monitor.handleKeyUp(keyCode: 53) == true)
        // …and the next Esc pair passes through untouched.
        #expect(monitor.handleKeyDown(keyCode: 53, flagsRaw: 0) == false)
        #expect(monitor.handleKeyUp(keyCode: 53) == false)
        #expect(cancels == 1)
    }

    @Test func disarmedEscapePassesThrough() {
        let monitor = ShortcutMonitor(shortcut: .defaultShortcut)
        var cancels = 0
        monitor.onEscapeCancel = { cancels += 1 }
        #expect(monitor.handleKeyDown(keyCode: 53, flagsRaw: 0) == false)
        #expect(monitor.handleKeyUp(keyCode: 53) == false)
        #expect(cancels == 0)
    }

    @Test func modifiedEscapePassesThroughEvenWhenArmed() {
        let monitor = ShortcutMonitor(shortcut: .defaultShortcut)
        var cancels = 0
        monitor.isEscapeArmed = true
        monitor.onEscapeCancel = { cancels += 1 }
        // ⌥Esc is somebody's app shortcut, not our cancel.
        #expect(monitor.handleKeyDown(keyCode: 53, flagsRaw: Shortcut.optionFlag) == false)
        #expect(cancels == 0)
    }
}
