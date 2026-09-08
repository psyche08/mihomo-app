#!/bin/zsh -f

# Validate an exact Xcode Cloud "Notarized App (ticket attached)" ZIP and
# generate only the signed Sparkle feed metadata needed to publish it. This
# script never builds, re-signs, re-packages, notarizes, or staples the App.

unsetopt XTRACE VERBOSE
set -e
set -u
setopt PIPE_FAIL
umask 077

export PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export LANG='C'
export LC_ALL='C'

readonly SCRIPT_PATH="${0:A}"
readonly ROOT="${SCRIPT_PATH:h:h}"
readonly DIST="$ROOT/dist"
readonly RELEASE_INPUT_ROOT="$ROOT/build/release-inputs"
readonly SPARKLE_DISTRIBUTION_ROOT="$RELEASE_INPUT_ROOT/Sparkle-2.9.4"
readonly SPARKLE_GENERATE_APPCAST="$SPARKLE_DISTRIBUTION_ROOT/bin/generate_appcast"
readonly SPARKLE_SIGN_UPDATE="$SPARKLE_DISTRIBUTION_ROOT/bin/sign_update"
readonly SPARKLE_SIGNATURE_VERIFIER="$RELEASE_INPUT_ROOT/verify-sparkle-ed25519"
readonly SPARKLE_ED_KEY_PATH="${HOME:-}/.config/mihomobox/sparkle-private-ed25519.b64"
readonly EXPECTED_GENERATE_APPCAST_SHA256='d70b1872fb6a859695f8abc0a403301d151d1c6c83cf427f4a2716c37a48983d'
readonly EXPECTED_SIGN_UPDATE_SHA256='bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad'
readonly EXPECTED_SIGNATURE_VERIFIER_SHA256='d35e471db39dfd3ab98dddff3c2b16ba2fed27fc131b85806f7087f319f2d530'
readonly EXPECTED_CLOUD_LEAF_SHA1='44B2EB8C6C3C6A85A3687EEDED7D85EB7C13524A'
readonly EXPECTED_TEAM_ID='89LGY6BD53'
readonly EXPECTED_SPARKLE_VERSION='2.9.4'
readonly REPOSITORY='psyche08/mihomo-app'

fail() {
  /usr/bin/printf 'prepare-cloud-release: %s\n' "$*" >&2
  exit 1
}

usage() {
  /usr/bin/printf 'usage: %s --cloud-zip /absolute/path/MihomoBox.app.zip\n' "${0:t}" >&2
  exit 2
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk 'NR == 1 { print $1 }'
}

require_regular_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a regular, non-symlink file"
}

