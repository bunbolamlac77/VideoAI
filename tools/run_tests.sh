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

echo "=== [3/4] Running Python Framing & Model Setup Unit Tests ==="
PYTHON_BIN="python3"
DEDICATED_PY="$HOME/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3"
if [ -x "$DEDICATED_PY" ]; then
    PYTHON_BIN="$DEDICATED_PY"
elif [ -x "workers/.venv/bin/python3" ]; then
    PYTHON_BIN="workers/.venv/bin/python3"
fi

"$PYTHON_BIN" tools/run_python_tests.py

echo "=== [4/5] Building .app and Running S02.T1 & S02.T2 Verification Harness ==="
./tools/build_macos_app.sh >/dev/null
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  tests/test_s02_manual_verification.swift \
  -o build/tests/test_s02_manual_verification

./build/tests/test_s02_manual_verification

echo "=== [5/7] Running Swift Gate G1 S04 Contract Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  tests/test_g1_contracts.swift \
  -o build/tests/test_g1_contracts

./build/tests/test_g1_contracts

echo "=== [6/7] Running Swift Gate G1 S05 Source Import & Snapshot Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceImportModels.swift \
  packages/AIVideoCore/Sources/SourceImport/APFSCapability.swift \
  packages/AIVideoCore/Sources/SourceImport/DiskBudgetPlanner.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceInspector.swift \
  packages/AIVideoCore/Sources/SourceImport/SnapshotVerifier.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceAcquisition.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceManifestStore.swift \
  tests/test_s05_source_import.swift \
  -o build/tests/test_s05_source_import

./build/tests/test_s05_source_import

echo "=== [7/7] Running S05 Hardening Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceImportModels.swift \
  packages/AIVideoCore/Sources/SourceImport/APFSCapability.swift \
  packages/AIVideoCore/Sources/SourceImport/DiskBudgetPlanner.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceInspector.swift \
  packages/AIVideoCore/Sources/SourceImport/SnapshotVerifier.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceAcquisition.swift \
  packages/AIVideoCore/Sources/SourceImport/SourceManifestStore.swift \
  tests/test_s05_hardening.swift \
  -o build/tests/test_s05_hardening

./build/tests/test_s05_hardening

echo "=== [8/8] Running Swift Gate G1 S06 ProjectStore Tests ==="
bash tools/run_s06_tests.sh

echo "=== ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY ==="
