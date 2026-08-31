# ONNX Runtime: dynamic linking against the official Microsoft build

The `ort` crate must NOT use its default `download-binaries` feature: pyke's prebuilt is compiled with an AVX2 baseline and crashes before main() on pre-Haswell/older AMD CPUs (a real production crash in Handy, PR #1566). We link dynamically against the official Microsoft onnxruntime build (SSE2 baseline, runtime MLAS dispatch), CPU execution provider only — GPU/DirectML is out of v1 (hybrid-GPU leaks, OOM class of bugs). CI greps Cargo.toml/lock and fails if `download-binaries` reappears.

## Runtime version (verified on the spike)

`ort` 2.0.0-rc.10 requires the onnxruntime **1.22.x** shared library and fail-fasts on a mismatch (it rejected 1.20.1 at startup). sez-asr-local must ship / expect onnxruntime.dll 1.22.x. Proven end-to-end on win-live ARM64 via `win/spikes/ort-smoke` (fixture Add graph). ARM64 exercises linking mechanics only — the AVX2 concern above is x64-specific and stays open until x64 metal QA.
