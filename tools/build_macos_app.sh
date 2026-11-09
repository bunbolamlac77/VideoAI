#!/bin/bash
# ==============================================================================
# tools/build_macos_app.sh — Reproducible Native macOS Build (arm64, Swift 6)
# ==============================================================================
# Compliant with AIVideo v3.1 Specifications:
# - Dynamic SDK discovery and verification against active compiler
# - Swift 6 language mode (-swift-version 6) with strict concurrency enforcement
# - Complete bundling of python worker and models into app Resources
# - Writes toolchain and build manifest for auditability
# ==============================================================================

set -euo pipefail

echo "=== [1/4] Detecting Compatible macOS SDK and Toolchain ==="

SWIFT_VERSION_STRING="$(swiftc --version | head -n 1)"
echo "Active Swift Compiler: $SWIFT_VERSION_STRING"

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

if [ -z "$SDK_PATH" ]; then
    echo "ERROR: Could not find an SDK compatible with current swiftc compiler." >&2
    exit 1
fi

echo "Verified Compatible SDK: $SDK_PATH"

APP_BUNDLE="apps/macos/build/AIVideo.app"
TARGET_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "=== [2/4] Setting up App Bundle Directory Structure ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$TARGET_DIR" "$RESOURCES_DIR"

# 1. Copy Info.plist
if [ -f "apps/macos/Resources/Info.plist" ]; then
    cp "apps/macos/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
fi

# 2. Bundle Python Worker runtime into Contents/Resources/Workers/aivideo_workers
echo "Bundling Python Worker into Resources..."
mkdir -p "$RESOURCES_DIR/Workers/aivideo_workers"
cp -R workers/src/aivideo_workers/* "$RESOURCES_DIR/Workers/aivideo_workers/"
# Also provide legacy path for compatibility
mkdir -p "$RESOURCES_DIR/workers"
cp -R workers/src "$RESOURCES_DIR/workers/"

# 3. Bundle Model profile lock into Contents/Resources/contracts
mkdir -p "$RESOURCES_DIR/contracts"
if [ -f "contracts/g0_model.lock.json" ]; then
    cp "contracts/g0_model.lock.json" "$RESOURCES_DIR/contracts/g0_model.lock.json"
fi
if [ -f "contracts/environment_matrix.json" ]; then
    cp "contracts/environment_matrix.json" "$RESOURCES_DIR/contracts/environment_matrix.json"
fi

# 4. Generate build manifest
BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat <<EOF > "$RESOURCES_DIR/build_manifest.json"
{
  "app_name": "AIVideo",
  "build_time": "$BUILD_TIME",
  "swift_version": "$SWIFT_VERSION_STRING",
  "sdk_path": "$SDK_PATH",
  "target": "arm64-apple-macosx14.0",
  "language_mode": "Swift 6"
}
EOF

echo "=== [3/4] Compiling Native Swift 6 arm64 Executable ==="
swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 6 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/Models/DataContracts.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Scheduler/ResourceGovernor.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  packages/AIVideoCore/Sources/Recovery/BackupRestoreService.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  apps/macos/Sources/AIVideoApp.swift \
  -o "$TARGET_DIR/AIVideo"

echo "=== [4/4] Ad-hoc Code Signing App Bundle ==="
codesign -s - --force "$APP_BUNDLE"

echo "=== BUILD SUCCESSFUL: $APP_BUNDLE ==="
