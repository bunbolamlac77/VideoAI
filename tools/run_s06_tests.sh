#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build/tests build/reports

# Auto-detect compatible macOS SDK if on Darwin
SDK_FLAGS=()
if [ "$(uname -s)" = "Darwin" ]; then
    SDK_CANDIDATES=(
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
        "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    )
    TMP_PROBE="/tmp/aivideo_sdk_probe_$$.swift"
    echo 'import Foundation; print("probe")' > "$TMP_PROBE"
    for candidate in "${SDK_CANDIDATES[@]}"; do
        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
            if swiftc -sdk "$candidate" -target arm64-apple-macosx14.0 "$TMP_PROBE" -o /dev/null 2>/dev/null; then
                SDK_FLAGS=(-sdk "$candidate" -target arm64-apple-macosx14.0)
                break
            fi
        fi
    done
    rm -f "$TMP_PROBE"
fi

S06_SOURCES=(
  packages/AIVideoCore/Sources/ProjectStore/ProjectStoreModels.swift
  packages/AIVideoCore/Sources/ProjectStore/SQLiteStoreDatabase.swift
  packages/AIVideoCore/Sources/ProjectStore/ProjectStore.swift
  packages/AIVideoCore/Sources/ProjectStore/ProjectStoreRegistry.swift
)

echo "=== Building S06 ProjectStore tests ==="

swiftc \
  ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} \
  -swift-version 6 \
  -parse-as-library \
  "${S06_SOURCES[@]}" \
  tests/test_s06_project_store.swift \
  -lsqlite3 \
  -o build/tests/test_s06_project_store

echo "=== Running S06 ProjectStore tests ==="

./build/tests/test_s06_project_store \
  contracts/migrations \
  2>&1 | tee build/reports/s06-projectstore.log

echo "=== S06 BASELINE PASS ==="