typeset CLOUD_ZIP=''
while (( $# > 0 )); do
  case "$1" in
    --cloud-zip)
      (( $# >= 2 )) || usage
      [[ -z "$CLOUD_ZIP" ]] || fail '--cloud-zip may be supplied only once'
      CLOUD_ZIP="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$CLOUD_ZIP" && "$CLOUD_ZIP" == /* ]] || usage
[[ "$CLOUD_ZIP" != *$'\n'* && "$CLOUD_ZIP" != *$'\r'* && "$CLOUD_ZIP" != *$'\t'* ]] ||
  fail 'Cloud ZIP path contains an unsupported character'
require_regular_file "$CLOUD_ZIP" 'Cloud ZIP'
CLOUD_ZIP="$(cd -P -- "${CLOUD_ZIP:h}" && /bin/pwd)/${CLOUD_ZIP:t}"
require_regular_file "$CLOUD_ZIP" 'Cloud ZIP'

require_regular_file "$ROOT/VERSION" 'VERSION'
readonly VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] ||
  fail 'VERSION must contain one semantic version'
readonly VERSION_MAJOR="${VERSION%%.*}"
readonly VERSION_REMAINDER="${VERSION#*.}"
readonly VERSION_MINOR="${VERSION_REMAINDER%%.*}"
readonly VERSION_PATCH="${VERSION_REMAINDER#*.}"
(( VERSION_MAJOR > 0 || VERSION_MINOR > 9 || (VERSION_MINOR == 9 && VERSION_PATCH >= 3) )) ||
  fail 'Cloud ZIP release format starts at version 0.9.3'

readonly SOURCE_COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse --verify 'HEAD^{commit}')"
[[ "$SOURCE_COMMIT" =~ '^[0-9a-f]{40}$' ]] || fail 'HEAD is not one full SHA-1 commit'
readonly WORKTREE_STATUS="$(/usr/bin/git -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
[[ -z "$WORKTREE_STATUS" ]] || fail 'release worktree must be clean'

for tool in "$SPARKLE_GENERATE_APPCAST" "$SPARKLE_SIGN_UPDATE" "$SPARKLE_SIGNATURE_VERIFIER"; do
  require_regular_file "$tool" 'pinned Sparkle release tool'
  [[ -x "$tool" ]] || fail 'pinned Sparkle release tool must be executable'
done
[[ "$(sha256_file "$SPARKLE_GENERATE_APPCAST")" == "$EXPECTED_GENERATE_APPCAST_SHA256" ]] ||
  fail 'generate_appcast checksum does not match the audited pin'
[[ "$(sha256_file "$SPARKLE_SIGN_UPDATE")" == "$EXPECTED_SIGN_UPDATE_SHA256" ]] ||
  fail 'sign_update checksum does not match the audited pin'
[[ "$(sha256_file "$SPARKLE_SIGNATURE_VERIFIER")" == "$EXPECTED_SIGNATURE_VERIFIER_SHA256" ]] ||
  fail 'Sparkle signature verifier checksum does not match the audited pin'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SPARKLE_DISTRIBUTION_ROOT/Sparkle.framework/Resources/Info.plist")" == \
  "$EXPECTED_SPARKLE_VERSION" ]] || fail 'Sparkle release tools have the wrong version'

require_regular_file "$SPARKLE_ED_KEY_PATH" 'Sparkle private key'
readonly KEY_MODE="$(/usr/bin/stat -f '%Lp' "$SPARKLE_ED_KEY_PATH")"
readonly KEY_OWNER="$(/usr/bin/stat -f '%u' "$SPARKLE_ED_KEY_PATH")"
[[ "$KEY_MODE" == '400' || "$KEY_MODE" == '600' ]] ||
  fail 'Sparkle private key permissions must be 0400 or 0600'
[[ "$KEY_OWNER" == "$(/usr/bin/id -u)" ]] || fail 'Sparkle private key has the wrong owner'

typeset STAGE=''
cleanup() {
  [[ -z "$STAGE" ]] || /bin/rm -rf -- "$STAGE"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE="$(/usr/bin/mktemp -d /private/tmp/mihomobox-cloud-release.XXXXXX)"
readonly ZIP_LIST="$STAGE/zip-entries.txt"
/usr/bin/unzip -Z1 "$CLOUD_ZIP" > "$ZIP_LIST" || fail 'could not list Cloud ZIP'
[[ -s "$ZIP_LIST" ]] || fail 'Cloud ZIP is empty'
if /usr/bin/awk '
  /^\// || /(^|\/)\.\.(\/|$)/ || /[\r\t]/ { bad = 1 }
  $0 != "MihomoBox.app" && $0 !~ /^MihomoBox\.app\// { bad = 1 }
  END { exit bad ? 0 : 1 }
' "$ZIP_LIST"; then
  fail 'Cloud ZIP contains an unsafe or unexpected entry'
fi

/usr/bin/ditto -x -k "$CLOUD_ZIP" "$STAGE/extracted"
readonly APP="$STAGE/extracted/MihomoBox.app"
[[ -d "$APP" && ! -L "$APP" ]] || fail 'Cloud ZIP does not contain MihomoBox.app at its root'
[[ "$(/usr/bin/find "$STAGE/extracted" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
  fail 'Cloud ZIP contains unexpected top-level entries'

/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
/usr/bin/codesign --verify --strict \
  -R="anchor apple generic and certificate leaf = H\"$EXPECTED_CLOUD_LEAF_SHA1\"" "$APP"
/usr/sbin/spctl --assess --type execute "$APP"
/usr/bin/xcrun stapler validate "$APP"

readonly INFO="$APP/Contents/Info.plist"
readonly MANIFEST="$APP/Contents/Resources/BuildManifest.plist"
require_regular_file "$INFO" 'Cloud App Info.plist'
require_regular_file "$MANIFEST" 'Cloud App BuildManifest.plist'
readonly BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[[ "$BUILD_VERSION" =~ '^[1-9][0-9]*$' ]] || fail 'Cloud App build version is invalid'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$VERSION" ]] ||
  fail 'Cloud App version does not match VERSION'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == 'dev.linsheng.mihomo-app' ]] ||
  fail 'Cloud App bundle identifier is invalid'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")" == 'mihomo-app' ]] ||
  fail 'Cloud App executable is invalid'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$MANIFEST")" == "$VERSION" ]] ||
  fail 'Cloud BuildManifest version mismatch'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BuildVersion' "$MANIFEST")" == "$VERSION" ]] ||
  fail 'Cloud BuildManifest source build version mismatch'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Architecture' "$MANIFEST")" == 'arm64' ]] ||
  fail 'Cloud App architecture is not arm64'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceCommit' "$MANIFEST")" == "$SOURCE_COMMIT" ]] ||
  fail 'Cloud App source commit does not match HEAD'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceDirty' "$MANIFEST")" == 'false' ]] ||
  fail 'Cloud App source was dirty'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SparkleVersion' "$MANIFEST")" == "$EXPECTED_SPARKLE_VERSION" ]] ||
  fail 'Cloud App embeds the wrong Sparkle version'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :DevelopmentUpdatesDisabled' "$MANIFEST")" == 'false' ]] ||
  fail 'Cloud App has production updates disabled'

typeset -a EXECUTABLES=(mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl)
typeset executable_path=''
[[ "$(/usr/bin/find "$APP/Contents/MacOS" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '5' ]] ||
  fail 'Cloud App must contain exactly five product executables'
for executable in "${EXECUTABLES[@]}"; do
  executable_path="$APP/Contents/MacOS/$executable"
  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] ||
    fail "Cloud App executable is missing or unsafe: $executable"
  /usr/bin/codesign --verify --strict \
    -R="anchor apple generic and certificate leaf = H\"$EXPECTED_CLOUD_LEAF_SHA1\"" \
    "$executable_path"
done

typeset key=''
typeset expected=''
for pair in \
  'SUFeedURL|https://github.com/psyche08/mihomo-app/releases/latest/download/appcast.xml' \
  'SUVerifyUpdateBeforeExtraction|true' \
  'SURequireSignedFeed|true' \
  'SUSignedFeedFailureExpirationInterval|0' \
  'SUEnableAutomaticChecks|true' \
  'SUAutomaticallyUpdate|true' \
  'SUScheduledImpatientCheckInterval|43200' \
  'MihomoBoxDevelopmentUpdatesDisabled|false'; do
  key="${pair%%|*}"
  expected="${pair#*|}"
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO")" == "$expected" ]] ||
    fail "Cloud App Sparkle policy mismatch: $key"
done

readonly PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"
[[ "$PUBLIC_KEY" =~ '^[A-Za-z0-9+/]{43}=$' ]] || fail 'Cloud App Sparkle public key is invalid'
readonly CHALLENGE="$STAGE/key-challenge"
/usr/bin/printf 'MihomoBox Cloud release key check %s\n' "$(/usr/bin/uuidgen)" > "$CHALLENGE"
typeset CHALLENGE_SIGNATURE=''
CHALLENGE_SIGNATURE="$("$SPARKLE_SIGN_UPDATE" -p --ed-key-file "$SPARKLE_ED_KEY_PATH" "$CHALLENGE")"
CHALLENGE_SIGNATURE="$(/usr/bin/printf '%s' "$CHALLENGE_SIGNATURE" | /usr/bin/tr -d '\r\n[:space:]')"
[[ "$CHALLENGE_SIGNATURE" =~ '^[A-Za-z0-9+/]{86}==$' ]] || fail 'Sparkle key challenge signature is invalid'
"$SPARKLE_SIGNATURE_VERIFIER" --public-key "$PUBLIC_KEY" \
  --signature "$CHALLENGE_SIGNATURE" --file "$CHALLENGE"
unset CHALLENGE_SIGNATURE

[[ -e "$DIST" ]] || /bin/mkdir "$DIST"
[[ -d "$DIST" && ! -L "$DIST" ]] || fail 'dist must be a non-symlink directory'
readonly ASSET_NAME="MihomoBox-$VERSION-macos-arm64.zip"
readonly ASSET="$DIST/$ASSET_NAME"
readonly SOURCE_SHA256="$(sha256_file "$CLOUD_ZIP")"
if [[ -e "$ASSET" ]]; then
  require_regular_file "$ASSET" 'existing Cloud release asset'
  [[ "$(sha256_file "$ASSET")" == "$SOURCE_SHA256" ]] ||
    fail 'existing Cloud release asset has different bytes'
else
  readonly ASSET_TEMP="$(/usr/bin/mktemp "$DIST/.cloud-asset.XXXXXX")"
  /bin/cp "$CLOUD_ZIP" "$ASSET_TEMP"
  /bin/chmod 0644 "$ASSET_TEMP"
  [[ "$(sha256_file "$ASSET_TEMP")" == "$SOURCE_SHA256" ]] || fail 'Cloud ZIP changed while copying'
  /bin/mv -n "$ASSET_TEMP" "$ASSET"
  [[ ! -e "$ASSET_TEMP" ]] || fail 'Cloud release asset appeared concurrently'
fi

readonly APPCAST_STAGE="$STAGE/appcast"
/bin/mkdir "$APPCAST_STAGE"
/bin/ln "$ASSET" "$APPCAST_STAGE/$ASSET_NAME" 2>/dev/null ||
  /bin/cp "$ASSET" "$APPCAST_STAGE/$ASSET_NAME"
readonly GENERATED_APPCAST="$APPCAST_STAGE/appcast.xml"
"$SPARKLE_GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_ED_KEY_PATH" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  -o "$GENERATED_APPCAST" \
  "$APPCAST_STAGE"
require_regular_file "$GENERATED_APPCAST" 'generated appcast.xml'
/usr/bin/xmllint --noout "$GENERATED_APPCAST"

readonly ASSET_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/$ASSET_NAME"
readonly ENCLOSURE_XPATH="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='enclosure'][@url='$ASSET_URL']"
[[ "$(/usr/bin/xmllint --xpath "count($ENCLOSURE_XPATH)" "$GENERATED_APPCAST")" == '1' ]] ||
  fail 'generated appcast must contain exactly one Cloud ZIP enclosure'
readonly ENCLOSURE_LENGTH="$(/usr/bin/xmllint --xpath "string($ENCLOSURE_XPATH/@length)" "$GENERATED_APPCAST")"
[[ "$ENCLOSURE_LENGTH" == "$(/usr/bin/stat -f '%z' "$ASSET")" ]] ||
  fail 'appcast enclosure length does not match the Cloud ZIP'
readonly APPCAST_SHORT_VERSION="$(/usr/bin/xmllint --xpath \
  "string($ENCLOSURE_XPATH/../*[local-name()='shortVersionString'])" "$GENERATED_APPCAST")"
readonly APPCAST_BUILD_VERSION="$(/usr/bin/xmllint --xpath \
  "string($ENCLOSURE_XPATH/../*[local-name()='version'])" "$GENERATED_APPCAST")"
[[ "$APPCAST_SHORT_VERSION" == "$VERSION" && "$APPCAST_BUILD_VERSION" == "$BUILD_VERSION" ]] ||
  fail 'appcast version does not match the Cloud App'
readonly ENCLOSURE_SIGNATURE="$(/usr/bin/xmllint --xpath \
  "string($ENCLOSURE_XPATH/@*[local-name()='edSignature'])" "$GENERATED_APPCAST")"
[[ "$ENCLOSURE_SIGNATURE" =~ '^[A-Za-z0-9+/]{86}==$' ]] ||
  fail 'appcast enclosure signature is invalid'
"$SPARKLE_SIGNATURE_VERIFIER" --public-key "$PUBLIC_KEY" \
  --signature "$ENCLOSURE_SIGNATURE" --file "$ASSET"

readonly APPCAST="$DIST/appcast.xml"
readonly APPCAST_TEMP="$(/usr/bin/mktemp "$DIST/.appcast.XXXXXX")"
/usr/bin/install -m 0644 "$GENERATED_APPCAST" "$APPCAST_TEMP"
/bin/mv -f "$APPCAST_TEMP" "$APPCAST"

/usr/bin/printf 'cloud_release_version=%s\n' "$VERSION"
/usr/bin/printf 'cloud_release_build=%s\n' "$BUILD_VERSION"
/usr/bin/printf 'cloud_release_commit=%s\n' "$SOURCE_COMMIT"
/usr/bin/printf 'cloud_release_asset=%s\n' "$ASSET"
/usr/bin/printf 'cloud_release_asset_sha256=%s\n' "$SOURCE_SHA256"
/usr/bin/printf 'cloud_release_appcast=%s\n' "$APPCAST"
