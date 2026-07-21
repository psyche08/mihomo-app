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
VERSION="$(/usr/bin/env node -p "require('./src-tauri/tauri.conf.json').version")"
if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  UPDATER_KEY_PATH="${TAURI_UPDATER_KEY_PATH:-$HOME/.tauri/mihomobox.key}"
  if [[ ! -f "$UPDATER_KEY_PATH" ]]; then
    echo "updater private key not found: $UPDATER_KEY_PATH" >&2
    exit 1
  fi
  export TAURI_SIGNING_PRIVATE_KEY="$UPDATER_KEY_PATH"
fi
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
export APPLE_SIGNING_IDENTITY="$IDENTITY"
/usr/bin/env npm run prepare:bundle
/usr/bin/env npm run tauri -- build --bundles app \
  --config src-tauri/tauri.release.conf.json

APP="$ROOT/src-tauri/target/release/bundle/macos/MihomoBox.app"
DIST="$ROOT/dist"
ARCHIVE="$DIST/MihomoBox-$VERSION-macos.zip"
DMG="$DIST/MihomoBox-$VERSION-macos-arm64.dmg"
UPDATE_ARCHIVE="$DIST/MihomoBox-$VERSION-macos-arm64.app.tar.gz"
LATEST_JSON="$DIST/latest.json"
DMG_STAGE="$(/usr/bin/mktemp -d /private/tmp/mihomobox-dmg.XXXXXX)"
UPDATE_AUDIT="$(/usr/bin/mktemp -d /private/tmp/mihomobox-update-audit.XXXXXX)"
cleanup() {
  [[ -z "${DMG_STAGE:-}" ]] || /bin/rm -rf -- "$DMG_STAGE"
  [[ -z "${UPDATE_AUDIT:-}" ]] || /bin/rm -rf -- "$UPDATE_AUDIT"
}
trap cleanup EXIT

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

/bin/rm -f "$UPDATE_ARCHIVE" "$UPDATE_ARCHIVE.sig" "$LATEST_JSON"
/usr/bin/tar -czf "$UPDATE_ARCHIVE" -C "$(/usr/bin/dirname "$APP")" \
  "$(/usr/bin/basename "$APP")"
/usr/bin/tar -xzf "$UPDATE_ARCHIVE" -C "$UPDATE_AUDIT"
/usr/bin/codesign --verify --deep --strict --verbose=2 \
  "$UPDATE_AUDIT/MihomoBox.app"
/usr/bin/env npm run tauri -- signer sign "$UPDATE_ARCHIVE"
UPDATE_SIGNATURE="$(/usr/bin/tr -d '\r\n' < "$UPDATE_ARCHIVE.sig")"
PUBLISH_DATE="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/bin/cat > "$LATEST_JSON" <<EOF
{
  "version": "$VERSION",
  "notes": "MihomoBox $VERSION",
  "pub_date": "$PUBLISH_DATE",
  "platforms": {
    "darwin-aarch64": {
      "signature": "$UPDATE_SIGNATURE",
      "url": "https://github.com/psyche08/mihomo-app/releases/download/v$VERSION/$(/usr/bin/basename "$UPDATE_ARCHIVE")"
    }
  }
}
EOF
/usr/bin/env node -e \
  'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
  "$LATEST_JSON"

/usr/bin/ditto "$APP" "$DMG_STAGE/MihomoBox.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create \
  -volname "MihomoBox" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG"
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
/usr/bin/codesign --verify --verbose=2 "$DMG"
/usr/bin/xcrun notarytool submit "$DMG" \
  --apple-id "$NOTARY_APPLE_ID" \
  --team-id "$NOTARY_TEAM_ID" \
  --password "$NOTARY_PASSWORD" \
  --wait
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
/usr/bin/hdiutil verify "$DMG"

echo "signed and notarized $APP"
echo "signed, notarized, and stapled $DMG"
echo "signed updater archive $UPDATE_ARCHIVE"
echo "generated updater manifest $LATEST_JSON"
