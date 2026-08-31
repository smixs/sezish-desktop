**English** · [Русский](./README.ru.md)

<div align="center">

<img src="assets/header.png" alt="sezish" width="100%">

# sezish

**Speech tools for the Uzbek market. Uzbek and Russian first.**

**[sezi.sh](https://sezi.sh)**

</div>

*Sezish* means "perception" in Uzbek: from *sezmoq*, to sense or perceive.

A closed-source commercial product, sold in Uzbekistan. This repository holds the desktop versions. It is private; builds are distributed from `dl.sezi.sh`, never from GitHub releases.

## What it does

- **Dictation**: hold a key, speak, release; the text lands where the cursor is.
- **Meeting recording** (macOS): system audio and mic, two-track diarization, transcription and an AI summary.

## Parts

| Path | What |
|---|---|
| [`app/`](./app) | macOS menu-bar app: dictation, meetings, summaries. The reference implementation |
| [`win/`](./win) | Windows dictation port (Tauri v2 + Rust), early beta |
| [`sezish`](./sezish) | CLI meeting transcriber, one Python file |
| [`docs/`](./docs) | ADRs and research |
| [`assets/`](./assets) | Shared art |

## Build

```bash
cd app && make build    # macOS
cd win && cargo build   # Windows
./sezish meeting.mp4    # CLI, no build needed
```

Testers start here: [TESTING.md](./TESTING.md). Agents start here: [AGENTS.md](./AGENTS.md).
