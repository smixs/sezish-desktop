# Spikes — throwaway de-risking binaries

Not product code, not in the `win/` workspace, never CI'd, never shipped. Each proves one risky Windows mechanic on live hardware before the real crate is built.

- `hook/` — ticket #4: WH_KEYBOARD_LL Right-Ctrl hold/tap detection + self-injection ignore
- `paste/` — ticket #5: clipboard + one batched SendInput pastes Uzbek oʻ/gʻ + Cyrillic
- `ort-smoke/` — ticket #6: `ort` linked to a dynamically-loaded onnxruntime.dll, no download-binaries (ARM64: proves linking only, not the x64 AVX2 regression)

Run on the win-live VM: `cd win/spikes/<name> && cargo run --release`.
