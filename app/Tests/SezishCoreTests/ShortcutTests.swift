import Foundation
import Testing
@testable import SezishCore

@Suite struct ShortcutTests {
    // MARK: - Persistence

    @Test func codableRoundTrip() throws {
        let originals: [Shortcut] = [
            .defaultShortcut,
            .modifierOnly(keyCode: Shortcut.leftOption, flags: Shortcut.optionFlag),
            .key(keyCode: 49, flags: Shortcut.optionFlag), // ⌥Space
        ]
        for original in originals {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Shortcut.self, from: data)
            #expect(decoded == original)
        }
    }

    // MARK: - Default

    @Test func defaultShortcutIsRightCommand() {
        let d = Shortcut.defaultShortcut
        #expect(d.kind == .modifierOnly)
        #expect(d.keyCode == Shortcut.rightCommand)
        #expect(d.keyCode == 54)
        #expect(d.modifierFlagsRaw == Shortcut.commandFlag)
    }

    // MARK: - Modifier-only begin/end (right ⌘, keyCode 54)

    @Test func modifierBeginWhenKeyAndFlagPresent() {
        let rightCmd = Shortcut.defaultShortcut
        #expect(rightCmd.matchesModifierBegin(
            eventKeyCode: 54, eventFlagsRaw: Shortcut.commandFlag))
    }

    @Test func modifierBeginRejectsWithoutFlag() {
        let rightCmd = Shortcut.defaultShortcut
        // Correct keyCode but the command bit is not set yet.
        #expect(!rightCmd.matchesModifierBegin(eventKeyCode: 54, eventFlagsRaw: 0))
    }

    @Test func modifierEndWhenFlagCleared() {
        let rightCmd = Shortcut.defaultShortcut
        #expect(rightCmd.matchesModifierEnd(eventKeyCode: 54, eventFlagsRaw: 0))
        // Flag still present → not an end.
        #expect(!rightCmd.matchesModifierEnd(
            eventKeyCode: 54, eventFlagsRaw: Shortcut.commandFlag))
    }

    @Test func rightCommandDoesNotBeginOnLeftCommand() {
        let rightCmd = Shortcut.defaultShortcut
        // Left ⌘ (keyCode 55) still raises the command flag, but the side differs.
        #expect(!rightCmd.matchesModifierBegin(
            eventKeyCode: 55, eventFlagsRaw: Shortcut.commandFlag))
    }

    @Test func genericModifierBeginsOnEitherSide() {
        let anyCommand = Shortcut.modifierOnly(
            keyCode: Shortcut.genericModifierKeyCode, flags: Shortcut.commandFlag)
        #expect(anyCommand.matchesModifierBegin(
            eventKeyCode: 54, eventFlagsRaw: Shortcut.commandFlag)) // right
        #expect(anyCommand.matchesModifierBegin(
            eventKeyCode: 55, eventFlagsRaw: Shortcut.commandFlag)) // left
    }

    // MARK: - Key combinations (⌥Space)

    @Test func keyDownMatchesExactModifiers() {
        let optSpace = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag)
        #expect(optSpace.matchesKeyDown(
            eventKeyCode: 49, eventFlagsRaw: Shortcut.optionFlag))
    }

    @Test func keyDownRejectsExtraModifier() {
        let optSpace = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag)
        // ⌥⌘Space carries an extra modifier the shortcut does not ask for.
        #expect(!optSpace.matchesKeyDown(
            eventKeyCode: 49, eventFlagsRaw: Shortcut.optionFlag | Shortcut.commandFlag))
    }

    @Test func keyDownRejectsWrongKey() {
        let optSpace = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag)
        #expect(!optSpace.matchesKeyDown(
            eventKeyCode: 48, eventFlagsRaw: Shortcut.optionFlag))
    }

    @Test func keyDownIgnoresIrrelevantSystemBits() {
        // Caps-lock (maskAlphaShift, 1<<16) and non-coalesced (1<<8) bits must be masked out.
        let optSpace = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag)
        let noise = Shortcut.optionFlag | (1 << 16) | (1 << 8)
        #expect(optSpace.matchesKeyDown(eventKeyCode: 49, eventFlagsRaw: noise))
    }

    @Test func modifierMethodsIgnoreWrongKind() {
        let optSpace = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag)
        #expect(!optSpace.matchesModifierBegin(
            eventKeyCode: 49, eventFlagsRaw: Shortcut.optionFlag))
        let rightCmd = Shortcut.defaultShortcut
        #expect(!rightCmd.matchesKeyDown(
            eventKeyCode: 54, eventFlagsRaw: Shortcut.commandFlag))
    }

    // MARK: - Flag constants match CoreGraphics ABI

    @Test func flagConstantsMatchCGEventFlagsABI() {
        #expect(Shortcut.shiftFlag == 1 << 17)   // maskShift
        #expect(Shortcut.controlFlag == 1 << 18) // maskControl
        #expect(Shortcut.optionFlag == 1 << 19)  // maskAlternate
        #expect(Shortcut.commandFlag == 1 << 20) // maskCommand
        #expect(Shortcut.fnFlag == 1 << 23)      // maskSecondaryFn
    }

    // MARK: - fn bit on hardware function keys

    @Test func fnBitIgnoredForHardwareFunctionKeys() {
        // F6 events always carry the hardware fn bit; a clean saved shortcut must still match…
        let f6 = Shortcut.key(keyCode: 97, flags: 0)
        #expect(f6.matchesKeyDown(eventKeyCode: 97, eventFlagsRaw: Shortcut.fnFlag))
        // …and a stale save that recorded the spurious bit must keep working too.
        let staleF6 = Shortcut.key(keyCode: 97, flags: Shortcut.fnFlag)
        #expect(staleF6.matchesKeyDown(eventKeyCode: 97, eventFlagsRaw: 0))
        // A typing key is unaffected: fn there is a real, distinct modifier.
        let fnSpace = Shortcut.key(keyCode: 49, flags: Shortcut.fnFlag)
        #expect(!fnSpace.matchesKeyDown(eventKeyCode: 49, eventFlagsRaw: 0))
    }

    // MARK: - Key naming (three-tier)

    @Test func specialNamesWinOverEverything() {
        #expect(Shortcut.keyName(for: 49) == "Space")
        #expect(Shortcut.keyName(for: 53) == "Esc")
        #expect(Shortcut.keyName(for: 97) == "F6")
        #expect(Shortcut.keyName(for: 123) == "←")
        // Even a resolver answer must not override a special name.
        #expect(Shortcut.keyName(for: 49, layout: { _ in "x" }) == "Space")
    }

    @Test func layoutResolverBeatsQwerty() {
        #expect(Shortcut.keyName(for: 12, layout: { _ in "й" }) == "Й")
    }

    @Test func nilResolverFallsBackToQwerty() {
        #expect(Shortcut.keyName(for: 12) == "Q") // the old UI showed "Key 12"
        #expect(Shortcut.keyName(for: 46) == "M") // …and "Key 46"
    }

    @Test func unknownKeyCodeFallsBackToKeyN() {
        #expect(Shortcut.keyName(for: 190) == "Key 190")
    }

    @Test func modifierTokensInCanonicalOrder() {
        let all = Shortcut.key(
            keyCode: 49,
            flags: Shortcut.commandFlag | Shortcut.shiftFlag | Shortcut.fnFlag
                | Shortcut.optionFlag | Shortcut.controlFlag)
        #expect(all.modifierTokens == ["⌃", "⌥", "⇧", "⌘", "Fn"])
    }

    // MARK: - Display strings

    @Test func displayStringInjectsSideWords() {
        let rightCmd = Shortcut.defaultShortcut
        #expect(rightCmd.displayString(leftWord: "Левый", rightWord: "Правый") == "Правый ⌘")
        #expect(rightCmd.displayString == "Right ⌘")
        let fn = Shortcut.modifierOnly(keyCode: Shortcut.fn, flags: Shortcut.fnFlag)
        #expect(fn.displayString == "Fn")
    }

    @Test func keyComboDisplayJoinsTokens() {
        let optQ = Shortcut.key(keyCode: 12, flags: Shortcut.optionFlag)
        #expect(optQ.displayString == "⌥ + Q")
        let combo = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag | Shortcut.commandFlag)
        #expect(combo.displayString == "⌥ + ⌘ + Space")
    }

    @Test func genericChordDisplaysAsTokens() {
        let chord = Shortcut.modifierOnly(
            keyCode: Shortcut.genericModifierKeyCode,
            flags: Shortcut.optionFlag | Shortcut.commandFlag)
        #expect(chord.displayString == "⌥ + ⌘")
    }
}
