#!/usr/bin/env bash
# G4 S20-S21 regression & macOS build gate. Never marks G4 DONE by itself.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m compileall -q workers/src/aivideo_workers
python3 tools/run_python_tests.py
command -v ffmpeg >/dev/null || { echo 'BLOCKED: ffmpeg missing'; exit 2; }
command -v ffprobe >/dev/null || { echo 'BLOCKED: ffprobe missing'; exit 2; }
command -v swiftc >/dev/null || { echo 'BLOCKED: Swift toolchain missing'; exit 2; }
command -v xcrun >/dev/null || { echo 'BLOCKED: Apple macOS SDK required for native Swift tests'; exit 2; }
SDK_CANDIDATES=(
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
)

SDK=""
TMP_PROBE="/tmp/aivideo_sdk_probe_$$.swift"
echo 'import Foundation; print("probe")' > "$TMP_PROBE"

for candidate in "${SDK_CANDIDATES[@]}"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        if swiftc -sdk "$candidate" -target arm64-apple-macosx14.0 "$TMP_PROBE" -o /dev/null 2>/dev/null; then
            SDK="$candidate"
            break
        fi
    fi
done
rm -f "$TMP_PROBE"

if [ -z "$SDK" ]; then
    echo "ERROR: Could not find an SDK compatible with current swiftc compiler." >&2
    exit 1
fi
mkdir -p build/tests
SWIFT_SOURCES=(
  packages/AIVideoCore/Sources/Models/DataContracts.swift
  packages/AIVideoCore/Sources/Models/DomainModels.swift
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift
  packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift
  packages/AIVideoCore/Sources/Storage/G4S21Guard.swift
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift
  packages/AIVideoCore/Sources/Publication/G4FilePublisher.swift
)
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -swift-version 6 -parse-as-library "${SWIFT_SOURCES[@]}" \
  tests/test_g4_approval.swift -o build/tests/test_g4_approval
./build/tests/test_g4_approval
./tools/build_macos_app.sh
echo 'G4 code regression passed; live Resolve + semantic preview QC still required.'
