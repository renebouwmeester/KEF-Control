#!/usr/bin/env bash
# Build KEF Control.app into /Applications (speaker-only; no bridges) (macOS 26+)
# arm64 by default (every Mac in the house is one); release.sh sets ARCHS="arm64 x86_64" for a universal build.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/KEF Control.app"
TARGET_OS=26.0

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Sources/Core is platform-neutral (no AppKit/Carbon) so an iOS shell can
# share it; Sources/macOS is the menu bar shell. One module, so order is free.
SOURCES=(Sources/Core/*.swift Sources/macOS/*.swift)
DELEN=()
for ARCH in ${ARCHS:-arm64}; do
  swiftc -O -parse-as-library -target $ARCH-apple-macos$TARGET_OS "${SOURCES[@]}" -o "$TMP/KEFMenuBar-$ARCH"
  DELEN+=("$TMP/KEFMenuBar-$ARCH")
done
lipo -create "${DELEN[@]}" -output "$APP/Contents/MacOS/KEFMenuBar"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp bluetooth-glyph.png "$APP/Contents/Resources/bluetooth-glyph.png"  # no SF Symbol exists for Bluetooth
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Developer ID + hardened runtime + secure timestamp, so release.sh can notarize it (since v1.2; before that the
# app was ad-hoc signed and downloads needed an xattr to get past Gatekeeper).
codesign --force --options runtime --timestamp --sign "Developer ID Application" "$APP"

echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/KEFMenuBar"))"
