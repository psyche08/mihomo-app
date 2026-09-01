#!/bin/zsh -f

# Fail closed against inherited shell/runtime injection before enabling error
# tracing or reading authentication state. Capture an optional GH_TOKEN as a
# non-exported shell value, then expose it only to the gh child process.
unsetopt XTRACE VERBOSE
typeset HELPER_GH_TOKEN="${GH_TOKEN:-}"
typeset +x HELPER_GH_TOKEN
unset BASH_ENV ENV SHELLOPTS BASHOPTS PS4 CDPATH ZDOTDIR
unset GH_DEBUG GH_HOST GH_REPO GH_PAGER GH_FORCE_TTY GH_CONFIG_DIR
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset CODESIGN_IDENTITY_FINGERPRINT RELEASE_STATE_DIR RELEASE_LOCK_DIR
unset LEGACY_MINISIGN LEGACY_UPDATER_PRIVATE_KEY_FILE MINISIGN_PASSWORD
unset SPARKLE_DISTRIBUTION_ROOT SPARKLE_ED_KEY_PATH SPARKLE_PUBLIC_ED_KEY_FILE
unset SPARKLE_GENERATE_APPCAST_SHA256 SPARKLE_SIGN_UPDATE_SHA256
unset SPARKLE_SIGNATURE_VERIFIER SPARKLE_SIGNATURE_VERIFIER_SHA256
unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
unset SAVED_GH_TOKEN SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
unset PRODUCT_LOCK_TOKEN
unset XDG_CONFIG_HOME
unset PYTHONPATH PYTHONHOME PYTHONINSPECT PYTHONSTARTUP
unset PERL5OPT PERL5LIB RUBYOPT RUBYLIB NODE_OPTIONS NODE_PATH
unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
unset LD_PRELOAD LD_LIBRARY_PATH SSH_ASKPASS
unset -m 'GIT_*' 'DYLD_*' 'LC_*'

set -e
set -u
setopt PIPE_FAIL

umask 077

# Keep executable discovery independent of the caller's PATH. In particular,
# never execute a repository-local gh shim.
export PATH='/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'
export GH_HOST='github.com'
export GH_PROMPT_DISABLED='1'
export GIT_TERMINAL_PROMPT='0'
export NO_COLOR='1'
export LANG='C'
export LC_ALL='C'

readonly SCRIPT_PATH="${0:A}"
readonly SCRIPT_DIR="${SCRIPT_PATH:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly DIST="$ROOT/dist"

typeset ACTION=''
typeset STATE_DIR_INPUT=''
typeset STATE_DIR=''
typeset NOTES_INPUT=''
typeset NOTES_FILE=''
typeset NOTES_PROVIDED='0'
typeset CONFIRM=''

typeset REPOSITORY="${MIHOMOBOX_GITHUB_REPOSITORY:-psyche08/mihomo-app}"
typeset VERSION=''
typeset TAG=''
typeset HEAD_SHA=''
typeset BRANCH_REF=''
typeset GH_BIN=''

typeset MANIFEST_FILE=''
typeset MANIFEST_SHA256=''
typeset STATE_FILE=''
typeset STATE_PHASE=''
typeset STATE_RELEASE_ID=''
typeset NOTES_MODE=''
typeset NOTES_SHA256=''
typeset DEFAULT_NOTES=''

typeset LOCK_BASE=''
typeset LOCK_TOKEN_FILE=''
typeset LOCK_TOKEN_TEMP=''
typeset LOCK_TOKEN=''
typeset +x LOCK_TOKEN_FILE LOCK_TOKEN_TEMP LOCK_TOKEN

typeset RELEASE_ROWS_FILE=''
typeset TAG_ROWS_FILE=''
typeset RELEASE_ROW_COUNT='0'
typeset EXACT_RELEASE_ID=''
typeset EXACT_RELEASE_DRAFT=''
typeset EXACT_RELEASE_PRERELEASE=''
typeset EXACT_RELEASE_TARGET=''

typeset RELEASE_ID=''
typeset RELEASE_TAG=''
typeset RELEASE_DRAFT=''
typeset RELEASE_PRERELEASE=''
typeset RELEASE_TARGET=''
typeset RELEASE_PUBLISHED_AT=''
typeset RELEASE_NAME=''
typeset RELEASE_BODY_FILE=''
typeset RELEASE_BODY_SHA256=''
typeset REMOTE_TAG_EXISTS='0'
typeset REMOTE_TAG_OBJECT=''
typeset REMOTE_MAIN_SHA=''

typeset ASSET_ROWS_FILE=''
typeset RESPONSE_FILE=''
typeset -a TEMP_FILES=()
typeset -a ASSET_NAMES=()
typeset -a ASSET_PATHS=()
typeset -a MISSING_ASSETS=()
typeset -A LOCAL_ASSET_PATH=()
typeset -A LOCAL_ASSET_SHA256=()
typeset -A LOCAL_ASSET_SIZE=()
typeset -A REMOTE_ASSET_SEEN=()

usage() {
  /usr/bin/printf '%s\n' \
    'usage:' \
    '  release-github.zsh prepare --state-dir ABS [--notes FILE]' \
    '  release-github.zsh publish --state-dir ABS --confirm vX.Y.Z@FULL_SHA' >&2
}

die() {
  /usr/bin/printf 'release-github: %s\n' "$*" >&2
  exit 1
}

new_temp_file() {
  local prefix="$1"
  REPLY="$(/usr/bin/mktemp "$STATE_DIR/.${prefix}.XXXXXX")" ||
    die "could not create a temporary state file"
  /bin/chmod 600 "$REPLY"
  TEMP_FILES+=("$REPLY")
}

cleanup_release_lock() {
  local current_token=''

  # The fixed lock and unique temporary token are hard links after successful
  # acquisition. Comparing the random token makes cleanup ownership-safe even
  # if a signal arrives between link(2) and the following shell assignment.
  if [[ -n "$LOCK_TOKEN" && -f "$LOCK_TOKEN_FILE" && ! -L "$LOCK_TOKEN_FILE" ]]; then
    IFS= read -r current_token < "$LOCK_TOKEN_FILE" || current_token=''
    if [[ "$current_token" == "$LOCK_TOKEN" ]]; then
      /bin/rm -f -- "$LOCK_TOKEN_FILE"
    fi
  fi
  if [[ -n "$LOCK_TOKEN_TEMP" && "$LOCK_TOKEN_TEMP" == "$LOCK_BASE"/.token.* &&
        -f "$LOCK_TOKEN_TEMP" && ! -L "$LOCK_TOKEN_TEMP" ]]; then
    /bin/rm -f -- "$LOCK_TOKEN_TEMP"
  fi
  LOCK_TOKEN_TEMP=''
}

