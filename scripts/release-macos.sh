#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID is required}"
: "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is required}"
: "${NOTARY_PASSWORD:?NOTARY_PASSWORD is required}"

IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | \
  /usr/bin/grep 'Developer ID Application' | \
  /usr/bin/grep "($NOTARY_TEAM_ID)" | \
  /usr/bin/sed -n '1s/.*"\(.*\)".*/\1/p')"
if [[ -z "$IDENTITY" ]]; then
  echo "no Developer ID Application identity found for requested team" >&2
  exit 1
fi

cd "$ROOT"
export APPLE_SIGNING_IDENTITY="$IDENTITY"
/usr/bin/env npm run prepare:bundle
/usr/bin/env npm run tauri -- build --bundles app

APP="$ROOT/src-tauri/target/release/bundle/macos/Mihomo App.app"
DIST="$ROOT/dist"
ARCHIVE="$DIST/Mihomo-App-0.1.0-macos.zip"
for executable in "$APP/Contents/MacOS/"*; do
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$executable"
done
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/bin/mkdir -p "$DIST"
/bin/rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
/usr/bin/xcrun notarytool submit "$ARCHIVE" \
  --apple-id "$NOTARY_APPLE_ID" \
  --team-id "$NOTARY_TEAM_ID" \
  --password "$NOTARY_PASSWORD" \
  --wait
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/bin/rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "signed and notarized $APP"
