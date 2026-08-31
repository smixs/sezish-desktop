# Configurable dictation hotkey

The hotkey is user-configurable, reaching macOS parity: a `Shortcut` value type
(`sez-hotkey/src/shortcut.rs`, ported from `app/Sources/SezishCore/Shortcut.swift`)
is either a bare side-specific modifier (`ModifierOnly { vk }`) or a main key plus an
exact modifier set (`Key { vk, mods }`, e.g. Alt+Q, bare F9). It persists in
`settings.json` as `{ "shortcut": { "kind": "modifier"|"key", "vk", "mods" } }` and is
recorded in the settings UI (click → press a gesture), mirroring VoiceInk's recorder.

This supersedes the fixed-key assumption in [0008](0008-default-hotkey-right-ctrl.md):
Right Ctrl remains the **default**, but is no longer the only option.

Decisions:
- **Combos are swallowed, bare modifiers are not.** A matched `Key` combo returns
  `LRESULT(1)` so the letter never reaches the focused app; a `ModifierOnly` key passes
  through and keeps working normally (Right Ctrl still acts as Ctrl).
- **Matching is pure and lives in `sez-hotkey`** (no `windows` crate), unit-tested on
  macOS CI. The WH_KEYBOARD_LL adapter only feeds it `vkCode`, the extended flag, and the
  `GetAsyncKeyState` modifier set, then acts on the returned decision. Per
  [0003](0003-macos-reference-semantics.md) the semantics (exact-modifier match, synthesised
  release when a required modifier is lifted first) come from the Swift reference.
- **IPC is extended additively, not broken.** `set_hotkey_key`, `begin_hotkey_capture`,
  `end_hotkey_capture` are added to the frozen contract from [0002](0002-test-seams.md);
  the global hook is suspended while the recorder captures so recording a key can't also
  start a dictation.
- **Ships as 0.1.1** — a patch bump on the independent Windows version line.
