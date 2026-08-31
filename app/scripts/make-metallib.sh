#!/bin/bash
# Compiles the overlay rim shader into the module bundle's default metal
# library. Run once after editing Shaders/MetalRim.metal; the artifact is
# committed (same pattern as the chime .caf files) — plain `swift build`
# cannot compile .metal sources.
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun -sdk macosx metal -mmacosx-version-min=14.2 \
    Shaders/MetalRim.metal -o Sources/SezishApp/Resources/default.metallib
echo "Built Sources/SezishApp/Resources/default.metallib ($(stat -f%z Sources/SezishApp/Resources/default.metallib) bytes)"