cleanup() {
  local exit_code="$?"
  local temporary=''

  trap - EXIT
  trap - HUP
  trap - INT
  trap - TERM
  set +e
  for temporary in "${TEMP_FILES[@]}"; do
    if [[ -n "$temporary" && "$temporary" == "$STATE_DIR"/.* &&
          -e "$temporary" && ! -d "$temporary" ]]; then
      /bin/rm -f -- "$temporary"
    fi
  done
  cleanup_release_lock
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

sha256_text() {
  /usr/bin/printf '%s' "$1" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

decode_base64_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/base64 -D
}

file_size() {
  /usr/bin/stat -f '%z' "$1"
}

file_mode() {
  /usr/bin/stat -f '%Lp' "$1"
}

require_safe_regular_file() {
  local path="$1"
  local label="$2"

  [[ -f "$path" && ! -L "$path" ]] ||
    die "$label must be a regular non-symlink file: $path"
}

require_mode_600() {
  local path="$1"
  local label="$2"
  local mode=''

  mode="$(file_mode "$path")"
  [[ "$mode" == '600' ]] ||
    die "$label must have mode 0600: $path"
}

parse_arguments() {
  (( $# >= 1 )) || {
    usage
    exit 2
  }

  ACTION="$1"
  shift
  case "$ACTION" in
    prepare|publish) ;;
    *)
      usage
      die "action must be prepare or publish"
      ;;
  esac

  while (( $# > 0 )); do
    case "$1" in
      --state-dir)
        (( $# >= 2 )) || die "--state-dir requires a value"
        [[ -z "$STATE_DIR_INPUT" ]] || die "--state-dir may be specified only once"
        STATE_DIR_INPUT="$2"
        shift 2
        ;;
      --notes)
        (( $# >= 2 )) || die "--notes requires a value"
        [[ "$NOTES_PROVIDED" == '0' ]] || die "--notes may be specified only once"
        NOTES_INPUT="$2"
        NOTES_PROVIDED='1'
        shift 2
        ;;
      --confirm)
        (( $# >= 2 )) || die "--confirm requires a value"
        [[ -z "$CONFIRM" ]] || die "--confirm may be specified only once"
        CONFIRM="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$STATE_DIR_INPUT" ]] || die "--state-dir is required"
  [[ "$STATE_DIR_INPUT" == /* ]] || die "--state-dir must be absolute"
  [[ "$STATE_DIR_INPUT" != *$'\n'* && "$STATE_DIR_INPUT" != *$'\t'* ]] ||
    die "--state-dir contains an unsupported character"

  if [[ "$ACTION" == 'prepare' ]]; then
    [[ -z "$CONFIRM" ]] || die "--confirm is valid only for publish"
  else
    [[ -n "$CONFIRM" ]] || die "publish requires --confirm vX.Y.Z@FULL_SHA"
    [[ "$NOTES_PROVIDED" == '0' ]] ||
      die "--notes is valid only for prepare; publish uses frozen notes state"
  fi

  if [[ "$NOTES_PROVIDED" == '1' ]]; then
    [[ "$NOTES_INPUT" != *$'\n'* && "$NOTES_INPUT" != *$'\t'* ]] ||
      die "--notes contains an unsupported character"
    require_safe_regular_file "$NOTES_INPUT" "release notes"
    NOTES_FILE="$(cd -P -- "${NOTES_INPUT:h}" && /bin/pwd)/${NOTES_INPUT:t}"
    require_safe_regular_file "$NOTES_FILE" "release notes"
  fi
}

prepare_state_directory() {
  local state_root="$DIST/.release-state"
  local expected_state_dir="$DIST/.release-state/$VERSION-$HEAD_SHA"

  [[ "$STATE_DIR_INPUT" == "$expected_state_dir" ]] ||
    die "--state-dir must be exactly $expected_state_dir"
  [[ -d "$DIST" && ! -L "$DIST" ]] ||
    die "dist must be a non-symlink directory"
  if [[ -e "$state_root" ]]; then
    [[ -d "$state_root" && ! -L "$state_root" ]] ||
      die "dist/.release-state must be a non-symlink directory"
  else
    /bin/mkdir -- "$state_root"
  fi
  if [[ -e "$STATE_DIR_INPUT" ]]; then
    [[ -d "$STATE_DIR_INPUT" && ! -L "$STATE_DIR_INPUT" ]] ||
      die "--state-dir must be a non-symlink directory"
  else
    /bin/mkdir -- "$STATE_DIR_INPUT"
  fi
  STATE_DIR="$(cd -P -- "$STATE_DIR_INPUT" && /bin/pwd)"
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] ||
    die "could not resolve --state-dir safely"
  [[ "$STATE_DIR" == "$expected_state_dir" ]] ||
    die "--state-dir must resolve exactly to $expected_state_dir"

  MANIFEST_FILE="$STATE_DIR/release-assets.tsv"
  STATE_FILE="$STATE_DIR/github-release.json"
}

find_gh() {
  local candidate=''
  local resolved=''
  local owner=''
  local mode=''
  local group_digit=''
  local world_digit=''

  for candidate in \
    /opt/homebrew/bin/gh \
    /usr/local/bin/gh \
    /usr/bin/gh; do
    if [[ -x "$candidate" ]]; then
      resolved="${candidate:A}"
      [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
        die "GitHub CLI did not resolve to a regular executable"
      owner="$(/usr/bin/stat -f '%u' "$resolved")"
      [[ "$owner" == '0' || "$owner" == "$EUID" ]] ||
        die "GitHub CLI executable has an untrusted owner"
      mode="$(/usr/bin/stat -f '%Lp' "$resolved")"
      [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "GitHub CLI executable mode is invalid"
      group_digit="${mode[-2]}"
      world_digit="${mode[-1]}"
      [[ "$group_digit" != [2367] && "$world_digit" != [2367] ]] ||
        die "GitHub CLI executable must not be group/world writable"
      GH_BIN="$resolved"
      break
    fi
  done
  [[ -n "$GH_BIN" && "$GH_BIN" == /* && -f "$GH_BIN" && ! -L "$GH_BIN" && -x "$GH_BIN" ]] ||
    die "GitHub CLI was not found in a trusted executable directory"
}

validate_repository_name() {
  [[ "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9_.-]+$ ]] ||
    die "MIHOMOBOX_GITHUB_REPOSITORY must be owner/repository"
  [[ "$REPOSITORY" != *'..'* ]] ||
    die "repository name must not contain '..'"
}

validate_origin_repository() {
  local origin_url=''

  origin_url="$(/usr/bin/git -C "$ROOT" remote get-url --push origin)" ||
    die "origin has no push URL"
  case "$origin_url" in
    "git@github.com:${REPOSITORY}.git"|\
    "ssh://git@github.com/${REPOSITORY}.git"|\
    "https://github.com/${REPOSITORY}.git"|\
    "https://github.com/${REPOSITORY}") ;;
    *) die "origin push URL does not match github.com/$REPOSITORY" ;;
  esac
}

derive_repository_state() {
  local version_text=''
  local worktree_changes=''
  local remote_main_sha=''

  require_safe_regular_file "$ROOT/VERSION" "VERSION"
  version_text="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
  [[ "$version_text" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "VERSION must contain one semantic version"
  VERSION="$version_text"
  TAG="v$VERSION"
  DEFAULT_NOTES="MihomoBox $VERSION"

  HEAD_SHA="$(/usr/bin/git -C "$ROOT" rev-parse --verify 'HEAD^{commit}')" ||
    die "could not resolve HEAD"
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40,64}$ ]] || die "HEAD is not a full object ID"

  BRANCH_REF="$(/usr/bin/git -C "$ROOT" symbolic-ref -q HEAD)" ||
    die "detached HEAD is not allowed"
  [[ "$BRANCH_REF" == refs/heads/* ]] || die "HEAD is not a local branch"

  worktree_changes="$(/usr/bin/git -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
  [[ -z "$worktree_changes" ]] || die "working tree must be clean"

  /usr/bin/git -C "$ROOT" fetch --no-tags origin \
    'refs/heads/main:refs/remotes/origin/main' >/dev/null ||
    die "could not refresh origin/main"
  remote_main_sha="$(
    /usr/bin/git -C "$ROOT" rev-parse --verify 'refs/remotes/origin/main^{commit}'
  )" || die "could not resolve origin/main"
  /usr/bin/git -C "$ROOT" merge-base --is-ancestor "$remote_main_sha" "$HEAD_SHA" ||
    die "origin/main must be an ancestor of HEAD"

  validate_origin_repository

  if [[ "$ACTION" == 'publish' && "$CONFIRM" != "$TAG@$HEAD_SHA" ]]; then
    die "--confirm must exactly equal $TAG@$HEAD_SHA"
  fi
}

acquire_release_lock() {
  local lock_owner=''
  local lock_mode=''
  local safe_repository="${REPOSITORY//\//-}"

  LOCK_BASE="/tmp/mihomobox-github-release-${EUID}"
  if ! /bin/mkdir -m 700 -- "$LOCK_BASE" 2>/dev/null; then
    [[ -d "$LOCK_BASE" && ! -L "$LOCK_BASE" ]] ||
      die "global GitHub release lock root is unsafe"
    lock_owner="$(/usr/bin/stat -f '%u' "$LOCK_BASE")"
    [[ "$lock_owner" == "$EUID" ]] ||
      die "global GitHub release lock root has the wrong owner"
  fi
  lock_mode="$(/usr/bin/stat -f '%Lp' "$LOCK_BASE")"
  [[ "$lock_mode" == '700' ]] ||
    die "global GitHub release lock root must have mode 0700"

  LOCK_TOKEN_FILE="$LOCK_BASE/${safe_repository}.lock"
  LOCK_TOKEN="${HEAD_SHA}.$$.$(/bin/date -u '+%Y%m%dT%H%M%SZ').${RANDOM}${RANDOM}"
  LOCK_TOKEN_TEMP="$(/usr/bin/mktemp "$LOCK_BASE/.token.XXXXXX")" ||
    die "could not create global GitHub release lock token"
  /usr/bin/printf '%s\n' "$LOCK_TOKEN" > "$LOCK_TOKEN_TEMP"
  /bin/chmod 600 "$LOCK_TOKEN_TEMP"
  if ! /bin/ln -- "$LOCK_TOKEN_TEMP" "$LOCK_TOKEN_FILE" 2>/dev/null; then
    die "another GitHub release operation holds the repository lock"
  fi

  /bin/rm -f -- "$LOCK_TOKEN_TEMP"
  LOCK_TOKEN_TEMP=''
}

validate_release_feeds() {
  local archive_name="MihomoBox-$VERSION-macos-arm64.app.tar.gz"
  local dmg_name="MihomoBox-$VERSION-macos-arm64.dmg"
  local archive_url="https://github.com/$REPOSITORY/releases/download/$TAG/$archive_name"
  local dmg_url="https://github.com/$REPOSITORY/releases/download/$TAG/$dmg_name"
  local latest_version=''
  local latest_url=''
  local enclosure_xpath=''
  local enclosure_count=''
  local enclosure_length=''
  local expected_dmg_length=''
  local appcast_version=''
  local appcast_short_version=''

  require_safe_regular_file "$DIST/latest.json" "latest.json"
  require_safe_regular_file "$DIST/appcast.xml" "appcast.xml"
  /usr/bin/plutil -convert json -o /dev/null "$DIST/latest.json"
  /usr/bin/xmllint --noout "$DIST/appcast.xml"

  latest_version="$(/usr/bin/plutil -extract version raw -n -o - "$DIST/latest.json")" ||
    die "latest.json has no version"
  latest_url="$(/usr/bin/plutil -extract 'platforms.darwin-aarch64.url' raw -n -o - "$DIST/latest.json")" ||
    die "latest.json has no darwin-aarch64 URL"
  [[ "$latest_version" == "$VERSION" ]] ||
    die "latest.json version does not match VERSION"
  [[ "$latest_url" == "$archive_url" ]] ||
    die "latest.json URL does not match the current tag and archive"

  enclosure_xpath="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='enclosure'][@url='$dmg_url']"
  enclosure_count="$(/usr/bin/xmllint --xpath "count($enclosure_xpath)" "$DIST/appcast.xml")" ||
    die "could not inspect appcast.xml enclosure"
  [[ "$enclosure_count" == '1' ]] ||
    die "appcast.xml must contain exactly one current DMG enclosure"

  enclosure_length="$(/usr/bin/xmllint --xpath "string(($enclosure_xpath)[1]/@length)" "$DIST/appcast.xml")"
  expected_dmg_length="$(file_size "$DIST/$dmg_name")"
  [[ "$enclosure_length" == "$expected_dmg_length" ]] ||
    die "appcast.xml enclosure length does not match the current DMG"

  appcast_version="$(/usr/bin/xmllint --xpath \
    "string((/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='version'])[1])" \
    "$DIST/appcast.xml")"
  appcast_short_version="$(/usr/bin/xmllint --xpath \
    "string((/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='shortVersionString'])[1])" \
    "$DIST/appcast.xml")"
  [[ "$appcast_version" == "$VERSION" && "$appcast_short_version" == "$VERSION" ]] ||
    die "appcast.xml version does not match VERSION"
}

build_local_asset_manifest() {
  local allow_create="$1"
  local index=0
  local name=''
  local path=''
  local digest=''
  local size=''
  local manifest_temporary=''

  ASSET_NAMES=(
    "MihomoBox-$VERSION-macos-arm64.app.tar.gz"
    "MihomoBox-$VERSION-macos-arm64.app.tar.gz.sig"
    "MihomoBox-$VERSION-macos-arm64.dmg"
    'latest.json'
    'appcast.xml'
  )
  ASSET_PATHS=(
    "$DIST/${ASSET_NAMES[1]}"
    "$DIST/${ASSET_NAMES[2]}"
    "$DIST/${ASSET_NAMES[3]}"
    "$DIST/${ASSET_NAMES[4]}"
    "$DIST/${ASSET_NAMES[5]}"
  )

  LOCAL_ASSET_PATH=()
  LOCAL_ASSET_SHA256=()
  LOCAL_ASSET_SIZE=()

  new_temp_file 'release-assets'
  manifest_temporary="$REPLY"
  : > "$manifest_temporary"

  for (( index = 1; index <= ${#ASSET_NAMES[@]}; ++index )); do
    name="${ASSET_NAMES[$index]}"
    path="${ASSET_PATHS[$index]}"
    require_safe_regular_file "$path" "release asset $name"
    size="$(file_size "$path")"
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "release asset is empty: $name"
    digest="$(sha256_file "$path")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "could not hash release asset: $name"

    LOCAL_ASSET_PATH[$name]="$path"
    LOCAL_ASSET_SHA256[$name]="$digest"
    LOCAL_ASSET_SIZE[$name]="$size"
    /usr/bin/printf '%s\t%s\t%s\n' "$digest" "$size" "$name" >> "$manifest_temporary"
  done
  /bin/chmod 600 "$manifest_temporary"

  if [[ -e "$MANIFEST_FILE" ]]; then
    require_safe_regular_file "$MANIFEST_FILE" "release asset manifest"
    require_mode_600 "$MANIFEST_FILE" "release asset manifest"
    /usr/bin/cmp -s "$manifest_temporary" "$MANIFEST_FILE" ||
      die "frozen release asset manifest does not match current files"
  else
    [[ "$allow_create" == '1' ]] ||
      die "publish requires an existing frozen release-assets.tsv"
    /bin/mv -n -- "$manifest_temporary" "$MANIFEST_FILE"
    if [[ -e "$manifest_temporary" ]]; then
      require_safe_regular_file "$MANIFEST_FILE" "release asset manifest"
      /usr/bin/cmp -s "$manifest_temporary" "$MANIFEST_FILE" ||
        die "release asset manifest appeared concurrently with different bytes"
    fi
  fi

  MANIFEST_SHA256="$(sha256_file "$MANIFEST_FILE")"
  [[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "could not hash release asset manifest"
}

state_value() {
  local key="$1"

  if /usr/bin/plutil -type "$key" "$STATE_FILE" >/dev/null 2>&1; then
    /usr/bin/plutil -extract "$key" raw -n -o - "$STATE_FILE"
  fi
}

load_and_validate_state() {
  local schema=''
  local stored=''

  if [[ ! -e "$STATE_FILE" ]]; then
    STATE_PHASE=''
    STATE_RELEASE_ID=''
    if [[ "$NOTES_PROVIDED" == '1' ]]; then
      NOTES_MODE='file'
      NOTES_SHA256="$(sha256_file "$NOTES_FILE")"
    else
      NOTES_MODE='default'
      NOTES_SHA256="$(sha256_text "$DEFAULT_NOTES")"
    fi
    return 0
  fi

  require_safe_regular_file "$STATE_FILE" "GitHub release state"
  require_mode_600 "$STATE_FILE" "GitHub release state"
  /usr/bin/plutil -convert json -o /dev/null "$STATE_FILE"
  schema="$(state_value schema_version)"
  [[ "$schema" == '1' ]] || die "unsupported GitHub release state schema"
  [[ "$(state_value repository)" == "$REPOSITORY" ]] || die "state repository mismatch"
  [[ "$(state_value version)" == "$VERSION" ]] || die "state version mismatch"
  [[ "$(state_value tag)" == "$TAG" ]] || die "state tag mismatch"
  [[ "$(state_value commit)" == "$HEAD_SHA" ]] || die "state commit mismatch"
  [[ "$(state_value manifest_sha256)" == "$MANIFEST_SHA256" ]] ||
    die "state manifest digest mismatch"

  STATE_PHASE="$(state_value phase)"
  case "$STATE_PHASE" in
    create_pending|draft_bound|uploading|uploaded_verified|published_verified) ;;
    *) die "invalid GitHub release state phase" ;;
  esac

  STATE_RELEASE_ID="$(state_value release_id)"
  if [[ -n "$STATE_RELEASE_ID" && ! "$STATE_RELEASE_ID" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid release_id in state"
  fi
  if [[ "$STATE_PHASE" == 'create_pending' ]]; then
    [[ -z "$STATE_RELEASE_ID" ]] || die "create_pending state must not have a release_id"
  else
    [[ -n "$STATE_RELEASE_ID" ]] || die "state phase requires a release_id"
  fi

  NOTES_MODE="$(state_value notes_mode)"
  NOTES_SHA256="$(state_value notes_sha256)"
  [[ "$NOTES_MODE" == 'default' || "$NOTES_MODE" == 'file' ]] ||
    die "invalid notes mode in state"
  [[ "$NOTES_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid notes digest in state"

  if [[ "$NOTES_PROVIDED" == '1' ]]; then
    stored="$(sha256_file "$NOTES_FILE")"
    [[ "$NOTES_MODE" == 'file' && "$stored" == "$NOTES_SHA256" ]] ||
      die "release notes do not match frozen state"
  fi
}

write_state() {
  local phase="$1"
  local release_id="${2:-}"
  local state_temporary=''
  local updated_at=''

  case "$phase" in
    create_pending)
      [[ -z "$release_id" ]] || die "internal invalid create_pending state"
      ;;
    draft_bound|uploading|uploaded_verified|published_verified)
      [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || die "internal invalid release ID"
      ;;
    *) die "internal invalid state phase" ;;
  esac

  if [[ -e "$STATE_FILE" ]]; then
    require_safe_regular_file "$STATE_FILE" "GitHub release state"
    require_mode_600 "$STATE_FILE" "GitHub release state"
  fi

  new_temp_file 'github-release'
  state_temporary="$REPLY"
  updated_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

  /usr/bin/plutil -create xml1 - > "$state_temporary"
  /usr/bin/plutil -insert schema_version -integer 1 "$state_temporary"
  /usr/bin/plutil -insert repository -string "$REPOSITORY" "$state_temporary"
  /usr/bin/plutil -insert version -string "$VERSION" "$state_temporary"
  /usr/bin/plutil -insert tag -string "$TAG" "$state_temporary"
  /usr/bin/plutil -insert commit -string "$HEAD_SHA" "$state_temporary"
  /usr/bin/plutil -insert phase -string "$phase" "$state_temporary"
  /usr/bin/plutil -insert manifest_sha256 -string "$MANIFEST_SHA256" "$state_temporary"
  /usr/bin/plutil -insert notes_mode -string "$NOTES_MODE" "$state_temporary"
  /usr/bin/plutil -insert notes_sha256 -string "$NOTES_SHA256" "$state_temporary"
  /usr/bin/plutil -insert updated_at -string "$updated_at" "$state_temporary"
  if [[ -n "$release_id" ]]; then
    /usr/bin/plutil -insert release_id -integer "$release_id" "$state_temporary"
  fi
  /usr/bin/plutil -convert json "$state_temporary"
  /bin/chmod 600 "$state_temporary"
  /bin/mv -f -- "$state_temporary" "$STATE_FILE"

  STATE_PHASE="$phase"
  STATE_RELEASE_ID="$release_id"
}

gh_with_auth() {
  (
    if [[ -n "$HELPER_GH_TOKEN" ]]; then
      export GH_TOKEN="$HELPER_GH_TOKEN"
    else
      unset GH_TOKEN
    fi
    exec "$GH_BIN" "$@"
  )
}

gh_api() {
  gh_with_auth api \
    --hostname github.com \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$@"
}

require_gh_authentication() {
  gh_with_auth auth status --hostname github.com >/dev/null 2>&1 ||
    die "GitHub CLI is not authenticated for github.com"
}

create_or_validate_annotated_tag() {
  local object_type=''
  local tag_commit=''

  if /usr/bin/git -C "$ROOT" show-ref --verify --quiet "refs/tags/$TAG"; then
    object_type="$(/usr/bin/git -C "$ROOT" cat-file -t "refs/tags/$TAG")"
    [[ "$object_type" == 'tag' ]] || die "$TAG must be an annotated tag"
    tag_commit="$(/usr/bin/git -C "$ROOT" rev-parse --verify "refs/tags/$TAG^{commit}")"
    [[ "$tag_commit" == "$HEAD_SHA" ]] || die "$TAG does not point to HEAD"
  else
    /usr/bin/git -C "$ROOT" -c tag.gpgSign=false tag -a "$TAG" "$HEAD_SHA" \
      -m "MihomoBox $VERSION"
  fi
}

validate_existing_annotated_tag() {
  local object_type=''
  local tag_commit=''

  /usr/bin/git -C "$ROOT" show-ref --verify --quiet "refs/tags/$TAG" ||
    die "publish requires existing annotated tag $TAG"
  object_type="$(/usr/bin/git -C "$ROOT" cat-file -t "refs/tags/$TAG")"
  [[ "$object_type" == 'tag' ]] || die "$TAG must be an annotated tag"
  tag_commit="$(/usr/bin/git -C "$ROOT" rev-parse --verify "refs/tags/$TAG^{commit}")"
  [[ "$tag_commit" == "$HEAD_SHA" ]] || die "$TAG does not point to HEAD"
}

atomic_push_main_and_tag() {
  /usr/bin/git -C "$ROOT" push --no-verify --atomic origin \
    'HEAD:refs/heads/main' \
    "refs/tags/${TAG}:refs/tags/${TAG}"
}

inspect_remote_annotated_tag() {
  local allow_missing="${1:-0}"
  local tag_ref="refs/tags/$TAG"
  local peeled_ref="refs/tags/$TAG^{}"
  local tag_count=''
  local peeled_count=''
  local tag_object=''
  local peeled_commit=''

  : > "$TAG_ROWS_FILE"
  /usr/bin/git -C "$ROOT" ls-remote origin "$tag_ref" "$peeled_ref" > "$TAG_ROWS_FILE"
  /bin/chmod 600 "$TAG_ROWS_FILE"

  tag_count="$(/usr/bin/awk -v ref="$tag_ref" '$2 == ref { count += 1 } END { print count + 0 }' "$TAG_ROWS_FILE")"
  peeled_count="$(/usr/bin/awk -v ref="$peeled_ref" '$2 == ref { count += 1 } END { print count + 0 }' "$TAG_ROWS_FILE")"
  REMOTE_TAG_EXISTS='0'
  REMOTE_TAG_OBJECT=''
  if [[ "$tag_count" == '0' && "$peeled_count" == '0' && "$allow_missing" == '1' ]]; then
    return 0
  fi
  [[ "$tag_count" == '1' && "$peeled_count" == '1' ]] ||
    die "remote $TAG must be exactly one annotated tag with a peeled commit"

  tag_object="$(/usr/bin/awk -v ref="$tag_ref" '$2 == ref { print $1 }' "$TAG_ROWS_FILE")"
  peeled_commit="$(/usr/bin/awk -v ref="$peeled_ref" '$2 == ref { print $1 }' "$TAG_ROWS_FILE")"
  [[ "$tag_object" =~ ^[0-9a-f]{40,64}$ && "$peeled_commit" =~ ^[0-9a-f]{40,64}$ ]] ||
    die "remote $TAG returned invalid object IDs"
  [[ "$tag_object" != "$peeled_commit" ]] || die "remote $TAG is not annotated"
  [[ "$peeled_commit" == "$HEAD_SHA" ]] ||
    die "remote annotated tag $TAG does not peel to HEAD"
  REMOTE_TAG_EXISTS='1'
  REMOTE_TAG_OBJECT="$tag_object"
}

require_remote_main_equals_head() {
  local main_ref='refs/heads/main'
  local rows=''
  local count=''

  rows="$(/usr/bin/git -C "$ROOT" ls-remote origin "$main_ref")" ||
    die "could not read remote main"
  count="$(
    /usr/bin/printf '%s\n' "$rows" |
      /usr/bin/awk -v ref="$main_ref" '$2 == ref { count += 1 } END { print count + 0 }'
  )"
  [[ "$count" == '1' ]] || die "remote main must resolve to exactly one commit"
  REMOTE_MAIN_SHA="$(
    /usr/bin/printf '%s\n' "$rows" |
      /usr/bin/awk -v ref="$main_ref" '$2 == ref { print $1 }'
  )"
  [[ "$REMOTE_MAIN_SHA" =~ ^[0-9a-f]{40,64}$ ]] ||
    die "remote main returned an invalid commit"
  [[ "$REMOTE_MAIN_SHA" == "$HEAD_SHA" ]] ||
    die "remote main does not equal the release commit"
}

require_local_tag_matches_remote() {
  local local_tag_object=''

  validate_existing_annotated_tag
  [[ "$REMOTE_TAG_EXISTS" == '1' && "$REMOTE_TAG_OBJECT" =~ ^[0-9a-f]{40,64}$ ]] ||
    die "remote annotated tag was not verified"
  local_tag_object="$(/usr/bin/git -C "$ROOT" rev-parse --verify "refs/tags/$TAG")"
  [[ "$local_tag_object" == "$REMOTE_TAG_OBJECT" ]] ||
    die "local and remote annotated tag objects differ"
}

ensure_local_tag_matches_remote() {
  if ! /usr/bin/git -C "$ROOT" show-ref --verify --quiet "refs/tags/$TAG"; then
    /usr/bin/git -C "$ROOT" fetch --no-tags --no-write-fetch-head origin \
      "refs/tags/$TAG:refs/tags/$TAG"
  fi
  require_local_tag_matches_remote
}

prepare_annotated_tag_and_main() {
  inspect_remote_annotated_tag '1'
  if [[ "$REMOTE_TAG_EXISTS" == '1' ]]; then
    ensure_local_tag_matches_remote
    require_remote_main_equals_head
    return 0
  fi

  create_or_validate_annotated_tag
  atomic_push_main_and_tag
  inspect_remote_annotated_tag '0'
  ensure_local_tag_matches_remote
  require_remote_main_equals_head
}

validate_release_target() {
  local target="$1"

  [[ "$target" == 'main' || "$target" == "$HEAD_SHA" ]] ||
    die "release target_commitish is neither main nor HEAD"
}

enumerate_exact_tag_releases() {
  local first_row=''

  : > "$RELEASE_ROWS_FILE"
  if ! gh_api --method GET --paginate \
    "repos/$REPOSITORY/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$TAG\") | [.id, .draft, .prerelease, .target_commitish] | @tsv" \
    > "$RELEASE_ROWS_FILE"; then
    return 1
  fi
  /bin/chmod 600 "$RELEASE_ROWS_FILE"

  RELEASE_ROW_COUNT="$(/usr/bin/awk 'NF { count += 1 } END { print count + 0 }' "$RELEASE_ROWS_FILE")"
  EXACT_RELEASE_ID=''
  EXACT_RELEASE_DRAFT=''
  EXACT_RELEASE_PRERELEASE=''
  EXACT_RELEASE_TARGET=''
  if [[ "$RELEASE_ROW_COUNT" == '1' ]]; then
    first_row="$(/usr/bin/sed -n '1p' "$RELEASE_ROWS_FILE")"
    IFS=$'\t' read -r \
      EXACT_RELEASE_ID EXACT_RELEASE_DRAFT EXACT_RELEASE_PRERELEASE EXACT_RELEASE_TARGET \
      <<< "$first_row"
    [[ "$EXACT_RELEASE_ID" =~ ^[1-9][0-9]*$ ]] || die "GitHub returned an invalid release ID"
    [[ "$EXACT_RELEASE_DRAFT" == 'true' || "$EXACT_RELEASE_DRAFT" == 'false' ]] ||
      die "GitHub returned an invalid draft value"
    [[ "$EXACT_RELEASE_PRERELEASE" == 'true' || "$EXACT_RELEASE_PRERELEASE" == 'false' ]] ||
      die "GitHub returned an invalid prerelease value"
    validate_release_target "$EXACT_RELEASE_TARGET"
  fi
}

fetch_release_by_id() {
  local release_id="$1"
  local row=''
  local tag_base64=''
  local name_base64=''
  local target_base64=''
  local published_base64=''
  local body_base64=''

  : > "$RESPONSE_FILE"
  gh_api --method GET "repos/$REPOSITORY/releases/$release_id" \
    --jq '[ (.id | tostring), (.tag_name | @base64), ((.name // "") | @base64), (.draft | tostring), (.prerelease | tostring), ((.target_commitish // "") | @base64), ((.published_at // "__MIHOMOBOX_UNPUBLISHED__") | @base64), ((.body // "") | @base64) ] | @tsv' \
    > "$RESPONSE_FILE"
  row="$(/usr/bin/sed -n '1p' "$RESPONSE_FILE")"
  IFS=$'\t' read -r \
    RELEASE_ID tag_base64 name_base64 RELEASE_DRAFT RELEASE_PRERELEASE target_base64 published_base64 body_base64 \
    <<< "$row"

  RELEASE_TAG="$(decode_base64_text "$tag_base64")" || die "release tag encoding is invalid"
  RELEASE_NAME="$(decode_base64_text "$name_base64")" || die "release name encoding is invalid"
  RELEASE_TARGET="$(decode_base64_text "$target_base64")" || die "release target encoding is invalid"
  RELEASE_PUBLISHED_AT="$(decode_base64_text "$published_base64")" ||
    die "release published_at encoding is invalid"
  if [[ "$RELEASE_PUBLISHED_AT" == '__MIHOMOBOX_UNPUBLISHED__' ]]; then
    RELEASE_PUBLISHED_AT=''
  fi
  : > "$RELEASE_BODY_FILE"
  /usr/bin/printf '%s' "$body_base64" | /usr/bin/base64 -D > "$RELEASE_BODY_FILE" ||
    die "release body encoding is invalid"
  /bin/chmod 600 "$RELEASE_BODY_FILE"
  RELEASE_BODY_SHA256="$(sha256_file "$RELEASE_BODY_FILE")"

  [[ "$RELEASE_ID" == "$release_id" ]] || die "release ID response mismatch"
  [[ "$RELEASE_TAG" == "$TAG" ]] || die "release tag response mismatch"
  [[ "$RELEASE_NAME" == "MihomoBox $VERSION" ]] || die "release name response mismatch"
  [[ "$RELEASE_DRAFT" == 'true' || "$RELEASE_DRAFT" == 'false' ]] ||
      die "release draft response is invalid"
  [[ "$RELEASE_PRERELEASE" == 'false' ]] || die "prerelease releases are not allowed"
  validate_release_target "$RELEASE_TARGET"
  [[ "$RELEASE_BODY_SHA256" == "$NOTES_SHA256" ]] ||
    die "release body does not match frozen notes digest"
}

require_single_canonical_release() {
  local release_id="$1"

  inspect_remote_annotated_tag '0'
  ensure_local_tag_matches_remote
  require_remote_main_equals_head
  enumerate_exact_tag_releases
  [[ "$RELEASE_ROW_COUNT" == '1' ]] ||
    die "exact tag must resolve to one GitHub Release, found $RELEASE_ROW_COUNT"
  [[ "$EXACT_RELEASE_ID" == "$release_id" ]] ||
    die "exact tag no longer resolves to the locked release ID"
  validate_release_target "$EXACT_RELEASE_TARGET"
}

create_draft_once() {
  local api_exit=0

  : > "$RESPONSE_FILE"
  if [[ "$NOTES_PROVIDED" == '1' ]]; then
    if gh_api --method POST "repos/$REPOSITORY/releases" \
      -f "tag_name=$TAG" \
      -f "target_commitish=$HEAD_SHA" \
      -f "name=MihomoBox $VERSION" \
      -F "body=@$NOTES_FILE" \
      -F draft=true \
      -F prerelease=false \
      -f make_latest=false \
      > "$RESPONSE_FILE"; then
      api_exit=0
    else
      api_exit="$?"
    fi
  else
    if gh_api --method POST "repos/$REPOSITORY/releases" \
      -f "tag_name=$TAG" \
      -f "target_commitish=$HEAD_SHA" \
      -f "name=MihomoBox $VERSION" \
      -f "body=$DEFAULT_NOTES" \
      -F draft=true \
      -F prerelease=false \
      -f make_latest=false \
      > "$RESPONSE_FILE"; then
      api_exit=0
    else
      api_exit="$?"
    fi
  fi

  return "$api_exit"
}

reconcile_create_pending() {
  local attempt=0
  local delay=0

  for attempt in 1 2 3 4; do
    if (( attempt > 1 )); then
      case "$attempt" in
        2) delay=2 ;;
        3) delay=4 ;;
        4) delay=8 ;;
      esac
      /bin/sleep "$delay"
    fi

    if enumerate_exact_tag_releases; then
      case "$RELEASE_ROW_COUNT" in
        1)
          [[ "$EXACT_RELEASE_DRAFT" == 'true' ]] ||
            die "the exact-tag release is already public while creation was pending"
          [[ "$EXACT_RELEASE_PRERELEASE" == 'false' ]] ||
            die "the exact-tag release is a prerelease"
          validate_release_target "$EXACT_RELEASE_TARGET"
          inspect_remote_annotated_tag '0'
          ensure_local_tag_matches_remote
          STATE_RELEASE_ID="$EXACT_RELEASE_ID"
          fetch_release_by_id "$STATE_RELEASE_ID"
          write_state draft_bound "$STATE_RELEASE_ID"
          return 0
          ;;
        0) ;;
        *) die "multiple exact-tag releases exist; refusing automatic reconciliation" ;;
      esac
    fi
  done

  die "draft creation remains unresolved; create_pending was preserved and POST will not be repeated"
}

bind_or_create_draft() {
  local create_exit=0

  if [[ -n "$STATE_RELEASE_ID" ]]; then
    require_single_canonical_release "$STATE_RELEASE_ID"
    fetch_release_by_id "$STATE_RELEASE_ID"
    return 0
  fi

  enumerate_exact_tag_releases
  case "$RELEASE_ROW_COUNT" in
    1)
      [[ "$EXACT_RELEASE_DRAFT" == 'true' ]] ||
        die "an exact-tag public release already exists without matching bound state"
      [[ "$EXACT_RELEASE_PRERELEASE" == 'false' ]] ||
        die "the exact-tag release is a prerelease"
      validate_release_target "$EXACT_RELEASE_TARGET"
      inspect_remote_annotated_tag '0'
      ensure_local_tag_matches_remote
      STATE_RELEASE_ID="$EXACT_RELEASE_ID"
      fetch_release_by_id "$STATE_RELEASE_ID"
      write_state draft_bound "$STATE_RELEASE_ID"
      ;;
    0)
      if [[ "$STATE_PHASE" == 'create_pending' ]]; then
        reconcile_create_pending
        fetch_release_by_id "$STATE_RELEASE_ID"
        return 0
      fi

      write_state create_pending ''
      if create_draft_once; then
        create_exit=0
      else
        create_exit="$?"
      fi
      # A failed request may have committed remotely. A successful response is
      # also reconciled by enumeration so the state never trusts response text
      # alone. There is intentionally no second create POST here.
      reconcile_create_pending
      fetch_release_by_id "$STATE_RELEASE_ID"
      if (( create_exit != 0 )); then
        /usr/bin/printf 'release-github: recovered draft after create request exit=%s\n' \
          "$create_exit" >&2
      fi
      ;;
    *) die "multiple exact-tag releases exist; refusing to choose or delete one" ;;
  esac
}

load_and_validate_remote_assets() {
  local release_id="$1"
  local row=''
  local asset_id=''
  local name=''
  local asset_state=''
  local size=''
  local digest=''
  local expected_digest=''

  : > "$ASSET_ROWS_FILE"
  gh_api --method GET --paginate \
    "repos/$REPOSITORY/releases/$release_id/assets?per_page=100" \
    --jq '.[] | [.id, .name, .state, .size, (.digest // "")] | @tsv' \
    > "$ASSET_ROWS_FILE"
  /bin/chmod 600 "$ASSET_ROWS_FILE"

  REMOTE_ASSET_SEEN=()
  MISSING_ASSETS=()
  while IFS=$'\t' read -r asset_id name asset_state size digest; do
    [[ -n "$asset_id" ]] || continue
    [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || die "GitHub returned an invalid asset ID"
    [[ -n "${LOCAL_ASSET_PATH[$name]-}" ]] ||
      die "unexpected asset exists on locked release: $name"
    [[ -z "${REMOTE_ASSET_SEEN[$name]-}" ]] ||
      die "duplicate asset exists on locked release: $name"
    REMOTE_ASSET_SEEN[$name]="$asset_id"

    [[ "$asset_state" == 'uploaded' ]] ||
      die "existing asset is not uploaded: $name state=$asset_state"
    [[ "$size" == "${LOCAL_ASSET_SIZE[$name]}" ]] ||
      die "existing asset size mismatch: $name"
    expected_digest="sha256:${LOCAL_ASSET_SHA256[$name]}"
    [[ "$digest" == "$expected_digest" ]] ||
      die "existing asset digest mismatch: $name"
  done < "$ASSET_ROWS_FILE"

  for name in "${ASSET_NAMES[@]}"; do
    if [[ -z "${REMOTE_ASSET_SEEN[$name]-}" ]]; then
      MISSING_ASSETS+=("$name")
    fi
  done
}

reconcile_uploaded_asset() {
  local release_id="$1"
  local name="$2"
  local attempt=0
  local delay=0

  for attempt in 1 2 3 4; do
    if (( attempt > 1 )); then
      case "$attempt" in
        2) delay=2 ;;
        3) delay=4 ;;
        4) delay=8 ;;
      esac
      /bin/sleep "$delay"
    fi
    load_and_validate_remote_assets "$release_id"
    if [[ -n "${REMOTE_ASSET_SEEN[$name]-}" ]]; then
      return 0
    fi
  done
  return 1
}

upload_asset_by_release_id() {
  local release_id="$1"
  local name="$2"
  local path="$3"
  local upload_url=''

  [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || die "internal invalid upload release ID"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "internal invalid upload asset name"
  require_safe_regular_file "$path" "release asset $name"
  upload_url="https://uploads.github.com/repos/$REPOSITORY/releases/$release_id/assets?name=$name"
  : > "$RESPONSE_FILE"

  # curl reads the Authorization header from stdin. The token is validated and
  # never expanded into argv, written to state, or echoed to diagnostics.
  gh_with_auth auth token --hostname github.com |
    /usr/bin/awk '
      NR == 1 && $0 ~ /^[A-Za-z0-9_-]+$/ { token = $0; next }
      { invalid = 1 }
      END {
        if (NR != 1 || invalid || token == "") exit 1
        printf "header = \"Authorization: Bearer %s\"\n", token
      }
    ' |
    /usr/bin/curl \
      --disable \
      --config - \
      --silent \
      --show-error \
      --fail \
      --proto '=https' \
      --proto-redir '=https' \
      --location \
      --tlsv1.2 \
      --connect-timeout 30 \
      --max-time 1800 \
      --request POST \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header 'Content-Type: application/octet-stream' \
      --data-binary "@$path" \
      --output "$RESPONSE_FILE" \
      "$upload_url"
}

upload_missing_assets() {
  local release_id="$1"
  local name=''
  local path=''
  local upload_exit=0

  fetch_release_by_id "$release_id"
  [[ "$RELEASE_DRAFT" == 'true' ]] || die "prepare will not alter a public release"
  load_and_validate_remote_assets "$release_id"

  for name in "${MISSING_ASSETS[@]}"; do
    path="${LOCAL_ASSET_PATH[$name]}"
    require_single_canonical_release "$release_id"
    fetch_release_by_id "$release_id"
    [[ "$RELEASE_DRAFT" == 'true' ]] || die "release became public during upload"
    write_state uploading "$release_id"

    if upload_asset_by_release_id "$release_id" "$name" "$path"; then
      upload_exit=0
    else
      upload_exit="$?"
    fi

    if ! reconcile_uploaded_asset "$release_id" "$name"; then
      die "asset upload remains unresolved without overwrite: $name (exit=$upload_exit)"
    fi
    if (( upload_exit != 0 )); then
      /usr/bin/printf 'release-github: reconciled asset after upload exit=%s name=%s\n' \
        "$upload_exit" "$name" >&2
    fi
  done

  load_and_validate_remote_assets "$release_id"
  (( ${#MISSING_ASSETS[@]} == 0 )) || die "locked release is missing formal assets"
  (( ${#REMOTE_ASSET_SEEN[@]} == 5 )) ||
    die "locked release does not contain exactly five formal assets"
  write_state uploaded_verified "$release_id"
}

verify_exact_five_assets() {
  local release_id="$1"

  load_and_validate_remote_assets "$release_id"
  (( ${#MISSING_ASSETS[@]} == 0 )) || die "locked release is missing formal assets"
  (( ${#REMOTE_ASSET_SEEN[@]} == 5 )) ||
    die "locked release does not contain exactly five formal assets"
}

verify_latest_release_id() {
  local expected_id="$1"
  local latest_id=''

  latest_id="$(gh_api --method GET "repos/$REPOSITORY/releases/latest" --jq '.id')" ||
    die "could not read the latest GitHub Release"
  [[ "$latest_id" == "$expected_id" ]] ||
    die "latest GitHub Release does not match the locked release ID"
}

publish_locked_release() {
  local release_id="$STATE_RELEASE_ID"
  local patch_exit=0

  [[ -n "$release_id" ]] || die "publish requires a locked release_id"
  require_single_canonical_release "$release_id"
  fetch_release_by_id "$release_id"
  verify_exact_five_assets "$release_id"

  if [[ "$RELEASE_DRAFT" == 'false' ]]; then
    [[ -n "$RELEASE_PUBLISHED_AT" ]] || die "public release has no published_at timestamp"
    verify_latest_release_id "$release_id"
    write_state published_verified "$release_id"
    /usr/bin/printf 'verified already-published %s release_id=%s\n' "$TAG" "$release_id"
    return 0
  fi

  [[ "$RELEASE_DRAFT" == 'true' ]] || die "release draft state is invalid"
  [[ "$STATE_PHASE" == 'uploaded_verified' || "$STATE_PHASE" == 'published_verified' ]] ||
    die "publish requires uploaded_verified state"

  : > "$RESPONSE_FILE"
  if gh_api --method PATCH "repos/$REPOSITORY/releases/$release_id" \
    -F draft=false \
    -F prerelease=false \
    -f make_latest=true \
    > "$RESPONSE_FILE"; then
    patch_exit=0
  else
    patch_exit="$?"
  fi

  # PATCH may have committed even when the response was lost. Read by locked
  # ID and never issue a second publish mutation in this invocation.
  fetch_release_by_id "$release_id"
  [[ "$RELEASE_DRAFT" == 'false' && -n "$RELEASE_PUBLISHED_AT" ]] ||
    die "publish outcome remains unresolved; no second PATCH was attempted (exit=$patch_exit)"
  require_single_canonical_release "$release_id"
  verify_exact_five_assets "$release_id"
  verify_latest_release_id "$release_id"
  write_state published_verified "$release_id"
  /usr/bin/printf 'published %s release_id=%s commit=%s\n' "$TAG" "$release_id" "$HEAD_SHA"
}

prepare_temp_files() {
  new_temp_file 'tag-rows'
  TAG_ROWS_FILE="$REPLY"
  new_temp_file 'release-rows'
  RELEASE_ROWS_FILE="$REPLY"
  new_temp_file 'asset-rows'
  ASSET_ROWS_FILE="$REPLY"
  new_temp_file 'github-response'
  RESPONSE_FILE="$REPLY"
  new_temp_file 'release-body'
  RELEASE_BODY_FILE="$REPLY"
}

main() {
  parse_arguments "$@"
  find_gh
  validate_repository_name
  derive_repository_state
  prepare_state_directory
  acquire_release_lock
  prepare_temp_files

  validate_release_feeds
  if [[ "$ACTION" == 'prepare' ]]; then
    build_local_asset_manifest '1'
  else
    [[ -e "$STATE_FILE" ]] || die "publish requires existing github-release.json"
    build_local_asset_manifest '0'
  fi
  load_and_validate_state
  require_gh_authentication

  if [[ "$ACTION" == 'prepare' ]]; then
    prepare_annotated_tag_and_main
    bind_or_create_draft
    if [[ "$RELEASE_DRAFT" == 'false' ]]; then
      verify_exact_five_assets "$STATE_RELEASE_ID"
      verify_latest_release_id "$STATE_RELEASE_ID"
      write_state published_verified "$STATE_RELEASE_ID"
      /usr/bin/printf 'verified already-published %s release_id=%s\n' \
        "$TAG" "$STATE_RELEASE_ID"
      return 0
    fi
    upload_missing_assets "$STATE_RELEASE_ID"
    /usr/bin/printf 'prepared draft %s release_id=%s assets=5 commit=%s\n' \
      "$TAG" "$STATE_RELEASE_ID" "$HEAD_SHA"
  else
    inspect_remote_annotated_tag '0'
    ensure_local_tag_matches_remote
    publish_locked_release
  fi
}

main "$@"
