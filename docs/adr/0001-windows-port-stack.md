# Windows port: Tauri v2 shell over a Rust crate workspace

The Windows port (`win/`) is a Tauri v2 app whose logic lives in plain Rust crates: `sez-core` (coordinator + traits), `sez-hotkey`, `sez-audio`, `sez-asr-cloud`, `sez-asr-local`, `sez-inject`, `sez-history`. Chosen after a code-level survey of 8 OSS dictation apps (`docs/windows-port-research.md`): Tauri gives tray + updater + webview settings at ~15-25 MB installers, while all platform logic stays testable Rust. Pure native Win32 was rejected for v1 — it saves single-digit MB but costs a from-scratch settings UI.

## Consequences

All business logic is cross-platform and unit-tested on macOS; WinAPI lives only in thin adapters tested on a self-hosted Windows runner.
