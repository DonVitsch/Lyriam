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
  -module-cache-path "${TMPDIR:-/private/tmp}/lyriam-module-cache" \
  -strict-concurrency=minimal \
  -O -whole-module-optimization \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  Sources/App/main.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/GlobalHotKey.swift \
  Sources/Settings/*.swift \
  Sources/Activities/*.swift \
  Sources/Visibility/*.swift \
  Sources/System/*.swift \
  Sources/Tools/*.swift \
  Sources/Network/*.swift \
  Sources/Devices/*.swift \
  Sources/Clipboard/*.swift \
  Sources/Shelf/*.swift \
  Sources/NowPlaying/*.swift \
  Sources/Lyrics/*.swift \
  Sources/UI/Notch/*.swift \
  Sources/UI/Settings/*.swift \
  -framework CoreAudio -framework IOBluetooth -framework CoreBluetooth -framework IOKit -framework ApplicationServices -framework AVFoundation -framework Network -framework SystemConfiguration

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp -r Resources/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

# Feature release; the calibrated island geometry remains unchanged.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.6.0" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

echo "Built: $APP_BUNDLE"
echo "DMG staging prepared: $DMG_STAGING_DIR"
echo "Run with: open '$APP_BUNDLE'"
