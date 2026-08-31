# Release x64 via CI; functionally verify on the ARM64 dev VM

The physical dev PC died, so live development/verification happens on a Parallels Windows 11 **ARM64** VM. But sezish's users run **x64** Windows, so the shipped installer must be x64. We split the two:

- **Functional proof** (hotkey → record → ASR → insert → history working end-to-end) is demonstrated on the ARM64 VM. The entire product is one Rust codebase; behavior is architecture-independent, so an ARM64 e2e run proves the logic.
- **The released artifact is x64**, built on GitHub Actions `windows-latest` (an x64 runner), signed with minisign, and deployed to dl.sezi.sh/win/.

Consequence: the exact x64 binary we publish is not run on real x64 hardware until Serge (or QA) installs it on an x64 machine — the same class of gap as the deferred x64 AVX2 check (ADR-0007). Low risk for a standard Tauri x64 app; called out as a release-QA line, not a blocker. ARM64 installers may be added later if that audience appears (ADR-0015 keeps versions independent).
