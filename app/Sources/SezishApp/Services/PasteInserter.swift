import AppKit
import Carbon
import CoreGraphics
import SezishCore

enum InsertError: LocalizedError {
    case secureInput

    var errorDescription: String? {
        switch self {
        case .secureInput:
            "The focused field blocks synthetic input (secure entry). Paste manually with ⌘V."
        }
    }
}

/// Inserts text by staging it on the pasteboard and synthesizing ⌘V. The
/// transcript deliberately STAYS on the pasteboard afterwards (no snapshot
/// restore): the last dictation is always one ⌘V away, and a failed insert
/// still leaves the text in hand. `@MainActor` is load-bearing: the TIS
/// keyboard-layout API (`TSMGetInputSourceProperty` inside `keyCodeForV`)
/// dispatch-asserts the main queue on macOS 14+ — calling it from the
/// cooperative pool crashes with SIGTRAP (seen in production 2026-07-24).
@MainActor
final class PasteInserter: TextInserter {
    func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Secure input blocks synthetic ⌘V; the transcript is already on the
        // pasteboard, so the "paste manually" instruction is actionable.
        if IsSecureEventInputEnabled() {
            throw InsertError.secureInput
        }

        postCommandV()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - Synthetic paste

    private func postCommandV() {
        let key = Self.keyCodeForV()
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The physical key that produces "v" in the active layout, so ⌘V pastes regardless of
    /// QWERTY/AZERTY/etc. Falls back to `kVK_ANSI_V` (9).
    private static func keyCodeForV() -> CGKeyCode {
        let fallback: CGKeyCode = 9
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var result = fallback
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return
            }
            let kbdType = UInt32(LMGetKbdType())
            for code in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    kbdType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                if status == noErr, length > 0, chars[0] == UniChar(UnicodeScalar("v").value) {
                    result = code
                    break
                }
            }
        }
        return result
    }

}
