#!/usr/bin/env bash
# Build a release artifact: universal .app, zipped for GitHub Releases.
#
#   ./release.sh            -> dist/KEF-Control-<version>.zip (+ .sha256)
#
# Upload the zip as a Release asset — do NOT commit it to the repo, or every
# future clone carries every past binary forever.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/KEF Control.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

./build.sh

mkdir -p dist
OUT="dist/KEF-Control-$VERSION.zip"
rm -f "$OUT" "$OUT.sha256"

# ditto, not zip: plain zip mangles bundle symlinks and breaks the signature.
ditto -c -k --keepParent "$APP" "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Verifying the archive round-trips…"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$OUT" "$TMP"
codesign --verify --deep --strict "$TMP/KEF Control.app" \
  && echo "  signature OK after unzip"
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  "$TMP/KEF Control.app/Contents/Info.plist" | sed 's/^/  version /'
lipo -archs "$TMP/KEF Control.app/Contents/MacOS/KEFMenuBar" | sed 's/^/  archs /'

cat <<EOF

Next: create a GitHub Release and attach the zip.
  gh release create v$VERSION "$OUT" --title "v$VERSION" --notes "…"
or use the web UI: Releases -> Draft a new release.

Note the app is ad-hoc signed, not notarized, so anyone downloading it must run
  xattr -dr com.apple.quarantine "/Applications/KEF Control.app"
(the README says so too).
EOF
