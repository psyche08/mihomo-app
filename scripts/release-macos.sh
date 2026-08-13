#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/release-common.sh"

RESUME_RELEASE=false
SKIP_BUILD=false
while (( $# > 0 )); do
  case "$1" in
    --resume)
      RESUME_RELEASE=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    *)
      echo "usage: $0 [--resume | --skip-build]" >&2
      exit 2
      ;;
  esac
done
# --resume already reuses the existing App and, unlike --skip-build, must not
# rebuild the pre-staple archive: its sha256 binds the stored notary submission
# state. Combining them would ask for both behaviours at once.
if [[ "$RESUME_RELEASE" == true && "$SKIP_BUILD" == true ]]; then
  echo "--resume already reuses the existing build; drop --skip-build" >&2
  exit 2
fi

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

codesign_with_retry() {
  local target="$1"
  shift
  local attempt=1
  local delay=5
  local maximum_attempts=5
  while true; do
    if /usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$@" "$target"; then
      return 0
    fi
    if (( attempt >= maximum_attempts )); then
      echo "secure timestamp signing failed after $attempt attempts: $target" >&2
      return 1
    fi
    echo "secure timestamp signing retry attempt=$attempt delay_seconds=$delay" >&2
    /bin/sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

notarize_with_retry() {
  local target="$1"
  local attempt=1
  local delay=5
  local maximum_attempts=5
  local submission_id=""
  local upload_confirmed=false
  local artifact_sha256
  local state_file
  local submit_log
  local persisted_status=""
  local output
  local status
  artifact_sha256="$(release_sha256 "$target")"
  state_file="$(release_notary_state_file "$target" "$artifact_sha256")"
  submit_log="$state_file.submit.log"
  if [[ -f "$state_file" ]]; then
    submission_id="$(release_read_notary_state "$state_file" submission_id)"
    upload_confirmed="$(release_read_notary_state "$state_file" upload_confirmed)"
    persisted_status="$(release_read_notary_state "$state_file" status)"
    case "$persisted_status" in
      accepted)
        echo "notarization state already accepted artifact_sha256=$artifact_sha256"
        return 0
        ;;
      rejected)
        echo "notarization state is rejected artifact_sha256=$artifact_sha256" >&2
        return 1
        ;;
      *) ;;
    esac
  fi

  # A shell or notarytool crash can happen after the ID reaches the persistent
  # log but before the JSON state is updated. Recover that exact ID; never turn
  # an ambiguous prior attempt into a second submission.
  if [[ -z "$submission_id" && -f "$submit_log" ]]; then
    submission_id="$(release_submission_id_from_log "$submit_log" || true)"
    if [[ -n "$submission_id" ]]; then
      if /usr/bin/grep -q 'Successfully uploaded file' "$submit_log"; then
        upload_confirmed=true
      fi
      release_write_notary_state \
        "$state_file" "$target" "$artifact_sha256" "$submission_id" \
        "$upload_confirmed" submitted
      echo "recovered notarization submission id=$submission_id from persistent log"
    fi
  fi

  if [[ -n "$submission_id" ]]; then
    if ! release_valid_submission_id "$submission_id"; then
      echo "invalid persisted notarization submission ID: $state_file" >&2
      return 1
    fi
    echo "resuming notarization submission id=$submission_id"
  elif [[ -f "$state_file" ]]; then
    echo "notarization attempt has no recoverable submission ID; refusing automatic resubmission: $state_file" >&2
    return 1
  else
    release_write_notary_state \
      "$state_file" "$target" "$artifact_sha256" "" false submitting
    /usr/bin/printf '' >"$submit_log"
    /bin/chmod 0600 "$submit_log"
    echo "submitting notarization artifact exactly once"
    set +e
    /usr/bin/xcrun notarytool submit "$target" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --no-s3-acceleration \
      --no-progress 2>&1 | /usr/bin/tee "$submit_log"
    status="${PIPESTATUS[0]}"
    set -e
    /bin/chmod 0600 "$submit_log"
    submission_id="$(release_submission_id_from_log "$submit_log" || true)"
    if [[ -z "$submission_id" ]]; then
      release_write_notary_state \
        "$state_file" "$target" "$artifact_sha256" "" false submit_unknown
      echo "submit ended without one recoverable submission ID; inspect Apple history manually and do not resubmit automatically" >&2
      return "$(( status == 0 ? 1 : status ))"
    fi
    if /usr/bin/grep -q 'Successfully uploaded file' "$submit_log"; then
      upload_confirmed=true
    fi
    release_write_notary_state \
      "$state_file" "$target" "$artifact_sha256" "$submission_id" \
      "$upload_confirmed" submitted
    if (( status != 0 )); then
      echo "notarytool submit exited status=$status after exposing an ID; continuing by ID only" >&2
    fi
  fi

  while true; do
    output="$(/usr/bin/mktemp /private/tmp/mihomobox-notary-wait.XXXXXX)"
    set +e
    /usr/bin/xcrun notarytool wait "$submission_id" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --timeout 30m 2>&1 | /usr/bin/tee "$output"
    status="${PIPESTATUS[0]}"
    set -e
    if (( status == 0 )); then
      release_write_notary_state \
        "$state_file" "$target" "$artifact_sha256" "$submission_id" \
        "$upload_confirmed" accepted
      /bin/rm -f -- "$output"
      return 0
    fi
    if /usr/bin/grep -Eq 'status: (Invalid|Rejected)' "$output"; then
      release_write_notary_state \
        "$state_file" "$target" "$artifact_sha256" "$submission_id" \
        "$upload_confirmed" rejected
      /bin/rm -f -- "$output"
      return "$status"
    fi
    release_write_notary_state \
      "$state_file" "$target" "$artifact_sha256" "$submission_id" \
      "$upload_confirmed" submitted
    /bin/rm -f -- "$output"
    if (( attempt >= maximum_attempts )); then
      echo "notarization wait failed after $attempt attempts; resume this exact submission later: $target" >&2
      return "$status"
    fi
    echo "notarization wait retry attempt=$attempt delay_seconds=$delay submission_id=$submission_id" >&2
    /bin/sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}


