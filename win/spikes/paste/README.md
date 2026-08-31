# Spike: clipboard + one batched SendInput paste (ticket #5)

Proves Uzbek Latin with modifier apostrophes (oʻ/gʻ, U+02BB), Cyrillic and an em dash
survive clipboard → one batched Ctrl+V chord, byte-intact, across target apps.

Run: `cargo run --release`, then within the 3 s countdown focus a target (Notepad,
Chrome address bar, VSCode). It pastes `oʻzbekcha gʻoya — тест ҳ` 20× with 400 ms gaps.

PASS = every paste lands identical, apostrophes and Cyrillic unmangled, in all targets.
No clipboard restore here — that's product code (ADR-0005).
