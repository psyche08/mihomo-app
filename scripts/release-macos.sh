#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/release-common.sh"

RESUME_RELEASE=false
APP_INPUT="$ROOT/build/MihomoBox.app"
PROVENANCE_INPUT=""
while (( $# > 0 )); do
  case "$1" in
    --resume)
      RESUME_RELEASE=true
      shift
      ;;
    --app)
      APP_INPUT="${2:?--app requires a prebuilt .app path}"
      shift 2
      ;;
    --provenance)
      PROVENANCE_INPUT="${2:?--provenance requires an unsigned bundle manifest path}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--resume] [--app PREBUILT_APP] [--provenance MANIFEST]" >&2
      exit 2
      ;;
  esac
done

: "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID is required}"
: "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is required}"
: "${NOTARY_PASSWORD:?NOTARY_PASSWORD is required}"

IDENTITY_CANDIDATES="$(/usr/bin/security find-identity -v -p codesigning |
  /usr/bin/awk -v team="$NOTARY_TEAM_ID" '
    index($0, "Developer ID Application") && index($0, "(" team ")") {
      fingerprint = $2
      gsub(/[^0-9A-Fa-f]/, "", fingerprint)
      if (fingerprint ~ /^[0-9A-Fa-f]{40}$/) print toupper(fingerprint)
    }
  ' | /usr/bin/sort -u)"
IDENTITY_COUNT="$(/usr/bin/printf '%s\n' "$IDENTITY_CANDIDATES" |
  /usr/bin/sed '/^[[:space:]]*$/d' |
  /usr/bin/wc -l |
  /usr/bin/tr -d '[:space:]')"
if [[ -n "${CODESIGN_IDENTITY_FINGERPRINT:-}" ]]; then
  IDENTITY="$(/usr/bin/printf '%s' "$CODESIGN_IDENTITY_FINGERPRINT" |
    /usr/bin/tr '[:lower:]' '[:upper:]')"
  if [[ ! "$IDENTITY" =~ ^[0-9A-F]{40}$ ]] ||
    ! /usr/bin/grep -Fxq "$IDENTITY" <<<"$IDENTITY_CANDIDATES"; then
    echo "CODESIGN_IDENTITY_FINGERPRINT is not a Developer ID Application identity for NOTARY_TEAM_ID" >&2
    exit 1
  fi
elif [[ "$IDENTITY_COUNT" == 1 ]]; then
  IDENTITY="$IDENTITY_CANDIDATES"
elif [[ "$IDENTITY_COUNT" == 0 ]]; then
  echo "no Developer ID Application identity found for requested team" >&2
  exit 1
else
  echo "multiple Developer ID Application identities found for requested team; set CODESIGN_IDENTITY_FINGERPRINT explicitly" >&2
  /usr/bin/printf '%s\n' "$IDENTITY_CANDIDATES" >&2
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
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain one semantic version" >&2
  exit 1
fi
if [[ ! -d "$APP_INPUT" || -L "$APP_INPUT" ]]; then
  echo "prebuilt App must be a non-symlink directory: $APP_INPUT" >&2
  exit 1
fi
APP="$(cd "$(/usr/bin/dirname "$APP_INPUT")" && pwd -P)/$(/usr/bin/basename "$APP_INPUT")"
if [[ -z "$PROVENANCE_INPUT" ]]; then
  PROVENANCE_INPUT="$ROOT/build/MihomoBox-$VERSION-unsigned-bundle.sha256"
fi
if [[ ! -f "$PROVENANCE_INPUT" || -L "$PROVENANCE_INPUT" ]]; then
  echo "unsigned bundle provenance must be a regular, non-symlink file: $PROVENANCE_INPUT" >&2
  exit 1
