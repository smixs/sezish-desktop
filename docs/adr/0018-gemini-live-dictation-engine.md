# Gemini Live as the third dictation engine, on the user's own key (macOS, 0.1.13)

Dictation had two engines: our own cloud (short takes, paid by us) and the on-device
model (free, but 215 MB and slower on old Macs). Neither is a cheap way to give one
person fast recognition with punctuation. The gap is filled by a third engine that
runs on the user's own Google AI Studio key, so the cost sits with whoever turns it
on.

The spike on 2026-08-27 compared the two ways of reaching `gemini-3.5-transcribe`
with the same audio. Batching the finished take into the unary REST call returned
text about 1.2 s after the key was released. Streaming the take in realtime over the
Live API returned the final about 0.3 s after release, because by then the server has
already heard everything except the tail. Metered price is about $0.009 per minute of
audio, which one person cannot spend into anything noticeable.

Decisions:

- **Live API over a WebSocket, not the unary call.** The 0.9 s difference is the whole
  reason the engine exists; a batch engine would be slower than our own cloud and
  pointless. Audio goes out in 100 ms chunks at 16 kHz, the cadence the spike ran at.
- **Manual VAD, not server VAD.** The hotkey already is the speech boundary: hold means
  speech, release means end. A take is `activityStart`, then chunks, then `activityEnd`,
  and `generationComplete` is the terminal signal that the answer is whole. Server-side
  endpointing would only add a second opinion about something we already know exactly.
- **One persistent session for the whole app session.** Handshake plus setup costs
  0.57 to 0.89 s, and the server keeps the socket between takes with no context bleeding
  from one take into the next. Paying that once instead of on every key press is most of
  the perceived speed.
- **The idle socket is kept alive by hand.** A socket left alone dies quietly: `send`
  into a stale TCP connection does not fail, it hangs until the idle timeout, and the
  user waits a minute for an error. Three numbers hold it together: a ping every 10 s
  while no take is running, a hard reconnect before `activityStart` if the last frame is
  older than 45 s (`staleAfter`), and a 15 s idle timeout on the transport
  (`timeoutIntervalForRequest`, instead of the system default of 60 s). The ping must be
  strictly more frequent than the idle timeout, otherwise the socket dies from the very
  timer the ping exists to reset.
- **The key lives in `UserDefaults`, not the Keychain.** It is the user's own key for
  their own quota, it is typed in Settings → Recognition and read on every dictation.
  A Keychain item would buy one prompt and a code path per read for a secret whose blast
  radius is the owner's own billing. It is redacted out of every log line and never
  appears in a logged URL.
- **No key means the engine is not selected.** `effectiveTranscriptionMode` falls back to
  the cloud, or to the local model when there are no cloud credentials either. Selecting
  Gemini and leaving the field empty degrades silently instead of failing a dictation.
- **Meetings are not touched.** Meeting transcription stays on the local model, per the
  standing rule. This engine is dictation only.
- **Two modes, visible in History.** SMART (default) cleans the text up, VERBATIM returns
  what was said. The take is tagged `gemini/live-smart` or `gemini/live-verbatim`, so a
  record always says which engine and which mode produced it.

Consequences:

- Dictation with punctuation and casing became roughly four times faster to the final
  text than the batch route, with no model download and no load on `cx`.
- We now depend on a Google endpoint for a shipped feature. It is opt-in and it degrades
  to two engines that were already there, so an outage costs a setting, not the product.
- Support gets a new class of question: the user's own key, the user's own quota, the
  user's own billing. Nothing is verifiable from our side beyond the error the server
  returned.
- SMART cuts profanity out of the transcript. For dictation in Russian that is a real
  behaviour change, and the reason VERBATIM is one toggle away.
- VERBATIM in the spike ate the last word in 2 runs out of 2. The client does not paper
  over that, and it is why SMART is the default.
- Interim transcripts arrive and are thrown away. Nothing on screen shows the text
  growing while the key is held.

Rejected:

- **Unary `gemini-3.5-transcribe`.** Simpler client, no socket, no keepalive, no session
  state. Rejected on the 1.2 s versus 0.3 s measurement alone.
- **Showing interim text in the HUD.** The drafts exist on the wire and would look alive,
  but the HUD is a small overlay that must not pull the eye off the caret, and interims
  rewrite themselves. Postponed, not refused.

Status: Accepted, 2026-08-27. Ships as 0.1.13 (build 14). Windows is
unaffected.
