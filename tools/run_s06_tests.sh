#!/usr/bin/env bash
# Gate G1 / S06 ProjectStore regression.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "NOT_RUN: S06 requires macOS." >&2
    exit 2
fi

if ! command -v swiftc >/dev/null 2>&1 ||
   ! command -v xcrun >/dev/null 2>&1; then
    echo "NOT_RUN: Xcode Command Line Tools missing." >&2
    exit 2
fi

SDK_CANDIDATES=(
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
)

SDK_PATH=""
TMP_PROBE="/tmp/aivideo_s06_probe_$$.swift"
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

if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
    echo "NOT_RUN: Valid macOS SDK unavailable." >&2
    exit 2
fi

mkdir -p build/tests build/reports

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

echo "PASS: S06 ProjectStore regression"
