# Spike: ort dynamically linked to onnxruntime.dll (ticket #6)

Proves the `ort` crate builds WITHOUT `download-binaries` and runs a fixture session
against an operator-supplied onnxruntime shared library on Windows ARM64.

**ARM64 caveat**: this proves linking mechanics only. The ADR-0007 AVX2/pre-Haswell
crash is an x64-specific failure mode (ARM has no AVX) — that regression must still be
checked on real x64 metal at release QA.

Operator setup:
1. Get the official onnxruntime for **win-arm64** (github.com/microsoft/onnxruntime/releases,
   `onnxruntime-win-arm64-*.zip`). Put `onnxruntime.dll` beside the built exe or on PATH,
   or set `ORT_DYLIB_PATH` to its full path.
2. `cargo run --release`.

Fixture `fixtures/add.onnx` is a tiny Add graph (a[2] + b[2] -> c[2]), opset 17, generated
with the `onnx` Python package. The spike loads it, runs [1,2]+[3,4], expects [4,6].

PASS = prints `RESULT: PASS` and the onnxruntime version.
