# sezish desktop — agent guide

Closed-source speech product for the Uzbek market (uz/ru UI), sold in Uzbekistan and distributed from `dl.sezi.sh` — not from GitHub releases. This repository holds the desktop line: dictation (hold-to-talk) and meeting recording with transcription and AI summaries.

This file is the canonical index for agents. There is no `CLAUDE.md` in this repo.

## Parts

| Part | What it is | Stack | Version | Tests |
|---|---|---|---|---|
| `app/` | macOS menu-bar app. **Reference implementation** — behavior and constants come from here | Swift 6 / SwiftUI, plain SPM + Makefile | 0.1.14 (build 15) | 297+ (Swift Testing) |
| `win/` | Windows dictation port, early beta | Tauri v2 (=2.11.5) + Rust workspace | 0.1.7 in code, not yet built (own version line, ADR-0015) | 130 |
| `./sezish` | CLI meeting transcriber, single-file Python (`uv run --script`) | onnx-asr + Silero VAD, CPU only | shipped via `install.sh` | — |
| `docs/` | ADRs, Windows-port research | — | — | — |
| `assets/` | Shared art | — | — | — |

Notes per part:

- **`app/`** — dictation (hold-to-talk), meeting recording with «Me/Them» diarization (ADR-0013), AI summaries through the user's own Claude Code / Codex CLI (ADR-0014), meeting hook (ADR-0012), Sparkle auto-update against `dl.sezi.sh/appcast.xml`. Two selectable on-device models (`AsrModel`, Settings → Recognition): the multilingual character-level one (ru/uz/kk/ky, no punctuation, default, pulled from HuggingFace) and a Russian+English one with punctuation and casing (subword vocab, pulled from `dl.sezi.sh/models/`); one `CtcDecoder` serves both, the unused downloaded model can be deleted from the same pane. «Launch hidden» skips the Settings window on a manual launch. A take whose text never came out keeps its audio and can be recognised again from the menu or the History tab (dictations plus meetings): failed dictations sit outside the FIFO eviction, and a failed meeting parks its stems in `.stems-<base>` next to the recording until a retry succeeds. Since 0.1.13 there is a third dictation engine, `gemini-3.5-transcribe-live` over a WebSocket (Live API, manual VAD, one persistent session held by a 10 s keepalive ping and reconnected after a long idle), running on the user's own Google AI Studio key, typed by hand in Settings → Recognition; two modes, SMART and VERBATIM, tagged in the History as `gemini/live-smart` or `gemini/live-verbatim` (ADR-0018, `docs/adr/0018-gemini-live-dictation-engine.md`). Since 0.1.14 long local takes are chunked at silences (200 s ONNX mask ceiling) and a retry longer than 30 s goes through batch `generateContent` instead of the Live socket. Meetings stay on the local model. The client logs to the `com.smixs.sezish` subsystem: `/usr/bin/log show --last 30m --predicate 'subsystem == "com.smixs.sezish"' --style compact`.
- **`win/`** — crates `sez-core` / `hotkey` / `audio` / `asr-cloud` / `asr-local` / `inject` / `history` plus `src-tauri`. Recording feedback since 0.1.4: a transparent always-on-top HUD window (`hud.rs`, `focusable(false)` so it never steals the caret, logo while recording → spinner while transcribing) plus a tray icon with a red/amber dot; both driven from `TrayUi::set_phase`. A startup failure is logged to `%APPDATA%\sezish\sezish.log` and shown in a message box instead of a silent exit. 0.1.4 was written without a Windows machine and is unverified there.

Ecosystem outside this tree (no code here, but agents should know it exists):

- `smixs/sezish-site` (`~/Projects/sezish-site`) — the `sezi.sh` landing page and `/privacy`, on Cloudflare Pages.
- The ASR + translate server behind `asr.sezi.sh` lives in a separate private repository. Desktop clients only need the endpoint and an API key.

## Server landscape (what desktop touches)

- **`asr.sezi.sh`** — cloud ASR. `POST /` with `X-API-Key`, raw audio; WAV passes through, everything else goes via ffmpeg. `GET /health` for prewarm.
- **`dl.sezi.sh`** — distribution, `file_server` over `cx:/opt/sezish-dl`: macOS releases + appcast, `win/latest.json` + setup.exe, `models/` (the multilingual ONNX model, 224 762 204 bytes, plus vocab; and the Russian+English punctuated model `v3_e2e_ctc.int8.onnx`, 224 893 347 bytes, plus its vocab — the Mac's second model), and the CLI (`install.sh` / `install-app.sh`).

## Build, test, release

| Part | Command |
|---|---|
| `app/` | `make build`, `make test`; release: `make release` |
| `win/` | `cargo fmt`, `cargo clippy`, `cargo test` |

Release specifics:

- **macOS** — `make release` runs dist → notarize → appcast → deploy, rsyncing into `cx:/opt/sezish-dl`. Notarization uses the keychain profile `sezish-notary`; the Developer ID certificate is valid until 2027-02-01.
- **Windows** — CI runs fmt + clippy + test on macOS and Windows; a `win-v*` tag builds the release, signs it with minisign, and produces `dl.sezi.sh/win/latest.json`. The CI artifact is uploaded to the server by hand. Requires repo secrets `SEZISH_CLOUD_ENDPOINT`, `SEZISH_CLOUD_KEY`, `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.

## Rules

- Behavior constants and semantics come from the macOS reference code (`app/Sources/`), never from third-party research or OSS lookalikes. When in doubt, read the Swift source (ADR-0003).
- Strict TDD: tests first (red commit), then implementation (green commit). Refactoring is not part of the cycle. Tests attach only to seams (ADR-0002).
- Real time in unit tests is forbidden — `Clock` is always injected.
- Never download ML models in dev or CI. Never commit API keys or signing keys.
- Do not mention the internal ASR model name in code comments, user-facing text, or public artifacts.
- A change set stays inside the crate the ticket names; touching another crate's code (especially `sez-core` traits) is rejected in review.
- **Meeting transcription runs on the local model only.** The cloud is for short dictations — nothing else.
- Versions move by the patch digit only (`0.1.x`). Minor bumps happen on Serge's explicit call.
- macOS `CFBundleVersion` must increase strictly monotonically.
- Commit messages are in Russian, prefixed with the part: `mac:`, `win:`, `docs:`.

## Where knowledge lives

- `docs/adr/` — ADRs; decisions, not tutorials.
- `implementation-notes.md` — gitignored, at the repo root and in `app/`, `win/`. The running log of infra and decisions.
- `TESTING.md` — guide for external testers: installers, building from source, bug reports.
