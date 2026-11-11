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
# (P1-44) Keep the previous run's records so a crash mid-matrix cannot leave the review
# package with only the summary record; the current run's files are replaced, not erased.
mkdir -p build/reports/previous
mv build/reports/*.jsonl build/reports/previous/ 2>/dev/null || true

# (P2-01) Compile from globbed sources: a hand-maintained file list silently dropped new
# Swift files from the suite binaries while the app still built.
CORE_DIR="packages/AIVideoCore/Sources"
CORE_ALL=$(find "$CORE_DIR" -name '*.swift' | LC_ALL=C sort)
CORE_IPC="$CORE_DIR/Models/DomainModels.swift $CORE_DIR/WorkerIPC/WorkerClient.swift"

echo "=== [1/2] Compiling and Running Worker IPC Tests (S02) ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_IPC \
  tests/test_worker_ipc.swift \
  -o build/tests/test_worker_ipc

./build/tests/test_worker_ipc

echo "=== [2/3] Compiling and Running DaVinci Resolve Tests (S03) ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_IPC \
  tests/test_resolve_spike.swift \
  -o build/tests/test_resolve_spike

# (P1-40) DaVinci Resolve is an optional component: a BLOCKED spike (Resolve closed) must
# be reported, not treated as a failure of the optional branch.
set +e
./build/tests/test_resolve_spike
RESOLVE_STATUS=$?
set -e
if [ "$RESOLVE_STATUS" -eq 2 ]; then
    echo "NOTE: DaVinci Resolve spike BLOCKED (Resolve Studio not running) — recorded, not counted as PASS"
elif [ "$RESOLVE_STATUS" -ne 0 ]; then
    echo "FAIL: DaVinci Resolve spike exited $RESOLVE_STATUS" >&2
    exit "$RESOLVE_STATUS"
fi

echo "=== [3/4] Running Python Framing & Model Setup Unit Tests ==="
PYTHON_BIN="python3"
if [ -x "workers/.venv/bin/python3" ]; then
    PYTHON_BIN="workers/.venv/bin/python3"
elif [ -x "$HOME/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3" ]; then
    PYTHON_BIN="$HOME/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3"
fi

"$PYTHON_BIN" tools/run_python_tests.py

echo "=== [4/5] Building .app and Running S02.T1 & S02.T2 Verification Harness ==="
./tools/build_macos_app.sh >/dev/null
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s02_manual_verification.swift \
  -o build/tests/test_s02_manual_verification

TEST_RECORDS_OUT="build/reports/swift_s02_manual_records.jsonl" ./build/tests/test_s02_manual_verification

echo "=== [5/6] Running Swift Gate G1 S04 Contract Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g1_contracts.swift \
  -o build/tests/test_g1_contracts

./build/tests/test_g1_contracts

echo "=== [6/11] Running Swift Gate G1 S06 ProjectStore Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s06_project_store.swift \
  -o build/tests/test_s06_project_store

./build/tests/test_s06_project_store

echo "=== [7/11] Running Swift Gate G1 S07 Scheduler & Governor Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s07_scheduler_fencing.swift \
  -o build/tests/test_s07_scheduler_fencing

./build/tests/test_s07_scheduler_fencing

echo "=== [8/11] Running Swift Gate G1 S08 Publication & Reconciler Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s08_publication_reconciler.swift \
  -o build/tests/test_s08_publication_reconciler

./build/tests/test_s08_publication_reconciler

echo "=== [9/11] Running Swift Gate G1 S09 Backup, Restore & Migration Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s09_backup_restore_migration.swift \
  -o build/tests/test_s09_backup_restore_migration

./build/tests/test_s09_backup_restore_migration

echo "=== [10/11] Running Swift Gate G2 S10 Media Indexer & S11 Model Adapter Unit Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s10_s11_g2_foundations.swift \
  -o build/tests/test_s10_s11_g2_foundations

./build/tests/test_s10_s11_g2_foundations

swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_source_revision_identity.swift \
  -o build/tests/test_source_revision_identity

TEST_RECORDS_OUT="build/reports/swift_source_revision_identity_records.jsonl" ./build/tests/test_source_revision_identity

echo "=== [10b/16] Running Swift G2 Coverage DTO Range Expansion Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g2_coverage_dto.swift \
  -o build/tests/test_g2_coverage_dto

TEST_RECORDS_OUT="build/reports/swift_g2_coverage_dto_records.jsonl" ./build/tests/test_g2_coverage_dto

echo "=== [10c/17] Running Swift G3 Story Request Builder Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g3_story_request.swift \
  -o build/tests/test_g3_story_request

TEST_RECORDS_OUT="build/reports/swift_g3_story_request_records.jsonl" ./build/tests/test_g3_story_request

echo "=== [11/15] Running Swift Gate G2 S12..S15 Analysis, Verifier & Review Closure Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s12_to_s15_g2_closure.swift \
  -o build/tests/test_s12_to_s15_g2_closure

TEST_RECORDS_OUT="build/reports/swift_s12_s15_records.jsonl" ./build/tests/test_s12_to_s15_g2_closure

echo "=== [12/15] Running Swift Gate G3 S19 Approval Transaction Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_s19_g3_approval.swift \
  -o build/tests/test_s19_g3_approval

TEST_RECORDS_OUT="build/reports/swift_s19_g3_records.jsonl" ./build/tests/test_s19_g3_approval

echo "=== [13/15] Running Swift Gate G3 Independent Approval Guard Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g3_approval_guard.swift \
  -o build/tests/test_g3_approval_guard

TEST_RECORDS_OUT="build/reports/swift_g3_guard_records.jsonl" ./build/tests/test_g3_approval_guard

echo "=== [14/15] Running Swift Gate G4 S21 Preview Approval & Demux Guard Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g4_approval.swift \
  -o build/tests/test_g4_approval

TEST_RECORDS_OUT="build/reports/swift_g4_s21_records.jsonl" ./build/tests/test_g4_approval

echo "=== [17/17] Running Swift Gate G5 S22..S26 Final 4K, Handoff, IME & Cache Quota Tests ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g5_final_and_release.swift \
  -o build/tests/test_g5_final_and_release

TEST_RECORDS_OUT="build/reports/swift_g5_s22_s26_records.jsonl" ./build/tests/test_g5_final_and_release

echo "=== [P1] Job completion (P1-01), backup/restore (P1-05/06/07), out-of-transaction hashing (P1-02) ==="
# (P2-01) these used to hand-list a subset of the core package, which broke as soon as
# a file moved; the whole package is one module, so compile all of it.
swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  $CORE_ALL tests/test_p1_job_completion.swift -o build/tests/test_p1_job_completion
TEST_RECORDS_OUT="build/reports/swift_p1_job_completion_records.jsonl" ./build/tests/test_p1_job_completion

swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  $CORE_ALL tests/test_p1_backup_restore.swift -o build/tests/test_p1_backup_restore
TEST_RECORDS_OUT="build/reports/swift_p1_backup_restore_records.jsonl" ./build/tests/test_p1_backup_restore

swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  $CORE_ALL tests/test_p1_hashing_outside_transaction.swift -o build/tests/test_p1_hashing_outside_transaction
TEST_RECORDS_OUT="build/reports/swift_p1_hashing_records.jsonl" ./build/tests/test_p1_hashing_outside_transaction

echo "=== [G5 receipt] P0-03: native receipt is bound to the approved plan/G3/G4 chain ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g5_receipt_binding.swift \
  -o build/tests/test_g5_receipt_binding

TEST_RECORDS_OUT="build/reports/swift_g5_receipt_binding_records.jsonl" ./build/tests/test_g5_receipt_binding

echo "=== [G3 LLM] P0-08: provenanced LLM narration reaches S19 approval ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g3_llm_approval.swift \
  -o build/tests/test_g3_llm_approval

TEST_RECORDS_OUT="build/reports/swift_g3_llm_approval_records.jsonl" ./build/tests/test_g3_llm_approval

echo "=== [G3 scope] P0-09: evidence scope comes from claim provenance ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g3_story_scope.swift \
  -o build/tests/test_g3_story_scope

TEST_RECORDS_OUT="build/reports/swift_g3_story_scope_records.jsonl" ./build/tests/test_g3_story_scope

echo "=== [G5 native] Verifying ffmpeg-native provenance receipt in S22 guard ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  $CORE_ALL \
  tests/test_g5_native_provenance.swift \
  -o build/tests/test_g5_native_provenance

TEST_RECORDS_OUT="build/reports/swift_g5_native_records.jsonl" ./build/tests/test_g5_native_provenance

echo "=== [Final Step] Re-signing and Verifying App Bundle Integrity ==="
find "$ROOT_DIR/apps/macos/build/AIVideo.app" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$ROOT_DIR/apps/macos/build/AIVideo.app" -name "*.pyc" -delete 2>/dev/null || true
codesign -s - --force --deep "$ROOT_DIR/apps/macos/build/AIVideo.app"
codesign --verify --deep --strict "$ROOT_DIR/apps/macos/build/AIVideo.app"

echo "=== ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY ==="
