# Spike: WH_KEYBOARD_LL Right-Ctrl + self-injection ignore (ticket #4)

Proves: a low-level keyboard hook on a dedicated thread with its own message pump
detects bare **Right** Ctrl press and release (distinct from Left via the extended
flag), collapses auto-repeat, and — critically — ignores a synthetic Ctrl+V that we
inject ourselves (tagged in `dwExtraInfo`) while still seeing real keypresses.

Run: `cargo run --release`. Then:
1. Tap and hold Right Ctrl a few times — watch `RCTRL DOWN` / `RCTRL UP` with ms deltas; a held key prints DOWN once, not repeatedly.
2. Press Left Ctrl — should print `left ctrl ignored (not our key)`.
3. After ~3 s the spike injects a tagged Ctrl+V itself: expect `IGNORED self-injection (tag matched)`, NOT a spurious RCTRL/V line.

PASS = real Right-Ctrl edges print cleanly, auto-repeat is collapsed, and the self-injected chord is reported IGNORED.
