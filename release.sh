#!/usr/bin/env bash
# Build a release artifact: universal .app, zipped for GitHub Releases.
#
#   ./release.sh            -> dist/KEF-Control-<version>.zip (+ .sha256)
#
# Upload the zip as a Release asset — do NOT commit it to the repo, or every
# future clone carries every past binary forever.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/KEF Control.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

ARCHS="arm64 x86_64" ./build.sh

mkdir -p dist
OUT="dist/KEF-Control-$VERSION.zip"
rm -f "$OUT" "$OUT.sha256"

# Notarize and staple (keychain profile "arco-notary", shared with Arco), then zip the stapled app.
# ditto, not zip: plain zip mangles bundle symlinks and breaks the signature.
NOTA="$(mktemp -d)/notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTA"
xcrun notarytool submit "$NOTA" --keychain-profile arco-notary --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Verifying the archive round-trips…"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$OUT" "$TMP"
codesign --verify --deep --strict "$TMP/KEF Control.app" \
  && echo "  signature OK after unzip"
spctl --assess --type execute "$TMP/KEF Control.app" && echo "  Gatekeeper: accepted (notarized)"
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  "$TMP/KEF Control.app/Contents/Info.plist" | sed 's/^/  version /'
lipo -archs "$TMP/KEF Control.app/Contents/MacOS/KEFMenuBar" | sed 's/^/  archs /'

cat <<EOF

Next: create a GitHub Release and attach the zip.
  gh release create v$VERSION "$OUT" --title "v$VERSION" --notes "…"
or use the web UI: Releases -> Draft a new release.

The app is Developer ID signed and notarized: no quarantine workaround needed.
EOF
