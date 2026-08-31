import Carbon.HIToolbox
import Foundation
import SezishCore

/// Live keyboard-layout key naming (port of VoiceInk's UCKeyTranslate path), tier 2 of
/// ``Shortcut/keyName(for:layout:)``. `nonisolated`: the app target defaults to MainActor,
/// but this must be passable as SezishCore's nonisolated `(Int) -> String?` resolver.
enum KeyboardLayout {
    /// The unshifted legend of a typing key on the current layout, uppercased by the caller.
    /// Returns nil — deferring to the QWERTY table — for control characters and for any
    /// non-ASCII legend: on Cyrillic layouts the Latin half of the dual-legend keycap is what
    /// the label should show, and it must not flip when the user switches layouts.
    nonisolated static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutBytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0, // no modifiers: the unshifted legend
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }

        let result = String(utf16CodeUnits: chars, count: length)
        guard !result.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }),
              result.unicodeScalars.allSatisfy(\.isASCII)
        else { return nil }
        return result
    }
}

extension Shortcut {
    /// The localized, layout-aware label the UI shows for this shortcut.
    func displayLabel(strings: Strings) -> String {
        displayString(
            leftWord: strings.keyLeft,
            rightWord: strings.keyRight,
            layout: KeyboardLayout.character(for:)
        )
    }
}
