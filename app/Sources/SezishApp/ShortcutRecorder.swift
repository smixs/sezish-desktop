import AppKit
import Observation
import SwiftUI
import SezishCore

/// A button that records an arbitrary push-to-talk ``Shortcut`` — a modifier-only key
/// (hold right ⌘) or a key combination (⌥Space) — ported from VoiceInk's recorder.
///
/// Click to enter record mode: a *local* `NSEvent` monitor (settings window is focused, so no
/// extra permission is needed) captures the next gesture and swallows it (`return nil`) so the
/// keys never leak into the UI. A modifier-only hold is committed once all modifiers are
/// released; a plain key is committed on its keyDown.
struct ShortcutRecorder: View {
    /// Ready-made localized label of the current shortcut (`displayLabel(strings:)`).
    let currentLabel: String
    let prompt: String
    let helpText: String
    /// Shown (accent, transient) when a bare typing key is rejected for lack of a modifier.
    let needsModifierText: String
    let onCommit: (Shortcut) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = RecorderSession()
    @State private var pulsing = false

    private var label: String {
        guard session.isRecording else { return currentLabel }
        return session.needsModifierHint ? needsModifierText : prompt
    }

    var body: some View {
        Button {
            session.toggle(onCommit: onCommit)
        } label: {
            Text(label)
                // Solid accent while recording: a 1px gradient border only shimmers.
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(session.isRecording ? Brand.accent : Brand.text)
                .frame(minWidth: 160)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.control)
                        .strokeBorder(
                            session.isRecording
                                ? Brand.accent.opacity(reduceMotion || pulsing ? 1 : 0.45)
                                : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .task(id: session.isRecording) {
            // Reduce Motion keeps the border at full accent instead of breathing.
            guard session.isRecording, !reduceMotion else {
                pulsing = false
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .onDisappear { session.cancel() }
    }
}

/// Owns the transient `NSEvent` monitor and accumulates the in-progress gesture.
/// `@Observable` so `isRecording` drives the button label.
@Observable
final class RecorderSession {
    private(set) var isRecording = false
    /// Set when a bare typing key was rejected; cleared by a short timer or the next event.
    private(set) var needsModifierHint = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onCommit: ((Shortcut) -> Void)?
    @ObservationIgnored private var peakFlags: UInt64 = 0
    @ObservationIgnored private var lastModifierKeyCode: Int?
    @ObservationIgnored private var sawModifier = false
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    func toggle(onCommit: @escaping (Shortcut) -> Void) {
        if isRecording { cancel() } else { start(onCommit: onCommit) }
    }

    private func start(onCommit: @escaping (Shortcut) -> Void) {
        self.onCommit = onCommit
        peakFlags = 0
        lastModifierKeyCode = nil
        sawModifier = false
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors always fire on the main thread; safe to hop onto the actor.
            MainActor.assumeIsolated { self?.handle(event) }
            return nil // swallow the event so recorded keys don't reach the settings UI
        }
    }

    /// Stops recording without committing (also invoked on view disappearance).
    func cancel() {
        guard isRecording else { return }
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCommit = nil
        isRecording = false
        hintTask?.cancel()
        hintTask = nil
        needsModifierHint = false
    }

    /// Flashes the "add a modifier" hint without leaving record mode.
    private func flashNeedsModifierHint() {
        needsModifierHint = true
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.needsModifierHint = false
        }
    }

    private func commit(_ shortcut: Shortcut) {
        let handler = onCommit
        stop()
        handler?(shortcut)
    }

    private func handle(_ event: NSEvent) {
        needsModifierHint = false
        switch event.type {
        case .flagsChanged:
            let flags = Self.modifierFlags(event)
            if flags != 0 {
                // A modifier went down (or another joined it): remember the physical key and
                // union its bit into the peak set.
                peakFlags |= flags
                sawModifier = true
                lastModifierKeyCode = Int(event.keyCode)
            } else if sawModifier, peakFlags != 0, let keyCode = lastModifierKeyCode {
                // All modifiers released after at least one press. A single modifier commits
                // side-specifically (`x & (x-1) == 0` is the single-bit test). A multi-modifier
                // hold stores just one side's keyCode — its begin-event may not carry every
                // flag and could never match — so it commits as a generic chord instead: only
                // the flags are compared, either side works.
                if peakFlags & (peakFlags - 1) == 0 {
                    commit(.modifierOnly(keyCode: keyCode, flags: peakFlags))
                } else {
                    commit(.modifierOnly(keyCode: Shortcut.genericModifierKeyCode, flags: peakFlags))
                }
            } else {
                // Flags fell to zero with nothing captured — reset and keep waiting.
                peakFlags = 0
                sawModifier = false
                lastModifierKeyCode = nil
            }

        case .keyDown:
            let keyCode = Int(event.keyCode)
            var flags = Self.modifierFlags(event)
            // Arrows, F-keys and the nav block carry a hardware fn bit; recording it would
            // both mislabel the shortcut ("Fn + F6") and break matching.
            if Shortcut.hardwareFunctionKeyCodes.contains(keyCode) { flags &= ~Shortcut.fnFlag }
            if keyCode == 53, flags == 0 { // Esc with no modifiers cancels
                cancel()
            } else if flags == 0, !Shortcut.functionKeyCodes.contains(keyCode) {
                // A bare typing key would be globally swallowed on every press — refuse it
                // and keep listening. F-keys are fine bare.
                flashNeedsModifierHint()
            } else {
                commit(.key(keyCode: keyCode, flags: flags))
            }

        default:
            break
        }
    }

    /// Maps an `NSEvent`'s modifiers onto ``Shortcut``'s `CGEventFlags`-compatible raw bits.
    /// `NSEvent.ModifierFlags` and `CGEventFlags` share identical raw bit positions for
    /// shift/control/option/command/function, so masking by `allModifierFlags` is exact — it
    /// also drops caps-lock, numeric-pad and help bits that must not affect matching.
    private static func modifierFlags(_ event: NSEvent) -> UInt64 {
        UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            & Shortcut.allModifierFlags
    }
}
