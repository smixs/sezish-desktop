#!/usr/bin/env python3
"""Synthesize the sezish start chimes (stdlib only) and convert to .caf.

Run once from app/: python3 scripts/make-chimes.py
Artifacts land in Sources/SezishApp/Resources/ and are committed.

- chime-meeting: E5 -> A5 (rising fourth, "positive start"), 2 overlapping notes,
  soft timbre (sine + 25% second harmonic), exponential decay, one-pole lowpass,
  peak -14 dBFS.
- chime-dictation: single A5, shorter and quieter (-16 dBFS) - it fires on every
  push-to-talk, so it whispers.
"""

import math
import struct
import subprocess
import wave
from pathlib import Path

SR = 44_100
OUT_DIR = Path(__file__).resolve().parent.parent / "Sources" / "SezishApp" / "Resources"


def tone(freq: float, dur: float, tau: float) -> list[float]:
    n = int(SR * dur)
    out = []
    for i in range(n):
        t = i / SR
        env = math.exp(-t / tau) * min(1.0, t / 0.008)  # attack ramp kills the click
        s = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * 2 * freq * t)
        out.append(env * s)
    return out


def place(canvas: list[float], note: list[float], offset_s: float) -> None:
    start = int(SR * offset_s)
    for i, s in enumerate(note):
        idx = start + i
        if idx < len(canvas):
            canvas[idx] += s


def lowpass(samples: list[float], fc: float) -> list[float]:
    a = math.exp(-2 * math.pi * fc / SR)
    y, out = 0.0, []
    for s in samples:
        y = (1 - a) * s + a * y
        out.append(y)
    return out


def normalize(samples: list[float], peak_db: float) -> list[float]:
    peak = max(abs(s) for s in samples) or 1.0
    k = (10 ** (peak_db / 20)) / peak
    return [s * k for s in samples]


def write_caf(name: str, samples: list[float]) -> None:
    wav_path = OUT_DIR / f"{name}.wav"
    caf_path = OUT_DIR / f"{name}.caf"
    with wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        w.writeframes(frames)
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", "LEI16", str(wav_path), str(caf_path)],
        check=True,
    )
    wav_path.unlink()
    print(f"{caf_path.name}: {caf_path.stat().st_size} bytes")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    meeting = [0.0] * int(SR * 0.5)
    place(meeting, tone(659.25, 0.32, 0.12), 0.0)   # E5
    place(meeting, tone(880.0, 0.32, 0.12), 0.12)   # A5
    write_caf("chime-meeting", normalize(lowpass(meeting, 3000), -14))

    dictation = [0.0] * int(SR * 0.3)
    place(dictation, tone(880.0, 0.18, 0.07), 0.0)  # A5
    write_caf("chime-dictation", normalize(lowpass(dictation, 3000), -16))


if __name__ == "__main__":
    main()
