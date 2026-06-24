#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Lyriam"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "Compiling sources..."
swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -swift-version 5 \
  -strict-concurrency=minimal \
  -O \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  Sources/App/main.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/GlobalHotKey.swift \
  Sources/Settings/*.swift \
  Sources/NowPlaying/*.swift \
  Sources/Lyrics/*.swift \
  Sources/UI/Notch/*.swift \
  Sources/UI/Settings/*.swift

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp -r Resources/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
echo "Run with: open '$APP_BUNDLE'"