cd "$ROOT"
VERSION="$(/usr/bin/env node -p "require('./src-tauri/tauri.conf.json').version")"
APP="$ROOT/src-tauri/target/release/bundle/macos/MihomoBox.app"
DIST="$ROOT/dist"
export RELEASE_STATE_DIR="${RELEASE_STATE_DIR:-$DIST/.release-state}"
ARCHIVE="$DIST/MihomoBox-$VERSION-macos.zip"
DMG="$DIST/MihomoBox-$VERSION-macos-arm64.dmg"
UPDATE_ARCHIVE="$DIST/MihomoBox-$VERSION-macos-arm64.app.tar.gz"
LATEST_JSON="$DIST/latest.json"
if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  UPDATER_KEY_PATH="${TAURI_UPDATER_KEY_PATH:-$HOME/.tauri/mihomobox.key}"
  if [[ ! -f "$UPDATER_KEY_PATH" ]]; then
    echo "updater private key not found: $UPDATER_KEY_PATH" >&2
    exit 1
  fi
  TAURI_SIGNING_PRIVATE_KEY="$(/bin/cat "$UPDATER_KEY_PATH")"
  export TAURI_SIGNING_PRIVATE_KEY
fi
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
DMG_STAGE="$(/usr/bin/mktemp -d /private/tmp/mihomobox-dmg.XXXXXX)"
UPDATE_AUDIT="$(/usr/bin/mktemp -d /private/tmp/mihomobox-update-audit.XXXXXX)"
cleanup() {
  [[ -z "${DMG_STAGE:-}" ]] || /bin/rm -rf -- "$DMG_STAGE"
  [[ -z "${UPDATE_AUDIT:-}" ]] || /bin/rm -rf -- "$UPDATE_AUDIT"
}
trap cleanup EXIT

