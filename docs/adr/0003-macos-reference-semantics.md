# The Windows port copies the macOS app; the macOS app may borrow from anywhere

The Swift sources in `app/Sources/` are the single source of truth for the **Windows port's** behavior: toggle cooldown 0.5 s (hold exempt), minimum dictation 4800 samples (0.3 s @16 kHz), history-before-insert, empty-text records kept, mode set by settings. An agent working on `win/` reads the Swift source, not OSS research: the research doc (`docs/windows-port-research.md`) is normative only for WinAPI mechanics (hook type, SendInput batching, linking), and its OSS constants (250 ms debounce, 350 ms hold heuristics) must not be blended into the port.

The **macOS app** itself is free to adopt behavior, constants, and code from any source, open-source apps included (Serge, 2026-11-05: «удалить этот ADR — всё можно»). Once a borrowed value lands in `app/Sources/`, it becomes the reference the Windows port follows. Borrowed code keeps its license: MIT sources (e.g. anomalyco/hex) are credited with copyright and license text in `app/THIRD_PARTY_NOTICES.md`.

Supersedes the 2026-09 wording that forbade OSS constants on macOS as well.
