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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
INSTALL_APP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_APP=1 ;;
    esac
done

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

# 1. Copy Info.plist and stamp repo root (Finder/Spotlight launches have cwd="/",
#    so the app needs an absolute pointer to workers/.venv and the worker source).
cp "apps/macos/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AIVideoRepoRoot string $ROOT_DIR" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :AIVideoRepoRoot $ROOT_DIR" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 1b. App icon (rendered from source, no binary asset in git)
ICON_TMP="$(mktemp -d)/AppIcon.iconset"
ICON_TOOL="$(dirname "$ICON_TMP")/make_app_icon"
swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 tools/make_app_icon.swift -o "$ICON_TOOL"
"$ICON_TOOL" "$ICON_TMP" >/dev/null
iconutil -c icns "$ICON_TMP" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICON_TMP")"

# 2. Bundle Python Worker runtime into Contents/Resources/Workers/aivideo_workers
echo "Bundling Python Worker into Resources..."
mkdir -p "$RESOURCES_DIR/Workers/aivideo_workers"
cp -R workers/src/aivideo_workers/* "$RESOURCES_DIR/Workers/aivideo_workers/"
# Also provide legacy path for compatibility
mkdir -p "$RESOURCES_DIR/workers"
cp -R workers/src "$RESOURCES_DIR/workers/"

# 3. Bundle Model profile lock into Contents/Resources/contracts
mkdir -p "$RESOURCES_DIR/contracts"
for contract_file in contracts/*.json contracts/*.sql; do
    if [ -f "$contract_file" ]; then
        cp "$contract_file" "$RESOURCES_DIR/contracts/"
    fi
done

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
  packages/AIVideoCore/Sources/Models/G3StoryRequest.swift \
  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \
  packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G4S21Guard.swift \
  packages/AIVideoCore/Sources/Storage/G5ProjectStore.swift \
  packages/AIVideoCore/Sources/Storage/G5S22Guard.swift \
  packages/AIVideoCore/Sources/Scheduler/ResourceGovernor.swift \
  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \
  packages/AIVideoCore/Sources/Publication/G4FilePublisher.swift \
  packages/AIVideoCore/Sources/Recovery/BackupRestoreService.swift \
  packages/AIVideoCore/Sources/Media/MediaIndexer.swift \
  packages/AIVideoCore/Sources/Media/SourceRevisionIdentity.swift \
  packages/AIVideoCore/Sources/Adapters/ModelAdapterContracts.swift \
  packages/AIVideoCore/Sources/Analysis/G2AnalysisAndReviewEngine.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  apps/macos/Sources/AppState.swift \
  apps/macos/Sources/AIVideoApp.swift \
  apps/macos/Sources/G3ConsoleView.swift \
  apps/macos/Sources/G4ConsoleView.swift \
  apps/macos/Sources/G5ConsoleView.swift \
  -o "$TARGET_DIR/AIVideo"

echo "=== [4/4] Ad-hoc Code Signing App Bundle ==="
find "$APP_BUNDLE" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$APP_BUNDLE" -name "*.pyc" -delete 2>/dev/null || true
codesign -s - --force --deep "$APP_BUNDLE"

echo "=== BUILD SUCCESSFUL: $APP_BUNDLE ==="

if [ "$INSTALL_APP" -eq 1 ]; then
    echo "=== [5/5] Installing to Applications & registering with Spotlight ==="
    if [ -w "/Applications" ]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; fi
    mkdir -p "$DEST_DIR"
    DEST="$DEST_DIR/AIVideo.app"
    osascript -e 'tell application id "com.phuthanh.aivideo" to quit' >/dev/null 2>&1 || true

    # Install into a private staging directory on the destination filesystem.
    # In particular, NEVER rm -rf the installed app before a verified copy
    # exists. The previous app remains recoverable on any copy/rename error.
    INSTALL_STAGE="$(mktemp -d "$DEST_DIR/.aivideo-install.XXXXXXXX")"
    STAGED_APP="$INSTALL_STAGE/AIVideo.app"
    BACKUP_APP="$INSTALL_STAGE/AIVideo.previous.app"
    cleanup_installer() {
        if [ -e "$BACKUP_APP" ] && [ ! -e "$DEST" ]; then
            mv "$BACKUP_APP" "$DEST" || echo "CRITICAL: Restore old app manually from $BACKUP_APP" >&2
        fi
        if [ -e "$BACKUP_APP" ]; then
            echo "WARNING: Previous app backup retained at $BACKUP_APP" >&2
        else
            rm -rf "$INSTALL_STAGE"
        fi
    }
    trap cleanup_installer EXIT

    ditto "$APP_BUNDLE" "$STAGED_APP"
    test -x "$STAGED_APP/Contents/MacOS/AIVideo"
    codesign --verify --deep --strict "$STAGED_APP"

    if [ -e "$DEST" ]; then
        mv "$DEST" "$BACKUP_APP"
    fi
    mv "$STAGED_APP" "$DEST"

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -u "$ROOT_DIR/$APP_BUNDLE" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || echo "WARNING: Spotlight registration failed" >&2
    mdimport "$DEST" >/dev/null 2>&1 || true
    touch "$DEST"
    echo "=== INSTALLED: $DEST (Spotlight: gõ \"AIVideo\") ==="

    if [ -e "$BACKUP_APP" ]; then
        rm -rf "$BACKUP_APP" || echo "WARNING: Could not clean up old app at $BACKUP_APP" >&2
    fi
    trap - EXIT
    cleanup_installer
fi
