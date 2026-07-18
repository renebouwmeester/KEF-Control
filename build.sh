#!/usr/bin/env bash
# Build KEF Control.app into ~/Applications (speaker-only; no bridges) (universal, macOS 26+)
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/KEF Control.app"
TARGET_OS=26.0

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O -parse-as-library -target arm64-apple-macos$TARGET_OS KEFMenuBar.swift -o "$TMP/KEFMenuBar-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos$TARGET_OS KEFMenuBar.swift -o "$TMP/KEFMenuBar-x86_64"
lipo -create "$TMP/KEFMenuBar-arm64" "$TMP/KEFMenuBar-x86_64" -output "$APP/Contents/MacOS/KEFMenuBar"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp bluetooth-glyph.png "$APP/Contents/Resources/bluetooth-glyph.png"  # no SF Symbol exists for Bluetooth
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"

echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/KEFMenuBar"))"
