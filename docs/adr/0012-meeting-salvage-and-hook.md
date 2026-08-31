# Meeting salvage, engine provenance, post-meeting hook (macOS)

A crash or force-quit mid-meeting used to destroy the recording: stem WAVs
(`.rec-<UUID>/{mic,system}.wav`) carry a zero-size header until `finalize()`,
and the launch-time cleaner deleted every `.rec-*` dir it found. Studying a
minimal local meeting recorder built on the opposite philosophy — everything
written must stay readable, the filesystem is the queue — we adopted three of
its ideas for the macOS app (0.1.8).

Decisions:
- **Salvage instead of delete.** `PCMSpoolFile.repairHeader` rebuilds the WAV
  sizes from the file size (even-truncated; foreign/short files untouched).
  `MeetingSalvage` then re-runs the normal pipeline at launch: chunked mixdown →
  m4a (WAV fallback) → on-device transcription when the local model is on disk →
  the usual `.md`, marked recovered. The orphan dir is removed only after the
  artifacts exist; a failed salvage stays on disk and retries next launch. Only
  proven garbage (zero frames in both stems) is deleted. Discovery is
  synchronous in `AppState.init` so a meeting started later can never be
  mistaken for an orphan.
- **Engine provenance, "cloud"/"local" only.** `DictationRecord.engine`
  (optional — old `index.json` decodes) is stamped by the coordinator from the
  same single read of `effectiveTranscriptionMode` that picked the transcriber,
  so the tag cannot disagree with the engine that ran. Meeting `.md` gets a
  static "recognised on-device" line whenever a transcript exists. Diagnostics
  only: no UI shows it, and no ASR model name appears anywhere.
- **`meetingHook`: a hidden post-meeting hook.** A shell command in UserDefaults
  (`defaults write com.smixs.sezish meetingHook '<cmd>'`, no UI) spawned via
  `/bin/sh -c "<cmd> \"$0\"" <md-path>` after both artifacts are on disk —
  including salvaged meetings. Fire-and-forget: the app never waits on it or
  reports its errors. See `docs/meeting-hook.md`.
- **Ships as 0.1.8** (`CFBundleVersion` 9) on the macOS Sparkle line; the
  Windows line is unaffected per [0015](0015-independent-version-line.md).

Numbering note: independent-version-line originally shipped as a second 0010
(alongside configurable-hotkey) and was renumbered to 0015 on 2026-08-02.
