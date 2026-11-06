#!/bin/bash
# ==============================================================================
# tools/run_tests.sh — Build and Execute Regression Test Suites
# Output binary location: build/tests/ (ignored by Git)
# ==============================================================================

set -euo pipefail

SDK_CANDIDATES=(
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
)

SDK_PATH=""
TMP_PROBE="/tmp/aivideo_sdk_probe_$$.swift"
echo 'import Foundation; print("probe")' > "$TMP_PROBE"

for candidate in "${SDK_CANDIDATES[@]}"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        if swiftc -sdk "$candidate" -target arm64-apple-macosx14.0 "$TMP_PROBE" -o /dev/null 2>/dev/null; then
            SDK_PATH="$candidate"
            break
        fi
    fi
done
rm -f "$TMP_PROBE"

mkdir -p build/tests build/reports
rm -f build/reports/*.jsonl

echo "=== [1/2] Compiling and Running Worker IPC Tests (S02) ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  tests/test_worker_ipc.swift \
  -o build/tests/test_worker_ipc

./build/tests/test_worker_ipc

echo "=== [2/3] Compiling and Running DaVinci Resolve Tests (S03) ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  tests/test_resolve_spike.swift \
  -o build/tests/test_resolve_spike

./build/tests/test_resolve_spike

echo "=== [3/3] Running Python Framing & Model Setup Unit Tests ==="
PYTHON_BIN="python3"
DEDICATED_PY="$HOME/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3"
if [ -x "$DEDICATED_PY" ]; then
    PYTHON_BIN="$DEDICATED_PY"
elif [ -x "workers/.venv/bin/python3" ]; then
    PYTHON_BIN="workers/.venv/bin/python3"
fi

"$PYTHON_BIN" tools/run_python_tests.py

echo "=== ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY ==="