require_prebuilt_app() {
  local mode="$1"
  if [[ ! -d "$APP" ]]; then
    echo "$mode requested but the built App is missing: $APP" >&2
    exit 1
  fi
  local bundle_version
  bundle_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  if [[ "$bundle_version" != "$VERSION" ]]; then
    echo "$mode App version $bundle_version does not match source version $VERSION" >&2
    exit 1
  fi
}

if [[ "$RESUME_RELEASE" == true ]]; then
  require_prebuilt_app resume
  echo "resuming release with existing signed artifacts version=$VERSION"
else
  if [[ "$SKIP_BUILD" == true ]]; then
    # The compile is what is expensive; signing is seconds and is repeated here
    # on purpose. `validate.sh` also leaves a bundle at this path, built from the
    # default config and signed differently, so re-signing with the Developer ID
    # identity and the hardened runtime is what keeps --skip-build from
    # notarizing something that was never built for release.
    require_prebuilt_app --skip-build
    echo "skipping build, signing and notarizing existing bundle version=$VERSION"
  else
    /usr/bin/env npm run prepare:bundle
    /usr/bin/env -u APPLE_SIGNING_IDENTITY npm run tauri -- build --bundles app \
      --config src-tauri/tauri.release.conf.json
  fi
  for executable in "$APP/Contents/MacOS/"*; do
    codesign_with_retry "$executable" --options runtime
  done
  codesign_with_retry "$APP" --options runtime
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/bin/mkdir -p "$DIST"
if /usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "App already has a valid notarization ticket"
else
  if [[ "$RESUME_RELEASE" != true ]]; then
    /bin/rm -f "$ARCHIVE"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
  elif [[ ! -f "$ARCHIVE" ]]; then
    echo "resume requested but pre-staple App archive is missing: $ARCHIVE" >&2
    exit 1
  fi
  notarize_with_retry "$ARCHIVE"
  /usr/bin/xcrun stapler staple "$APP"
fi
/usr/bin/xcrun stapler validate "$APP"
/bin/rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

/bin/rm -f "$UPDATE_ARCHIVE" "$UPDATE_ARCHIVE.sig" "$LATEST_JSON"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$UPDATE_ARCHIVE" -C "$(/usr/bin/dirname "$APP")" \
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

REUSE_EXISTING_DMG=false
if [[ "$RESUME_RELEASE" == true && -f "$DMG" ]]; then
  existing_dmg_sha256="$(release_sha256 "$DMG")"
  existing_dmg_state="$(
    release_notary_state_file "$DMG" "$existing_dmg_sha256"
  )"
  if /usr/bin/xcrun stapler validate "$DMG" >/dev/null 2>&1 \
    || [[ -f "$existing_dmg_state" ]]; then
    REUSE_EXISTING_DMG=true
  fi
fi
if [[ "$REUSE_EXISTING_DMG" != true ]]; then
  /usr/bin/ditto "$APP" "$DMG_STAGE/MihomoBox.app"
  /bin/ln -s /Applications "$DMG_STAGE/Applications"
  /bin/rm -f "$DMG"
  /usr/bin/hdiutil create \
    -volname "MihomoBox" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG"
  codesign_with_retry "$DMG"
else
  echo "resuming release with state-bound existing signed DMG"
fi
/usr/bin/codesign --verify --verbose=2 "$DMG"
if /usr/bin/xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "DMG already has a valid notarization ticket"
else
  notarize_with_retry "$DMG"
  /usr/bin/xcrun stapler staple "$DMG"
fi
/usr/bin/xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
/usr/bin/hdiutil verify "$DMG"

echo "signed and notarized $APP"
echo "signed, notarized, and stapled $DMG"
echo "signed updater archive $UPDATE_ARCHIVE"
echo "generated updater manifest $LATEST_JSON"
