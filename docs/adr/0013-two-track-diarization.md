# Two-track meeting diarization (macOS)

Meeting transcription used to mix the mic and system-audio stems into one mono
stream and transcribe the mix — losing who spoke. The two stems ARE the
diarization: mic = the user, system audio = everyone else. As of 0.1.8 each
track is chunked and recognised separately, segments carry a `Speaker` tag
(`me`/`them`), and `finish()` merges them by timestamp. The transcript reads
"[3:12] Я: …" / "[3:15] Они: …" (uz: Men/Ular); the audio artifact stays ONE
mixed m4a — diarization lives in the text only.

Decisions:
- **One shared transcriber, one worker.** The local engine is an actor that
  serializes inference; a second instance would double ONNX session memory for
  zero wall-clock gain. Both tracks feed one AsyncStream and one worker.
- **Silence gate before inference.** Each track is mostly silent while the
  other side talks; a chunk whose loudest 100 ms frame is below a speech-energy
  threshold never reaches the model — roughly halving what a call costs.
  Timestamps are unaffected (per-track clocks count emitted samples).
- **Per-track clocks, deterministic merge.** Each track's segment starts are
  prefix sums on its own clock (both start at 0, taps open within tens of ms);
  the merge sorts by (start, me < them < untagged).
- **The transcript no longer mirrors the m4a.** Tracks are transcribed pre-mix
  and unclipped — cleaner single-voice audio recognises better than the
  soft-clipped sum. Deliberate break of the old invariant.
- **Mic-only recordings stay unlabeled.** With no second party on record
  (system tap denied), labelling every line "me" is noise: `speaker == nil`,
  rendering falls back to the old untagged format. Salvaged meetings diarize
  exactly like live ones (same pipeline, same renderer).

Known limit (accepted for v1): the mic has no echo cancellation, so without
headphones the far end bleeds from the speakers into the mic track and can be
duplicated under the "me" label. With headphones diarization is clean. If it
bites, the fix is a hidden voice-processing toggle — a separate ticket.
