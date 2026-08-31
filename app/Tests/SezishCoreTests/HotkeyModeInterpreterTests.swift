import Foundation
import Testing
@testable import SezishCore

/// Drives the interpreter with a hand-cranked clock and recording flag, asserting the
/// command stream for both modes. The `recording` box stands in for the coordinator: tests
/// flip it exactly when the real pipeline would.
@Suite struct HotkeyModeInterpreterTests {
    /// Test double wiring: mutable clock + recording state captured by the closures.
    private final class Harness {
        var now: TimeInterval = 1000
        var recording = false
        private(set) var interpreter: HotkeyModeInterpreter!

        init(mode: HotkeyMode) {
            interpreter = HotkeyModeInterpreter(
                mode: mode,
                isRecording: { [unowned self] in recording },
                now: { [unowned self] in now }
            )
        }

        /// Applies a command the way AppState would, keeping `recording` truthful.
        func apply(_ command: HotkeyModeInterpreter.Command) {
            switch command {
            case .start: recording = true
            case .stop: recording = false
            case .none: break
            }
        }
    }

    // MARK: - Hold

    @Test func holdPressStartsReleaseStops() {
        let h = Harness(mode: .hold)
        let down = h.interpreter.keyPressed()
        #expect(down == .start)
        h.apply(down)
        let up = h.interpreter.keyReleased()
        #expect(up == .stop)
    }

    @Test func holdReleaseWithoutPressIsNoOp() {
        let h = Harness(mode: .hold)
        #expect(h.interpreter.keyReleased() == .none)
    }

    @Test func holdHasNoCooldownForFastConsecutiveTakes() {
        let h = Harness(mode: .hold)
        h.apply(h.interpreter.keyPressed())
        h.apply(h.interpreter.keyReleased())
        h.now += 0.1 // way inside the toggle cooldown — must not matter in hold mode
        #expect(h.interpreter.keyPressed() == .start)
    }

    @Test func holdReleaseAfterFailedStartIsNoOp() {
        let h = Harness(mode: .hold)
        #expect(h.interpreter.keyPressed() == .start)
        // Recording never actually started (mic failure): release must not emit .stop.
        #expect(h.interpreter.keyReleased() == .none)
    }

    // MARK: - Toggle

    @Test func togglePressStartsSecondPressStops() {
        let h = Harness(mode: .toggle)
        let first = h.interpreter.keyPressed()
        #expect(first == .start)
        h.apply(first)
        #expect(h.interpreter.keyReleased() == .none) // latched, release ignored

        h.now += 0.6 // past the cooldown
        let second = h.interpreter.keyPressed()
        #expect(second == .stop)
        h.apply(second)
        #expect(h.interpreter.keyReleased() == .none)
    }

    @Test func toggleCooldownDebouncesTapBounce() {
        let h = Harness(mode: .toggle)
        h.apply(h.interpreter.keyPressed())
        h.apply(h.interpreter.keyReleased())

        h.now += 0.3 // inside the 0.5 s window: bounce, not intent
        #expect(h.interpreter.keyPressed() == .none)
        #expect(h.interpreter.keyReleased() == .none) // its release is inert too

        h.now += 0.3 // now 0.6 s after the accepted press
        #expect(h.interpreter.keyPressed() == .stop)
    }

    @Test func repeatedPressWithoutReleaseIsSwallowed() {
        let h = Harness(mode: .toggle)
        h.apply(h.interpreter.keyPressed())
        h.now += 5 // cooldown long gone; only the isPressed gate can block this
        #expect(h.interpreter.keyPressed() == .none) // auto-repeat while held
    }

    @Test func externallyEndedRecordingDoesNotStrandTheLatch() {
        let h = Harness(mode: .toggle)
        h.apply(h.interpreter.keyPressed())
        h.apply(h.interpreter.keyReleased())

        h.recording = false // Esc cancelled the take out-of-band

        h.now += 0.6
        #expect(h.interpreter.keyPressed() == .start) // fresh start, not a stray .stop
    }

    @Test func resetForgetsPressAndCooldown() {
        let h = Harness(mode: .toggle)
        _ = h.interpreter.keyPressed() // recording never starts (e.g. mode flip mid-press)
        h.interpreter.reset()
        // Immediately after reset — inside what was the cooldown window and without a
        // release — a fresh press must go straight through.
        #expect(h.interpreter.keyPressed() == .start)
    }
}