fi
PROVENANCE="$(cd "$(/usr/bin/dirname "$PROVENANCE_INPUT")" && pwd -P)/$(/usr/bin/basename "$PROVENANCE_INPUT")"
case "$PROVENANCE" in
  "$APP"|"$APP"/*)
    echo "unsigned bundle provenance must be stored outside the App bundle" >&2
    exit 1
    ;;
esac
DIST="$ROOT/dist"
export RELEASE_STATE_DIR="${RELEASE_STATE_DIR:-$DIST/.release-state}"
ARCHIVE="$DIST/MihomoBox-$VERSION-macos.zip"
DMG="$DIST/MihomoBox-$VERSION-macos-arm64.dmg"
UPDATE_ARCHIVE="$DIST/MihomoBox-$VERSION-macos-arm64.app.tar.gz"
LATEST_JSON="$DIST/latest.json"
APPCAST="$DIST/appcast.xml"
LEGACY_PUBLIC_KEY="dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEI2QUExNjI1M0Q1MzdEQTkKUldTcGZWTTlKUmFxdHF2UEhrd2t1bTgxY2hoTUZZcHpUV1hqTmV1b1ZRKzBDOVNtbnBTWUZNMFgK"
DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
RELEASE_LOCK_DIR="$RELEASE_STATE_DIR/release.lock"
RELEASE_LOCK_TOKEN=""
SIGNED_APP_STATE="$RELEASE_STATE_DIR/MihomoBox-$VERSION-signed-app.json"

release_lock_cleanup() {
  local recorded_token=""
  if [[ -n "$RELEASE_LOCK_TOKEN" && -d "$RELEASE_LOCK_DIR" &&
    ! -L "$RELEASE_LOCK_DIR" ]]; then
    recorded_token="$(/bin/cat "$RELEASE_LOCK_DIR/token" 2>/dev/null || true)"
    if [[ "$recorded_token" == "$RELEASE_LOCK_TOKEN" ]]; then
      /bin/rm -rf -- "$RELEASE_LOCK_DIR"
    fi
  fi
}

acquire_release_lock() {
  local owner_pid="unknown"
  local owner_host="unknown"
  local owner_started="unknown"
  /bin/mkdir -p "$RELEASE_STATE_DIR"
  if ! /bin/mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
    if [[ -L "$RELEASE_LOCK_DIR" || ! -d "$RELEASE_LOCK_DIR" ]]; then
      echo "release lock path is unsafe: $RELEASE_LOCK_DIR" >&2
      exit 1
    fi
    owner_pid="$(/bin/cat "$RELEASE_LOCK_DIR/pid" 2>/dev/null || true)"
    owner_host="$(/bin/cat "$RELEASE_LOCK_DIR/host" 2>/dev/null || true)"
    owner_started="$(/bin/cat "$RELEASE_LOCK_DIR/started_at" 2>/dev/null || true)"
    echo "release lock already exists owner_pid=${owner_pid:-unknown} owner_host=${owner_host:-unknown} started_at=${owner_started:-unknown}" >&2
    if [[ "$owner_host" == "$(/bin/hostname)" && "$owner_pid" =~ ^[0-9]+$ ]] &&
      /bin/kill -0 "$owner_pid" 2>/dev/null; then
      echo "the owning release process is still running" >&2
    else
      echo "the lock appears stale; inspect it and remove only $RELEASE_LOCK_DIR before retrying" >&2
    fi
    exit 1
  fi
  RELEASE_LOCK_TOKEN="$(/usr/bin/uuidgen)"
  /usr/bin/printf '%s\n' "$$" > "$RELEASE_LOCK_DIR/pid"
  /bin/hostname > "$RELEASE_LOCK_DIR/host"
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$RELEASE_LOCK_DIR/started_at"
  /usr/bin/printf '%s\n' "$RELEASE_LOCK_TOKEN" > "$RELEASE_LOCK_DIR/token"
  /bin/chmod 0700 "$RELEASE_LOCK_DIR"
  /bin/chmod 0600 "$RELEASE_LOCK_DIR"/*
  trap release_lock_cleanup EXIT
}

fresh_release_has_prior_state() {
  local target
  local found
  if [[ -e "$SIGNED_APP_STATE" ]]; then
    echo "existing signed App state requires --resume: $SIGNED_APP_STATE" >&2
    return 0
  fi
  for target in "$ARCHIVE" "$DMG"; do
    found="$(/usr/bin/find "$RELEASE_STATE_DIR" -maxdepth 1 -type f \
      -name "$(/usr/bin/basename "$target").*.json" -print -quit)"
    if [[ -n "$found" ]]; then
      echo "existing notarization state requires --resume: $found" >&2
      return 0
    fi
  done
  return 1
}

acquire_release_lock
if [[ "$RESUME_RELEASE" != true ]] && fresh_release_has_prior_state; then
  exit 1
fi

: "${LEGACY_MINISIGN:?LEGACY_MINISIGN must name the external minisign executable}"
: "${LEGACY_UPDATER_PRIVATE_KEY_FILE:?LEGACY_UPDATER_PRIVATE_KEY_FILE is required}"
if [[ ! -x "$LEGACY_MINISIGN" || -d "$LEGACY_MINISIGN" ]]; then
  echo "LEGACY_MINISIGN is not an executable file" >&2
  exit 1
fi
if [[ ! -f "$LEGACY_UPDATER_PRIVATE_KEY_FILE" || -L "$LEGACY_UPDATER_PRIVATE_KEY_FILE" ]]; then
  echo "LEGACY_UPDATER_PRIVATE_KEY_FILE must be a regular, non-symlink file" >&2
  exit 1
fi
MINISIGN_HELP="$("$LEGACY_MINISIGN" -h 2>&1 || true)"
for required_option in '-S' '-V' '-m' '-s' '-p' '-x'; do
  if ! /usr/bin/grep -Eq "(^|[[:space:]])${required_option}([[:space:],<]|$)" <<<"$MINISIGN_HELP"; then
    echo "minisign does not advertise required option $required_option" >&2
    exit 1
  fi
done
LEGACY_UPDATER_SMOKE_ARCHIVE="${LEGACY_UPDATER_SMOKE_ARCHIVE:-$DIST/MihomoBox-0.7.0-macos-arm64.app.tar.gz}"
LEGACY_UPDATER_SMOKE_SIGNATURE="${LEGACY_UPDATER_SMOKE_SIGNATURE:-$LEGACY_UPDATER_SMOKE_ARCHIVE.sig}"
if [[ ! -f "$LEGACY_UPDATER_SMOKE_ARCHIVE" || -L "$LEGACY_UPDATER_SMOKE_ARCHIVE" ]] ||
  [[ ! -f "$LEGACY_UPDATER_SMOKE_SIGNATURE" || -L "$LEGACY_UPDATER_SMOKE_SIGNATURE" ]]; then
  echo "real 0.7 updater smoke artifact/signature is required" >&2
  exit 1
fi

: "${SPARKLE_DISTRIBUTION_ROOT:?SPARKLE_DISTRIBUTION_ROOT must name the Sparkle 2.9.4 binary artifact root}"
: "${SPARKLE_ED_KEY_PATH:?SPARKLE_ED_KEY_PATH is required}"
: "${SPARKLE_GENERATE_APPCAST_SHA256:?SPARKLE_GENERATE_APPCAST_SHA256 must pin the audited Sparkle tool}"
: "${SPARKLE_SIGN_UPDATE_SHA256:?SPARKLE_SIGN_UPDATE_SHA256 must pin the audited Sparkle tool}"
: "${SPARKLE_SIGNATURE_VERIFIER:?SPARKLE_SIGNATURE_VERIFIER must name an audited Ed25519 verifier executable}"
: "${SPARKLE_SIGNATURE_VERIFIER_SHA256:?SPARKLE_SIGNATURE_VERIFIER_SHA256 must pin the audited verifier binary}"
if [[ ! -f "$SPARKLE_SIGNATURE_VERIFIER" || -L "$SPARKLE_SIGNATURE_VERIFIER" ||
  ! -x "$SPARKLE_SIGNATURE_VERIFIER" ]]; then
  echo "SPARKLE_SIGNATURE_VERIFIER must be an executable, regular non-symlink file" >&2
  exit 1
fi
if [[ ! "$SPARKLE_SIGNATURE_VERIFIER_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  [[ "$(release_sha256 "$SPARKLE_SIGNATURE_VERIFIER")" != \
    "$SPARKLE_SIGNATURE_VERIFIER_SHA256" ]]; then
  echo "SPARKLE_SIGNATURE_VERIFIER checksum does not match the audited pin" >&2
  exit 1
fi
SPARKLE_SIGNATURE_VERIFIER_HELP="$("$SPARKLE_SIGNATURE_VERIFIER" --help 2>&1 || true)"
for required_option in --public-key --signature --file; do
  if ! /usr/bin/grep -q -- "$required_option" <<<"$SPARKLE_SIGNATURE_VERIFIER_HELP"; then
    echo "SPARKLE_SIGNATURE_VERIFIER does not advertise required option $required_option" >&2
    exit 1
  fi
done
if [[ ! -d "$SPARKLE_DISTRIBUTION_ROOT" ]]; then
  echo "SPARKLE_DISTRIBUTION_ROOT is not a directory" >&2
  exit 1
fi
SPARKLE_DISTRIBUTION_ROOT="$(cd "$SPARKLE_DISTRIBUTION_ROOT" && pwd -P)"
SPARKLE_GENERATE_APPCAST="$SPARKLE_DISTRIBUTION_ROOT/bin/generate_appcast"
SPARKLE_SIGN_UPDATE="$SPARKLE_DISTRIBUTION_ROOT/bin/sign_update"
SPARKLE_TOOLS_FRAMEWORK_INFO="$SPARKLE_DISTRIBUTION_ROOT/Sparkle.framework/Resources/Info.plist"
if [[ ! -x "$SPARKLE_GENERATE_APPCAST" || -d "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "Sparkle distribution generate_appcast is not an executable file" >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_SIGN_UPDATE" || -d "$SPARKLE_SIGN_UPDATE" ]]; then
  echo "Sparkle distribution sign_update is not an executable file" >&2
  exit 1
fi
if [[ ! "$SPARKLE_GENERATE_APPCAST_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  [[ "$(release_sha256 "$SPARKLE_GENERATE_APPCAST")" != \
    "$SPARKLE_GENERATE_APPCAST_SHA256" ]]; then
  echo "generate_appcast checksum does not match the audited Sparkle 2.9.4 pin" >&2
  exit 1
fi
if [[ ! "$SPARKLE_SIGN_UPDATE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  [[ "$(release_sha256 "$SPARKLE_SIGN_UPDATE")" != \
    "$SPARKLE_SIGN_UPDATE_SHA256" ]]; then
  echo "sign_update checksum does not match the audited Sparkle 2.9.4 pin" >&2
  exit 1
fi
if [[ ! -f "$SPARKLE_TOOLS_FRAMEWORK_INFO" ]] ||
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$SPARKLE_TOOLS_FRAMEWORK_INFO")" != "2.9.4" ]]; then
  echo "Sparkle release tools must come from a complete 2.9.4 distribution" >&2
  exit 1
fi
if [[ ! -f "$SPARKLE_ED_KEY_PATH" || -L "$SPARKLE_ED_KEY_PATH" ]]; then
  echo "SPARKLE_ED_KEY_PATH must be a regular, non-symlink file" >&2
  exit 1
fi
SPARKLE_ED_KEY_MODE="$(/usr/bin/stat -f '%Lp' "$SPARKLE_ED_KEY_PATH")"
if [[ "$SPARKLE_ED_KEY_MODE" != "400" && "$SPARKLE_ED_KEY_MODE" != "600" ]]; then
  echo "SPARKLE_ED_KEY_PATH permissions must be 0400 or 0600" >&2
  exit 1
fi
SPARKLE_APPCAST_HELP="$("$SPARKLE_GENERATE_APPCAST" --help 2>&1 || true)"
for required_option in --ed-key-file --download-url-prefix; do
  if ! /usr/bin/grep -q -- "$required_option" <<<"$SPARKLE_APPCAST_HELP"; then
    echo "generate_appcast does not advertise required option $required_option" >&2
    exit 1
  fi
done
if ! /usr/bin/grep -Eq '(^|[[:space:]])-o([[:space:],<]|$)' <<<"$SPARKLE_APPCAST_HELP"; then
  echo "generate_appcast does not advertise required option -o" >&2
  exit 1
fi
SPARKLE_SIGN_UPDATE_HELP="$("$SPARKLE_SIGN_UPDATE" --help 2>&1 || true)"
if ! /usr/bin/grep -q -- '--ed-key-file' <<<"$SPARKLE_SIGN_UPDATE_HELP"; then
  echo "sign_update does not advertise required option --ed-key-file" >&2
  exit 1
fi
if ! /usr/bin/grep -Eq '(^|[[:space:]])-p([[:space:],<]|$)' <<<"$SPARKLE_SIGN_UPDATE_HELP"; then
  echo "sign_update does not advertise required option -p" >&2
  exit 1
fi

DMG_STAGE="$(/usr/bin/mktemp -d /private/tmp/mihomobox-dmg.XXXXXX)"
UPDATE_AUDIT="$(/usr/bin/mktemp -d /private/tmp/mihomobox-update-audit.XXXXXX)"
APPCAST_STAGE="$(/usr/bin/mktemp -d /private/tmp/mihomobox-appcast.XXXXXX)"
LEGACY_PUBLIC_KEY_FILE="$UPDATE_AUDIT/legacy-updater.pub"
LEGACY_SMOKE_MINISIG="$UPDATE_AUDIT/legacy-0.7.minisig"
LEGACY_UPDATE_MINISIG="$UPDATE_AUDIT/current.minisig"
SPARKLE_KEY_CHALLENGE="$UPDATE_AUDIT/sparkle-key-challenge"
cleanup() {
  [[ -z "${DMG_STAGE:-}" ]] || /bin/rm -rf -- "$DMG_STAGE"
  [[ -z "${UPDATE_AUDIT:-}" ]] || /bin/rm -rf -- "$UPDATE_AUDIT"
  [[ -z "${APPCAST_STAGE:-}" ]] || /bin/rm -rf -- "$APPCAST_STAGE"
  release_lock_cleanup
}
trap cleanup EXIT

SPARKLE_ED_KEY_CONTENT="$(/usr/bin/tr -d '\r\n[:space:]' < "$SPARKLE_ED_KEY_PATH")"
if [[ ! "$SPARKLE_ED_KEY_CONTENT" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
  ! SPARKLE_DECODED_KEY_SIZE="$(/usr/bin/printf '%s' "$SPARKLE_ED_KEY_CONTENT" |
    /usr/bin/base64 -D |
    /usr/bin/wc -c |
    /usr/bin/tr -d '[:space:]')"; then
  unset SPARKLE_ED_KEY_CONTENT
  echo "SPARKLE_ED_KEY_PATH is not a valid base64-encoded Sparkle private key" >&2
  exit 1
fi
unset SPARKLE_ED_KEY_CONTENT
if [[ "$SPARKLE_DECODED_KEY_SIZE" != "32" && "$SPARKLE_DECODED_KEY_SIZE" != "96" ]]; then
  echo "SPARKLE_ED_KEY_PATH decoded size is not a supported Sparkle private key" >&2
  exit 1
fi

if ! /usr/bin/printf '%s' "$LEGACY_PUBLIC_KEY" |
  /usr/bin/base64 -D > "$LEGACY_PUBLIC_KEY_FILE"; then
  echo "embedded legacy updater public key is invalid" >&2
  exit 1
fi
if ! /usr/bin/base64 -D < "$LEGACY_UPDATER_SMOKE_SIGNATURE" > "$LEGACY_SMOKE_MINISIG"; then
  echo "0.7 updater smoke signature is not base64-wrapped minisign data" >&2
  exit 1
fi
"$LEGACY_MINISIGN" -V -m "$LEGACY_UPDATER_SMOKE_ARCHIVE" \
  -x "$LEGACY_SMOKE_MINISIG" -p "$LEGACY_PUBLIC_KEY_FILE"
echo "verified real 0.7 updater signature compatibility"

release_app_cdhash() {
  local cdhash
  cdhash="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p' |
    /usr/bin/head -1 |
    /usr/bin/tr '[:lower:]' '[:upper:]')"
  if [[ ! "$cdhash" =~ ^[0-9A-F]{40,64}$ ]]; then
    echo "unable to obtain the signed App CodeDirectory hash" >&2
    return 1
  fi
  /usr/bin/printf '%s\n' "$cdhash"
}

write_signed_app_state() {
  local temporary
  local executable
  local key
  local cdhash
  local code_resources_sha256
  cdhash="$(release_app_cdhash)"
  code_resources_sha256="$(release_sha256 "$APP/Contents/_CodeSignature/CodeResources")"
  temporary="$(/usr/bin/mktemp "$RELEASE_STATE_DIR/.signed-app-state.XXXXXX")"
  # Use XML while incrementally inserting values. On macOS 26, an empty JSON
  # dictionary is ambiguous with OpenStep syntax and plutil refuses the first
  # mutation. The persisted binding remains JSON after the explicit convert.
  /usr/bin/plutil -create xml1 - > "$temporary"
  /usr/bin/plutil -insert schema_version -integer 1 "$temporary"
  /usr/bin/plutil -insert version -string "$VERSION" "$temporary"
  /usr/bin/plutil -insert app -string "$APP" "$temporary"
  /usr/bin/plutil -insert source_commit -string \
    "$(/usr/bin/git -C "$ROOT" rev-parse HEAD)" "$temporary"
  /usr/bin/plutil -insert signing_identity_fingerprint -string "$IDENTITY" "$temporary"
  /usr/bin/plutil -insert cdhash -string "$cdhash" "$temporary"
  /usr/bin/plutil -insert code_resources_sha256 -string \
    "$code_resources_sha256" "$temporary"
  /usr/bin/plutil -insert executables -dictionary "$temporary"
  for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
    case "$executable" in
      mihomo-app) key="mihomo_app" ;;
      mihomo) key="mihomo" ;;
      mihomo-daemon) key="mihomo_daemon" ;;
      mihomo-agent) key="mihomo_agent" ;;
      mihomoboxctl) key="mihomoboxctl" ;;
    esac
    /usr/bin/plutil -insert "executables.$key" -string \
      "$(release_sha256 "$APP/Contents/MacOS/$executable")" "$temporary"
  done
  /usr/bin/plutil -convert json "$temporary"
  /bin/chmod 0600 "$temporary"
  /bin/mv -f "$temporary" "$SIGNED_APP_STATE"
}

verify_signed_app_state() {
  local executable
  local key
  local expected
  local actual
  if [[ ! -f "$SIGNED_APP_STATE" || -L "$SIGNED_APP_STATE" ]]; then
    echo "resume requires the signed App binding state: $SIGNED_APP_STATE" >&2
    return 1
  fi
  if [[ "$(release_read_notary_state "$SIGNED_APP_STATE" schema_version)" != "1" ]] ||
    [[ "$(release_read_notary_state "$SIGNED_APP_STATE" version)" != "$VERSION" ]] ||
    [[ "$(release_read_notary_state "$SIGNED_APP_STATE" app)" != "$APP" ]] ||
    [[ "$(release_read_notary_state "$SIGNED_APP_STATE" source_commit)" != \
      "$(/usr/bin/git -C "$ROOT" rev-parse HEAD)" ]] ||
    [[ "$(release_read_notary_state "$SIGNED_APP_STATE" signing_identity_fingerprint)" != "$IDENTITY" ]]; then
    echo "signed App binding metadata does not match this resume request" >&2
    return 1
  fi
  expected="$(release_read_notary_state "$SIGNED_APP_STATE" cdhash)"
  actual="$(release_app_cdhash)"
  if [[ "$expected" != "$actual" ]]; then
    echo "signed App CodeDirectory hash changed since the original release run" >&2
    return 1
  fi
  expected="$(release_read_notary_state "$SIGNED_APP_STATE" code_resources_sha256)"
  actual="$(release_sha256 "$APP/Contents/_CodeSignature/CodeResources")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
    echo "signed App CodeResources changed since the original release run" >&2
    return 1
  fi
  for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
    case "$executable" in
      mihomo-app) key="mihomo_app" ;;
      mihomo) key="mihomo" ;;
      mihomo-daemon) key="mihomo_daemon" ;;
      mihomo-agent) key="mihomo_agent" ;;
      mihomoboxctl) key="mihomoboxctl" ;;
    esac
    expected="$(release_read_notary_state "$SIGNED_APP_STATE" "executables.$key")"
    actual="$(release_sha256 "$APP/Contents/MacOS/$executable")"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
      echo "signed App executable changed since the original release run: $executable" >&2
      return 1
    fi
  done
}

verify_sparkle_key_pair() {
  local app_public_key="$1"
  local challenge_signature
  /usr/bin/printf 'MihomoBox Sparkle key-pair check %s\n' "$(/usr/bin/uuidgen)" \
    > "$SPARKLE_KEY_CHALLENGE"
  challenge_signature="$("$SPARKLE_SIGN_UPDATE" -p \
    --ed-key-file "$SPARKLE_ED_KEY_PATH" "$SPARKLE_KEY_CHALLENGE")"
  challenge_signature="$(/usr/bin/printf '%s' "$challenge_signature" |
    /usr/bin/tr -d '\r\n[:space:]')"
  if [[ ! "$challenge_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]]; then
    echo "sign_update did not emit one Ed25519 signature for the private key file" >&2
    return 1
  fi
  "$SPARKLE_SIGNATURE_VERIFIER" --public-key "$app_public_key" \
    --signature "$challenge_signature" --file "$SPARKLE_KEY_CHALLENGE"
  /bin/rm -f -- "$SPARKLE_KEY_CHALLENGE"
}

require_prebuilt_app() {
  local bundle_version
  local bundle_build_version
  local build_manifest="$APP/Contents/Resources/BuildManifest.plist"
  local sparkle_public_ed_key
  local executable
  local bundled_entry
  local manifest_key
  local expected_sha256
  local actual_sha256
  local -a bundled_entries=()
  bundle_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  if [[ "$bundle_version" != "$VERSION" ]]; then
    echo "prebuilt App version $bundle_version does not match VERSION $VERSION" >&2
    exit 1
  fi
  bundle_build_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" != \
    "dev.linsheng.mihomo-app" ]]; then
    echo "prebuilt App bundle identifier is invalid" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" != \
    "mihomo-app" ]]; then
    echo "prebuilt App executable contract is invalid" >&2
    exit 1
  fi
  while IFS= read -r -d '' bundled_entry; do
    bundled_entries+=("$bundled_entry")
  done < <(/usr/bin/find "$APP/Contents/MacOS" -mindepth 1 -maxdepth 1 -print0)
  if (( ${#bundled_entries[@]} != 5 )); then
    echo "prebuilt App must contain exactly five MacOS entries" >&2
    exit 1
  fi
  for bundled_entry in "${bundled_entries[@]}"; do
    executable="$(/usr/bin/basename "$bundled_entry")"
    case "$executable" in
      mihomo-app|mihomo|mihomo-daemon|mihomo-agent|mihomoboxctl) ;;
      *) echo "prebuilt App contains an unexpected MacOS entry: $executable" >&2; exit 1 ;;
    esac
    if [[ ! -f "$bundled_entry" || -L "$bundled_entry" || ! -x "$bundled_entry" ]]; then
      echo "prebuilt App entry must be an executable regular file: $executable" >&2
      exit 1
    fi
  done
  if [[ ! -f "$build_manifest" ]]; then
    echo "prebuilt App build manifest is missing" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$build_manifest")" != "$VERSION" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BuildVersion' "$build_manifest")" != \
      "$bundle_build_version" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Architecture' "$build_manifest")" != "arm64" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceCommit' "$build_manifest")" != \
      "$(/usr/bin/git -C "$ROOT" rev-parse HEAD)" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceDirty' "$build_manifest")" != "false" ]]; then
    echo "prebuilt App was not produced from the clean current arm64 source revision" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SparkleVersion' "$build_manifest")" != "2.9.4" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :DevelopmentUpdatesDisabled' "$build_manifest")" != "false" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")" != "2.9.4" ]]; then
    echo "prebuilt App must embed Sparkle 2.9.4" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" != \
    "https://github.com/psyche08/mihomo-app/releases/latest/download/appcast.xml" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$APP/Contents/Info.plist")" != "true" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$APP/Contents/Info.plist")" != "true" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUSignedFeedFailureExpirationInterval' "$APP/Contents/Info.plist")" != "0" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$APP/Contents/Info.plist")" != "true" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$APP/Contents/Info.plist")" != "true" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MihomoBoxDevelopmentUpdatesDisabled' "$APP/Contents/Info.plist")" != "false" ]]; then
    echo "prebuilt App Sparkle security policy is invalid" >&2
    exit 1
  fi
  sparkle_public_ed_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
  if [[ "$sparkle_public_ed_key" == "$DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY" ]] ||
    [[ ! "$sparkle_public_ed_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "prebuilt App Sparkle public key is invalid" >&2
    exit 1
  fi
  verify_sparkle_key_pair "$sparkle_public_ed_key"
  if [[ "$RESUME_RELEASE" != true ]]; then
    for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
      case "$executable" in
        mihomo-app) manifest_key="MihomoAppSHA256" ;;
        mihomo) manifest_key="MihomoSHA256" ;;
        mihomo-daemon) manifest_key="MihomoDaemonSHA256" ;;
        mihomo-agent) manifest_key="MihomoAgentSHA256" ;;
        mihomoboxctl) manifest_key="MihomoBoxCLISHA256" ;;
      esac
      expected_sha256="$(/usr/libexec/PlistBuddy -c "Print :$manifest_key" "$build_manifest")"
      actual_sha256="$(release_sha256 "$APP/Contents/MacOS/$executable")"
      if [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        [[ "$actual_sha256" != "$expected_sha256" ]]; then
        echo "prebuilt App hash does not match build manifest: $executable" >&2
        exit 1
      fi
    done
  fi
}

bundle_symlink_target_is_safe() {
  local link_path="$1"
  local target="$2"
  local bundle_root="$3"
  local combined
  local component
  local resolved
  local depth=0
  local -a components=()

  if [[ -z "$target" || "$target" == /* ]] ||
    [[ "$target" == *$'\n'* || "$target" == *$'\r'* || "$target" == *$'\t'* ]]; then
    return 1
  fi

  combined="$(/usr/bin/dirname "$link_path")/$target"
  IFS='/' read -r -a components <<< "$combined"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) ;;
      ..)
        if (( depth == 0 )); then
          return 1
        fi
        depth=$((depth - 1))
        ;;
      *) depth=$((depth + 1)) ;;
    esac
  done

  if ! resolved="$(/usr/bin/perl -MCwd=abs_path -e '
    use strict;
    use warnings;
    my $resolved = abs_path($ARGV[0]);
    exit 2 unless defined $resolved;
    print $resolved;
  ' "$bundle_root/$link_path")"; then
    return 1
  fi
  case "$resolved" in
    "$bundle_root"|"$bundle_root"/*) ;;
    *) return 1 ;;
  esac
}

create_unsigned_bundle_provenance() {
  local app="$1"
  local output="$2"
  local record_path
  local mode
  local sha256
  local target
  local target_sha256
  local bundle_root

  if ! {
    /usr/bin/printf 'MIHOMOBOX-UNSIGNED-BUNDLE-PROVENANCE-V2\n'
    (
      cd "$app"
      bundle_root="$(pwd -P)"
      /usr/bin/find . -print0 |
        while IFS= read -r -d '' relative; do
          record_path="${relative#./}"
          [[ -n "$record_path" ]] || record_path='.'
          if [[ "$record_path" == *$'\n'* || "$record_path" == *$'\r'* ||
            "$record_path" == *$'\t'* ]]; then
            echo "prebuilt App entry has an unsupported control character in its path" >&2
            exit 1
          fi

          mode="$(/usr/bin/stat -f '%Lp' "$relative")"
          if [[ -L "$relative" ]]; then
            if ! target="$(/usr/bin/perl -e '
              use strict;
              use warnings;
              my $target = readlink($ARGV[0]);
              exit 2 unless defined $target;
              exit 3 if $target =~ /[\t\r\n]/;
              print $target;
            ' "$relative")"; then
              echo "prebuilt App symlink has an unreadable or unsupported target: $record_path" >&2
              exit 1
            fi
            if ! bundle_symlink_target_is_safe \
              "$record_path" "$target" "$bundle_root"; then
              echo "prebuilt App symlink target escapes the bundle or is unsafe: $record_path" >&2
              exit 1
            fi
            target_sha256="$(/usr/bin/printf '%s' "$target" |
              /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
            /usr/bin/printf 'L\t%s\t%s\t%s\t%s\n' \
              "$mode" "$target_sha256" "$record_path" "$target"
          elif [[ -d "$relative" ]]; then
            /usr/bin/printf 'D\t%s\t-\t%s\n' "$mode" "$record_path"
          elif [[ -f "$relative" ]]; then
            sha256="$(release_sha256 "$relative")"
            /usr/bin/printf 'F\t%s\t%s\t%s\n' "$mode" "$sha256" "$record_path"
          else
            echo "prebuilt App contains a socket, device, FIFO, or unsupported entry: $record_path" >&2
            exit 1
          fi
        done |
        LC_ALL=C /usr/bin/sort
    )
  } > "$output"; then
    /bin/rm -f -- "$output"
    return 1
  fi
}

verify_unsigned_bundle_provenance() {
  local observed
  observed="$(/usr/bin/mktemp /private/tmp/mihomobox-unsigned-provenance.XXXXXX)"
  if ! create_unsigned_bundle_provenance "$APP" "$observed"; then
    /bin/rm -f -- "$observed"
    return 1
  fi
  if ! /usr/bin/cmp -s "$PROVENANCE" "$observed"; then
    echo "prebuilt App does not match the external unsigned bundle provenance" >&2
    /bin/rm -f -- "$observed"
    return 1
  fi
  /bin/rm -f -- "$observed"
}

require_prebuilt_app
if [[ "$RESUME_RELEASE" != true ]]; then
  verify_unsigned_bundle_provenance
fi

sign_sparkle_framework() {
  local framework="$APP/Contents/Frameworks/Sparkle.framework"
  local current="$framework/Versions/Current"
  local installer="$current/XPCServices/Installer.xpc"
  local downloader="$current/XPCServices/Downloader.xpc"
  local autoupdate="$current/Autoupdate"
  local updater="$current/Updater.app"
  local component
  for component in "$installer" "$downloader" "$autoupdate" "$updater"; do
    if [[ ! -e "$component" ]]; then
      echo "required Sparkle signing component is missing: $component" >&2
      exit 1
    fi
  done
  codesign_with_retry "$installer" --options runtime
  codesign_with_retry "$downloader" --options runtime --preserve-metadata=entitlements
  codesign_with_retry "$autoupdate" --options runtime
  codesign_with_retry "$updater" --options runtime
  codesign_with_retry "$framework" --options runtime
}

if [[ "$RESUME_RELEASE" == true ]]; then
  verify_signed_app_state
  echo "resuming release with existing signed artifacts version=$VERSION"
else
  echo "signing prebuilt App version=$VERSION"
  sign_sparkle_framework
  for executable in "$APP/Contents/MacOS/"*; do
    codesign_with_retry "$executable" --options runtime
  done
  codesign_with_retry "$APP" --options runtime
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
  write_signed_app_state
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
FIRST_UPDATE_ENTRY="$(/usr/bin/tar -tzf "$UPDATE_ARCHIVE" | /usr/bin/sed -n '1p')"
if [[ "$FIRST_UPDATE_ENTRY" != "MihomoBox.app/" ]] ||
  /usr/bin/tar -tzf "$UPDATE_ARCHIVE" | /usr/bin/grep -Eq '(^|/)\._'; then
  echo "legacy updater archive has an unsafe or AppleDouble-prefixed layout" >&2
  exit 1
fi
/usr/bin/tar -xzf "$UPDATE_ARCHIVE" -C "$UPDATE_AUDIT"
/usr/bin/codesign --verify --deep --strict --verbose=2 \
  "$UPDATE_AUDIT/MihomoBox.app"
"$LEGACY_MINISIGN" -S -m "$UPDATE_ARCHIVE" \
  -s "$LEGACY_UPDATER_PRIVATE_KEY_FILE" -x "$LEGACY_UPDATE_MINISIG"
if [[ ! -f "$LEGACY_UPDATE_MINISIG" ]]; then
  echo "minisign did not create the legacy updater signature" >&2
  exit 1
fi
"$LEGACY_MINISIGN" -V -m "$UPDATE_ARCHIVE" \
  -x "$LEGACY_UPDATE_MINISIG" -p "$LEGACY_PUBLIC_KEY_FILE"
/usr/bin/base64 < "$LEGACY_UPDATE_MINISIG" |
  /usr/bin/tr -d '\r\n' > "$UPDATE_ARCHIVE.sig"
UPDATE_SIGNATURE="$(/usr/bin/tr -d '\r\n' < "$UPDATE_ARCHIVE.sig")"
if [[ -z "$UPDATE_SIGNATURE" ]]; then
  echo "legacy updater signature is empty" >&2
  exit 1
fi
# The legacy 0.7 updater wire format is a base64 wrapper around the complete
# four-line minisign signature. Decode and verify the emitted asset again.
if ! /usr/bin/base64 -D < "$UPDATE_ARCHIVE.sig" > "$UPDATE_AUDIT/emitted.minisig"; then
  echo "legacy updater signature wrapper is invalid" >&2
  exit 1
fi
"$LEGACY_MINISIGN" -V -m "$UPDATE_ARCHIVE" \
  -x "$UPDATE_AUDIT/emitted.minisig" -p "$LEGACY_PUBLIC_KEY_FILE"
PUBLISH_DATE="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
LATEST_JSON_TEMP="$(/usr/bin/mktemp "$DIST/.latest.XXXXXX")"
/usr/bin/plutil -create xml1 - > "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert version -string "$VERSION" "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert notes -string "MihomoBox $VERSION" "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert pub_date -string "$PUBLISH_DATE" "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert platforms -dictionary "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert platforms.darwin-aarch64 -dictionary "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert platforms.darwin-aarch64.signature -string \
  "$UPDATE_SIGNATURE" "$LATEST_JSON_TEMP"
/usr/bin/plutil -insert platforms.darwin-aarch64.url -string \
  "https://github.com/psyche08/mihomo-app/releases/download/v$VERSION/$(/usr/bin/basename "$UPDATE_ARCHIVE")" \
  "$LATEST_JSON_TEMP"
/usr/bin/plutil -convert json "$LATEST_JSON_TEMP"
/bin/chmod 0644 "$LATEST_JSON_TEMP"
/bin/mv -f "$LATEST_JSON_TEMP" "$LATEST_JSON"
/usr/bin/plutil -lint "$LATEST_JSON" >/dev/null
if [[ "$(/usr/bin/plutil -extract platforms.darwin-aarch64.signature raw -n -o - "$LATEST_JSON")" != \
  "$(/usr/bin/tr -d '\r\n' < "$UPDATE_ARCHIVE.sig")" ]]; then
  echo "latest.json signature does not match the published legacy signature asset" >&2
  exit 1
fi

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

/usr/bin/ditto "$DMG" "$APPCAST_STAGE/$(/usr/bin/basename "$DMG")"
GENERATED_APPCAST="$APPCAST_STAGE/appcast.xml"
"$SPARKLE_GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_ED_KEY_PATH" \
  --download-url-prefix "https://github.com/psyche08/mihomo-app/releases/download/v$VERSION/" \
  -o "$GENERATED_APPCAST" \
  "$APPCAST_STAGE"
if [[ ! -f "$GENERATED_APPCAST" ]]; then
  echo "generate_appcast did not create appcast.xml" >&2
  exit 1
fi
/usr/bin/xmllint --noout "$GENERATED_APPCAST"
EXPECTED_DMG_URL="https://github.com/psyche08/mihomo-app/releases/download/v$VERSION/$(/usr/bin/basename "$DMG")"
APPCAST_ENCLOSURE_XPATH="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='enclosure'][@url='$EXPECTED_DMG_URL']"
APPCAST_ENCLOSURE_COUNT="$(/usr/bin/xmllint --xpath \
  "count($APPCAST_ENCLOSURE_XPATH)" "$GENERATED_APPCAST")"
if [[ "$APPCAST_ENCLOSURE_COUNT" != "1" ]]; then
  echo "generated appcast must contain exactly one enclosure for the current DMG URL" >&2
  exit 1
fi
APPCAST_ENCLOSURE_SIGNATURE="$(/usr/bin/xmllint --xpath \
  "string($APPCAST_ENCLOSURE_XPATH/@*[local-name()='edSignature'])" \
  "$GENERATED_APPCAST")"
if [[ ! "$APPCAST_ENCLOSURE_SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]]; then
  echo "generated appcast enclosure signature is invalid" >&2
  exit 1
fi
APPCAST_ENCLOSURE_LENGTH="$(/usr/bin/xmllint --xpath \
  "string($APPCAST_ENCLOSURE_XPATH/@length)" "$GENERATED_APPCAST")"
if [[ "$APPCAST_ENCLOSURE_LENGTH" != "$(/usr/bin/stat -f '%z' "$DMG")" ]]; then
  echo "generated appcast enclosure length does not match the current DMG" >&2
  exit 1
fi
APPCAST_SHORT_VERSION="$(/usr/bin/xmllint --xpath \
  "string($APPCAST_ENCLOSURE_XPATH/../*[local-name()='shortVersionString'])" \
  "$GENERATED_APPCAST")"
APPCAST_BUILD_VERSION="$(/usr/bin/xmllint --xpath \
  "string($APPCAST_ENCLOSURE_XPATH/../*[local-name()='version'])" \
  "$GENERATED_APPCAST")"
if [[ "$APPCAST_SHORT_VERSION" != "$VERSION" ]] ||
  [[ "$APPCAST_BUILD_VERSION" != \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" ]]; then
  echo "generated appcast item version does not match the current App" >&2
  exit 1
fi
APP_SPARKLE_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$APP/Contents/Info.plist")"
"$SPARKLE_SIGNATURE_VERIFIER" --public-key "$APP_SPARKLE_PUBLIC_ED_KEY" \
  --signature "$APPCAST_ENCLOSURE_SIGNATURE" --file "$DMG"
/usr/bin/install -m 0644 "$GENERATED_APPCAST" "$APPCAST"

echo "signed and notarized $APP"
echo "signed, notarized, and stapled $DMG"
echo "generated signed Sparkle appcast $APPCAST"
echo "signed updater archive $UPDATE_ARCHIVE"
echo "generated updater manifest $LATEST_JSON"
