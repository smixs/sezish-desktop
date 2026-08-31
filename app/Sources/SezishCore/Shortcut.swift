import Foundation

/// How a shortcut is matched against keyboard events.
public enum ShortcutKind: String, Codable, Sendable {
    /// A modifier-only push-to-talk key (e.g. right ⌘). Matched on `.flagsChanged`,
    /// because bare modifiers emit no keyDown/keyUp.
    case modifierOnly
    /// A normal key plus optional modifiers (e.g. ⌥Space). Matched on keyDown/keyUp.
    case key
}

/// A pure, `Codable` description of a push-to-talk shortcut with no AppKit/CoreGraphics
/// dependency, so its match logic is unit-testable and it persists to UserDefaults as JSON.
/// The app layer feeds it raw values straight from `CGEvent`: `keyCode` from
/// `.keyboardEventKeycode` and `modifierFlagsRaw` from `CGEventFlags.rawValue`.
public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var kind: ShortcutKind
    /// Hardware keycode. For `.modifierOnly` this is the physical modifier key (side-specific),
    /// or `genericModifierKeyCode` to match either side. For `.key` it is the main key.
    public var keyCode: Int
    /// Raw modifier mask. Bit values mirror `CGEventFlags` (see the flag constants below), so
    /// the app can compare `CGEventFlags.rawValue` against this without any conversion.
    public var modifierFlagsRaw: UInt64

    public init(kind: ShortcutKind, keyCode: Int, modifierFlagsRaw: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlagsRaw
    }
}

// MARK: - Keycodes

public extension Shortcut {
    static let leftCommand = 55
    static let rightCommand = 54
    static let leftShift = 56
    static let rightShift = 60
    static let leftOption = 58
    static let rightOption = 61
    static let leftControl = 59
    static let rightControl = 62
    static let fn = 63

    /// Sentinel keycode for "any side" of a modifier: only the flags are compared, the
    /// physical key is ignored. `UInt16.max` can never be a real hardware keycode.
    static let genericModifierKeyCode = Int(UInt16.max)
}

// MARK: - Modifier flag bits
//
// These raw values are the ABI-stable bit positions of `CGEventFlags` in CoreGraphics
// (`CGEventTypes.h`): maskShift=1<<17, maskControl=1<<18, maskAlternate=1<<19,
// maskCommand=1<<20, maskSecondaryFn=1<<23. Keeping them here — rather than importing
// CoreGraphics — is what lets this type stay pure and testable; the app layer maps
// `CGEventFlags.rawValue` onto these directly, and the values coincide exactly.

public extension Shortcut {
    static let shiftFlag: UInt64 = 1 << 17
    static let controlFlag: UInt64 = 1 << 18
    static let optionFlag: UInt64 = 1 << 19
    static let commandFlag: UInt64 = 1 << 20
    static let fnFlag: UInt64 = 1 << 23

    /// Every modifier bit this type reasons about, used to mask out irrelevant CGEvent bits
    /// (caps-lock, numeric-pad, non-coalesced, device-dependent) before comparing.
    static let allModifierFlags: UInt64 =
        shiftFlag | controlFlag | optionFlag | commandFlag | fnFlag
}

// MARK: - Constructors

public extension Shortcut {
    static func modifierOnly(keyCode: Int, flags: UInt64) -> Shortcut {
        Shortcut(kind: .modifierOnly, keyCode: keyCode, modifierFlagsRaw: flags)
    }

    static func key(keyCode: Int, flags: UInt64) -> Shortcut {
        Shortcut(kind: .key, keyCode: keyCode, modifierFlagsRaw: flags)
    }

    /// The out-of-the-box push-to-talk key: hold the right ⌘.
    static let defaultShortcut = Shortcut.modifierOnly(keyCode: rightCommand, flags: commandFlag)
}

// MARK: - Matching (pure, event-driven)

public extension Shortcut {
    /// `.modifierOnly` press: the required key/side is active and its flag has appeared.
    func matchesModifierBegin(eventKeyCode: Int, eventFlagsRaw: UInt64) -> Bool {
        guard kind == .modifierOnly, modifierFlagsRaw != 0 else { return false }
        let sideMatches = keyCode == Self.genericModifierKeyCode || eventKeyCode == keyCode
        return sideMatches && containsAll(modifierFlagsRaw, in: eventFlagsRaw)
    }

    /// `.modifierOnly` release: the required flag is no longer fully present. The monitor only
    /// consults this while already holding, so key/side need not be re-checked here.
    func matchesModifierEnd(eventKeyCode: Int, eventFlagsRaw: UInt64) -> Bool {
        guard kind == .modifierOnly else { return false }
        return !containsAll(modifierFlagsRaw, in: eventFlagsRaw)
    }

    /// `.key` press: exact key and exact modifier set (extra modifiers reject the match).
    /// The fn bit is ignored for keys whose events carry a hardware fn flag (arrows, F-keys,
    /// nav block): macOS sets it on their way in, so honoring it would both reject clean
    /// matches and strand stale saves that recorded the spurious bit.
    func matchesKeyDown(eventKeyCode: Int, eventFlagsRaw: UInt64) -> Bool {
        guard kind == .key, eventKeyCode == keyCode else { return false }
        var relevant = Self.allModifierFlags
        if Self.hardwareFunctionKeyCodes.contains(keyCode) { relevant &= ~Self.fnFlag }
        return (eventFlagsRaw & relevant) == (modifierFlagsRaw & relevant)
    }

