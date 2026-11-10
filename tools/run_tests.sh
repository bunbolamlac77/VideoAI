#!/bin/bash
# ==============================================================================
# tools/run_tests.sh — Build and Execute Regression Test Suites
# Output binary location: build/tests/ (ignored by Git)
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

echo "=== [5/6] Running Swift Gate G1 S04 Contract Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  tests/test_g1_contracts.swift \
  -o build/tests/test_g1_contracts

./build/tests/test_g1_contracts

echo "=== [6/11] Running Swift Gate G1 S06 ProjectStore Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  tests/test_s06_project_store.swift \
  -o build/tests/test_s06_project_store

./build/tests/test_s06_project_store

echo "=== [7/11] Running Swift Gate G1 S07 Scheduler & Governor Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Scheduler/ResourceGovernor.swift \
  tests/test_s07_scheduler_fencing.swift \
  -o build/tests/test_s07_scheduler_fencing

./build/tests/test_s07_scheduler_fencing

echo "=== [8/11] Running Swift Gate G1 S08 Publication & Reconciler Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  tests/test_s08_publication_reconciler.swift \
  -o build/tests/test_s08_publication_reconciler

./build/tests/test_s08_publication_reconciler

echo "=== [9/11] Running Swift Gate G1 S09 Backup, Restore & Migration Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  packages/AIVideoCore/Sources/Recovery/BackupRestoreService.swift \
  tests/test_s09_backup_restore_migration.swift \
  -o build/tests/test_s09_backup_restore_migration

./build/tests/test_s09_backup_restore_migration

echo "=== [10/11] Running Swift Gate G2 S10 Media Indexer & S11 Model Adapter Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Media/MediaIndexer.swift \
  packages/AIVideoCore/Sources/Adapters/ModelAdapterContracts.swift \
  tests/test_s10_s11_g2_foundations.swift \
  -o build/tests/test_s10_s11_g2_foundations

./build/tests/test_s10_s11_g2_foundations

echo "=== [11/15] Running Swift Gate G2 S12..S15 Analysis, Verifier & Review Closure Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  tests/test_s12_to_s15_g2_closure.swift \
  -o build/tests/test_s12_to_s15_g2_closure

TEST_RECORDS_OUT="build/reports/swift_s12_s15_records.jsonl" ./build/tests/test_s12_to_s15_g2_closure

echo "=== [12/15] Running Swift Gate G3 S19 Approval Transaction Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  tests/test_s19_g3_approval.swift \
  -o build/tests/test_s19_g3_approval

TEST_RECORDS_OUT="build/reports/swift_s19_g3_records.jsonl" ./build/tests/test_s19_g3_approval

echo "=== [13/15] Running Swift Gate G3 Independent Approval Guard Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  tests/test_g3_approval_guard.swift \
  -o build/tests/test_g3_approval_guard

TEST_RECORDS_OUT="build/reports/swift_g3_guard_records.jsonl" ./build/tests/test_g3_approval_guard

echo "=== [14/15] Running Swift Gate G4 S21 Preview Approval & Demux Guard Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \
  packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G4S21Guard.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  packages/AIVideoCore/Sources/Publication/G4FilePublisher.swift \
  tests/test_g4_approval.swift \
  -o build/tests/test_g4_approval

TEST_RECORDS_OUT="build/reports/swift_g4_s21_records.jsonl" ./build/tests/test_g4_approval

echo "=== [15/15] Running Swift Gate G5 S22..S26 Final 4K, Handoff, IME & Cache Quota Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \
  packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G4S21Guard.swift \
  packages/AIVideoCore/Sources/Storage/G5ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G5S22Guard.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  packages/AIVideoCore/Sources/Publication/G4FilePublisher.swift \
  tests/test_g5_final_and_release.swift \
  -o build/tests/test_g5_final_and_release

TEST_RECORDS_OUT="build/reports/swift_g5_s22_s26_records.jsonl" ./build/tests/test_g5_final_and_release

echo "=== [Final Step] Re-signing and Verifying App Bundle Integrity ==="
find "$ROOT_DIR/apps/macos/build/AIVideo.app" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$ROOT_DIR/apps/macos/build/AIVideo.app" -name "*.pyc" -delete 2>/dev/null || true
codesign -s - --force --deep "$ROOT_DIR/apps/macos/build/AIVideo.app"
codesign --verify --deep --strict "$ROOT_DIR/apps/macos/build/AIVideo.app"

echo "=== ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY ==="
