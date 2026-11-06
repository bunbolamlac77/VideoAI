#!/bin/bash
set -euo pipefail

echo "=== Building AIVideo.app (macOS Native arm64) ==="
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TARGET_DIR="apps/macos/build/AIVideo.app/Contents/MacOS"
RESOURCES_DIR="apps/macos/build/AIVideo.app/Contents/Resources"

mkdir -p "$TARGET_DIR" "$RESOURCES_DIR"

if [ -f "apps/macos/Resources/Info.plist" ]; then
  cp "apps/macos/Resources/Info.plist" "apps/macos/build/AIVideo.app/Contents/Info.plist"
fi

swiftc -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift \
  packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift \
  apps/macos/Sources/AIVideoApp.swift \
  -o "$TARGET_DIR/AIVideo"

codesign -s - --force apps/macos/build/AIVideo.app

echo "=== Build Complete: apps/macos/build/AIVideo.app ==="