    /// `.key` release: the main key came up. Modifiers may already be gone, so they are ignored.
    func matchesKeyUp(eventKeyCode: Int) -> Bool {
        kind == .key && eventKeyCode == keyCode
    }

    private func containsAll(_ needed: UInt64, in raw: UInt64) -> Bool {
        (raw & needed) == needed
    }
}

// MARK: - Key classes

public extension Shortcut {
    /// F1–F20 hardware keycodes. These are legal without any modifier (unlike typing keys).
    static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, // F1–F10
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90, // F11–F20
    ]

    /// Keys whose events carry a hardware fn bit (maskSecondaryFn) set by macOS itself:
    /// F-keys, arrows, and the nav block. That bit must not affect matching or recording.
    static let hardwareFunctionKeyCodes: Set<Int> = functionKeyCodes.union([
        123, 124, 125, 126, // ← → ↓ ↑
        115, 116, 117, 119, 121, // Home, Page Up, Forward Delete, End, Page Down
    ])
}

// MARK: - Display (VoiceInk's three-tier naming, kept pure)
//
// Tier 2 — the live keyboard layout — needs Carbon (UCKeyTranslate), which this type must not
// import. It is injected as a `(Int) -> String?` resolver instead; the app layer passes
// `KeyboardLayout.character(for:)` and tests pass stubs. With no resolver the QWERTY table wins.

public extension Shortcut {
    /// Fixed names for non-typing keys (Space, arrows, F-keys, keypad…): tier 1, beats layout.
    static func specialKeyName(_ keyCode: Int) -> String? { specialKeyNames[keyCode] }

    /// US-QWERTY legend for typing keys: tier 3, the fallback when no resolver answers.
    static func qwertyKeyName(_ keyCode: Int) -> String? { qwertyFallbackKeyNames[keyCode] }

    /// Human-readable name of a main key: special table → live layout → QWERTY → "Key N".
    static func keyName(for keyCode: Int, layout resolver: (Int) -> String? = { _ in nil }) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let live = resolver(keyCode) { return live.uppercased() }
        return qwertyFallbackKeyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Modifier symbols in the canonical Apple order: ⌃ ⌥ ⇧ ⌘ Fn.
    var modifierTokens: [String] {
        var tokens: [String] = []
        if modifierFlagsRaw & Self.controlFlag != 0 { tokens.append("⌃") }
        if modifierFlagsRaw & Self.optionFlag != 0 { tokens.append("⌥") }
        if modifierFlagsRaw & Self.shiftFlag != 0 { tokens.append("⇧") }
        if modifierFlagsRaw & Self.commandFlag != 0 { tokens.append("⌘") }
        if modifierFlagsRaw & Self.fnFlag != 0 { tokens.append("Fn") }
        return tokens
    }

    /// Localizable label: side words ("Левый"/"Chap"/"Left") come from the caller because this
    /// type has no access to the app's `Strings`. E.g. "Правый ⌘", "⌥ + Q", "⌥ + ⌘".
    func displayString(
        leftWord: String,
        rightWord: String,
        layout resolver: (Int) -> String? = { _ in nil }
    ) -> String {
        switch kind {
        case .key:
            return (modifierTokens + [Self.keyName(for: keyCode, layout: resolver)])
                .joined(separator: " + ")
        case .modifierOnly:
            if let side = sideWord(leftWord: leftWord, rightWord: rightWord) {
                return side
            }
            // Generic sentinel or a multi-modifier chord: the symbols say it all.
            return modifierTokens.joined(separator: " + ")
        }
    }

    /// Neutral-English fallback for logs and tests; the UI goes through the app layer's
    /// localized `displayLabel(strings:)`.
    var displayString: String { displayString(leftWord: "Left", rightWord: "Right") }

    /// Side-specific name for a single held modifier ("Left ⌘"); nil when the keycode is not a
    /// known side or more than one modifier bit is set (then the chord tokens are shown).
    private func sideWord(leftWord: String, rightWord: String) -> String? {
        guard modifierFlagsRaw & (modifierFlagsRaw - 1) == 0 else { return nil }
        switch keyCode {
        case Self.leftCommand: return "\(leftWord) ⌘"
        case Self.rightCommand: return "\(rightWord) ⌘"
        case Self.leftShift: return "\(leftWord) ⇧"
        case Self.rightShift: return "\(rightWord) ⇧"
        case Self.leftOption: return "\(leftWord) ⌥"
        case Self.rightOption: return "\(rightWord) ⌥"
        case Self.leftControl: return "\(leftWord) ⌃"
        case Self.rightControl: return "\(rightWord) ⌃"
        case Self.fn: return "Fn"
        default: return nil
        }
    }

    private static let specialKeyNames: [Int: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 126: "↑", 125: "↓",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14",
        113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        65: "Keypad .", 75: "Keypad /", 67: "Keypad *", 78: "Keypad -", 69: "Keypad +",
        76: "Keypad Enter", 81: "Keypad =",
    ]

    private static let qwertyFallbackKeyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R",
        1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]
}
