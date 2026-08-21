#!/bin/zsh -f

# Operator entry point for a complete MihomoBox release. This wrapper is the
# only layer that may invoke validation (and therefore compilation), the
# prebuilt-App release pipeline, and the GitHub draft-release helper in one
# run. Publication always requires an exact version-and-commit confirmation.

emulate -LR zsh
unsetopt XTRACE VERBOSE
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077

unset BASH_ENV ENV SHELLOPTS BASHOPTS PS4 CDPATH MINISIGN_PASSWORD
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_ATTR_NOSYSTEM
unset GIT_CEILING_DIRECTORIES GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_NAMESPACE
unset GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS
unset CODESIGN_ALLOCATE DEVELOPER_DIR TOOLCHAINS
unset PERL5OPT PERL5LIB PYTHONPATH PYTHONHOME RUBYOPT NODE_OPTIONS LD_PRELOAD
unset GH_DEBUG GH_HOST GH_REPO MIHOMOBOX_GITHUB_REPOSITORY
unset CODESIGN_IDENTITY_FINGERPRINT RELEASE_STATE_DIR RELEASE_LOCK_DIR
unset LEGACY_MINISIGN LEGACY_UPDATER_PRIVATE_KEY_FILE
unset SPARKLE_DISTRIBUTION_ROOT SPARKLE_ED_KEY_PATH
unset SPARKLE_GENERATE_APPCAST_SHA256 SPARKLE_SIGN_UPDATE_SHA256
unset SPARKLE_SIGNATURE_VERIFIER SPARKLE_SIGNATURE_VERIFIER_SHA256
unset RELEASE_ROOT LEGACY_UPDATER_SMOKE_ARCHIVE LEGACY_UPDATER_SMOKE_SIGNATURE
unset PUBLISHED_080_ARCHIVE PUBLISHED_080_SIGNATURE
for inherited_name in ${(k)parameters}; do
  case "$inherited_name" in
    BASH_FUNC_*|DYLD_*|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*)
      unset "$inherited_name"
      ;;
  esac
done
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL="C"

# GitHub credentials are intentionally unavailable to validation and the
# signing/notarization pipeline. Restore them only for the GitHub helper.
# Normalize either supported GitHub CLI token variable into GH_TOKEN before
# the helper starts, so no lower-precedence token variable survives into its
# standalone authentication boundary.
typeset SAVED_GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
typeset +x SAVED_GH_TOKEN
unset GH_TOKEN GITHUB_TOKEN

# Likewise, keep notarization credentials out of Git, validation, and GitHub
# helper subprocesses. They are restored only immediately before release-macos.
typeset SAVED_NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
typeset SAVED_NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
typeset SAVED_NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
typeset +x SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD

readonly EXPECTED_RELEASE_ENV_SHA256="3d25c562efdb5f720c044aee0a82611b64015e077cad10c6eadd2dac6a4a3b40"
readonly PROGRAM_NAME="${0:t}"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

usage() {
  print -u2 -- \
    "usage: $PROGRAM_NAME fresh|resume|publish [--notes FILE] [--publish --confirm vX.Y.Z@FULL_SHA]"
  print -u2 -- \
    "       $PROGRAM_NAME publish --confirm vX.Y.Z@FULL_SHA"
  exit 2
}

(( $# >= 1 )) || usage
readonly MODE="$1"
shift
case "$MODE" in
  fresh|resume|publish) ;;
  *) usage ;;
esac

typeset NOTES=""
typeset NOTES_SEEN=0
typeset PUBLISH_REQUESTED=0
typeset CONFIRMATION=""
typeset CONFIRMATION_SEEN=0
while (( $# > 0 )); do
  case "$1" in
    --notes)
      (( $# >= 2 )) || usage
      (( NOTES_SEEN == 0 )) || fail "--notes may be supplied only once"
      NOTES_SEEN=1
      NOTES="$2"
      [[ -n "$NOTES" ]] || fail "--notes requires a non-empty file path"
      shift 2
      ;;
    --publish)
      (( PUBLISH_REQUESTED == 0 )) || fail "--publish may be supplied only once"
      PUBLISH_REQUESTED=1
      shift
      ;;
    --confirm)
      (( $# >= 2 )) || usage
      (( CONFIRMATION_SEEN == 0 )) || fail "--confirm may be supplied only once"
      CONFIRMATION_SEEN=1
      CONFIRMATION="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

if [[ "$MODE" == "publish" ]]; then
  PUBLISH_REQUESTED=1
  [[ -z "$NOTES" ]] || fail "publish mode does not prepare or change release notes"
  [[ -n "$CONFIRMATION" ]] || fail "publish mode requires --confirm"
elif (( PUBLISH_REQUESTED )); then
  [[ -n "$CONFIRMATION" ]] || fail "--publish requires --confirm"
elif [[ -n "$CONFIRMATION" ]]; then
  fail "--confirm is valid only with --publish or publish mode"
fi

readonly SCRIPT_PATH="${0:A}"
readonly ROOT="${SCRIPT_PATH:h:h}"
readonly VALIDATE_SCRIPT="$ROOT/scripts/validate.sh"
readonly RELEASE_SCRIPT="$ROOT/scripts/release-macos.sh"
readonly GITHUB_SCRIPT="$ROOT/scripts/release-github.zsh"
readonly RELEASE_ENV="$ROOT/build/release-inputs/release-0.8.0.env"
readonly DIST_ROOT="$ROOT/dist"
readonly STATE_ROOT="$DIST_ROOT/.release-state"
readonly PRODUCT_LOCK="$STATE_ROOT/release-product.lock"

[[ -f "$ROOT/VERSION" && ! -L "$ROOT/VERSION" ]] ||
  fail "VERSION is missing or unsafe"
[[ -f "$VALIDATE_SCRIPT" && ! -L "$VALIDATE_SCRIPT" ]] ||
  fail "validation entry point is missing or unsafe"
[[ -f "$RELEASE_SCRIPT" && ! -L "$RELEASE_SCRIPT" ]] ||
  fail "release entry point is missing or unsafe"
[[ -f "$GITHUB_SCRIPT" && ! -L "$GITHUB_SCRIPT" ]] ||
  fail "GitHub release helper is missing or unsafe"

readonly VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] ||
  fail "VERSION must contain one strict semantic version"

typeset EXPECTED_COMMIT=""
typeset EXPECTED_BRANCH=""

repository_status() {
  local tracked_status
  local untracked_status

  # Never hide a tracked modification merely because it is below build/ or
  # dist/. Only generated, untracked content in those two directories is
  # outside the release-source cleanliness boundary.
  tracked_status="$(
    /usr/bin/git -C "$ROOT" status --porcelain=v1 --untracked-files=no
  )" || return 1
  untracked_status="$(
    /usr/bin/git -C "$ROOT" ls-files --others --exclude-standard -- . \
      ':(exclude)build' ':(exclude)dist'
  )" || return 1
  print -r -- "$tracked_status"
  print -r -- "$untracked_status"
}

verify_repository_snapshot() {
  local expected_commit="$1"
  local expected_version="$2"
  local actual_commit
  local actual_version
  local branch
  local clean_status
  local upstream_commit

  branch="$(/usr/bin/git -C "$ROOT" symbolic-ref --quiet HEAD)" ||
    fail "release requires a non-detached branch"
  actual_commit="$(/usr/bin/git -C "$ROOT" rev-parse --verify 'HEAD^{commit}')" ||
    fail "could not resolve HEAD"
  [[ "$actual_commit" =~ '^[0-9a-f]{40}$' ]] ||
    fail "HEAD is not one full SHA-1 commit"
  upstream_commit="$(/usr/bin/git -C "$ROOT" rev-parse --verify '@{upstream}^{commit}')" ||
    fail "release branch has no upstream"
  [[ "$upstream_commit" == "$actual_commit" ]] ||
    fail "release branch upstream does not equal HEAD"
  clean_status="$(repository_status)" ||
    fail "could not inspect the release worktree"
  [[ -z "$clean_status" ]] ||
    fail "release worktree is not clean"
  actual_version="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
  [[ "$actual_version" == "$expected_version" ]] ||
    fail "VERSION changed during the release workflow"
  if [[ -n "$expected_commit" && "$actual_commit" != "$expected_commit" ]]; then
    fail "HEAD changed during the release workflow"
  fi
  if [[ -n "$EXPECTED_BRANCH" && "$branch" != "$EXPECTED_BRANCH" ]]; then
    fail "release branch changed during the release workflow"
  fi

  REPLY="$actual_commit"
  reply=("$branch")
}

verify_repository_snapshot "" "$VERSION"
EXPECTED_COMMIT="$REPLY"
EXPECTED_BRANCH="${reply[1]}"
readonly EXPECTED_COMMIT EXPECTED_BRANCH
readonly EXPECTED_CONFIRMATION="v$VERSION@$EXPECTED_COMMIT"
if (( PUBLISH_REQUESTED )); then
  [[ "$CONFIRMATION" == "$EXPECTED_CONFIRMATION" ]] ||
    fail "publication confirmation must be exactly $EXPECTED_CONFIRMATION"
fi

readonly STATE_DIR="$STATE_ROOT/$VERSION-$EXPECTED_COMMIT"
readonly SIGNED_APP_STATE="$STATE_DIR/MihomoBox-$VERSION-signed-app.json"
readonly RELEASE_ASSETS_STATE="$STATE_DIR/release-assets.tsv"
readonly LOG_ROOT="$STATE_ROOT/logs"
readonly LOG_DIR="$LOG_ROOT/$VERSION-$EXPECTED_COMMIT"
readonly BUILD_MANIFEST="$ROOT/build/MihomoBox.app/Contents/Resources/BuildManifest.plist"

if [[ -n "$NOTES" ]]; then
  [[ -f "$NOTES" && ! -L "$NOTES" ]] ||
    fail "release notes must be a regular, non-symlink file"
  NOTES="${NOTES:A}"
fi

typeset PRODUCT_LOCK_TOKEN=""
typeset +x PRODUCT_LOCK_TOKEN
typeset PRODUCT_LOCK_OWNED=0
typeset CLEANUP_RUNNING=0

release_product_lock() {
  local recorded_token=""
  (( PRODUCT_LOCK_OWNED )) || return 0
  if [[ -d "$PRODUCT_LOCK" && ! -L "$PRODUCT_LOCK" ]]; then
    if [[ -f "$PRODUCT_LOCK/token" && ! -L "$PRODUCT_LOCK/token" ]]; then
      recorded_token="$(/bin/cat "$PRODUCT_LOCK/token" 2>/dev/null || true)"
      if [[ "$recorded_token" == "$PRODUCT_LOCK_TOKEN" ]]; then
        /bin/rm -rf -- "$PRODUCT_LOCK"
      fi
    fi
  fi
  PRODUCT_LOCK_OWNED=0
}

cleanup() {
  (( CLEANUP_RUNNING == 0 )) || return 0
  CLEANUP_RUNNING=1
  unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
  unset SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
  unset GH_TOKEN GITHUB_TOKEN SAVED_GH_TOKEN
  release_product_lock
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_product_lock() {
  local owner_pid="unknown"
  local owner_host="unknown"
  local owner_started="unknown"

  for directory in "$DIST_ROOT" "$STATE_ROOT"; do
    [[ ! -L "$directory" ]] || fail "release directory is a symlink: $directory"
    if [[ -e "$directory" && ! -d "$directory" ]]; then
      fail "release directory path is unsafe: $directory"
    fi
  done
  /bin/mkdir -p "$STATE_ROOT"
  /bin/chmod 0700 "$STATE_ROOT"

  if ! /bin/mkdir "$PRODUCT_LOCK" 2>/dev/null; then
    if [[ -L "$PRODUCT_LOCK" || ! -d "$PRODUCT_LOCK" ]]; then
      fail "release-product lock path is unsafe: $PRODUCT_LOCK"
    fi
    owner_pid="$(/bin/cat "$PRODUCT_LOCK/pid" 2>/dev/null || true)"
    owner_host="$(/bin/cat "$PRODUCT_LOCK/host" 2>/dev/null || true)"
    owner_started="$(/bin/cat "$PRODUCT_LOCK/started_at" 2>/dev/null || true)"
    print -u2 -- \
      "release-product lock already exists owner_pid=${owner_pid:-unknown} owner_host=${owner_host:-unknown} started_at=${owner_started:-unknown}"
    if [[ "$owner_host" == "$(/bin/hostname)" && "$owner_pid" =~ '^[0-9]+$' ]] &&
      /bin/kill -0 "$owner_pid" 2>/dev/null; then
      print -u2 -- "the owning release-product process is still running"
    else
      print -u2 -- \
        "the lock appears stale; inspect it and remove only $PRODUCT_LOCK before retrying"
    fi
    exit 1
  fi

  PRODUCT_LOCK_TOKEN="$(/usr/bin/uuidgen)"
  /usr/bin/printf '%s\n' "$PRODUCT_LOCK_TOKEN" > "$PRODUCT_LOCK/token"
  /usr/bin/printf '%s\n' "$$" > "$PRODUCT_LOCK/pid"
  /bin/hostname > "$PRODUCT_LOCK/host"
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$PRODUCT_LOCK/started_at"
  /bin/chmod 0700 "$PRODUCT_LOCK"
  /bin/chmod 0600 "$PRODUCT_LOCK"/*
  # Cleanup is allowed only after the complete ownership record exists. An
  # interrupted initialization deliberately leaves a stale lock for manual
  # inspection; it must never delete a replacement directory without a token
  # match.
  PRODUCT_LOCK_OWNED=1
}

acquire_product_lock

if [[ -L "$STATE_DIR" || ( -e "$STATE_DIR" && ! -d "$STATE_DIR" ) ]]; then
  fail "version release state path is unsafe: $STATE_DIR"
fi
typeset RESUME_ASSETS_FROZEN=0
case "$MODE" in
  fresh)
    first_state_entry=""
    if [[ -d "$STATE_DIR" ]]; then
      first_state_entry="$(
        /usr/bin/find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit
      )" || fail "could not inspect the version release state"
    fi
    [[ -z "$first_state_entry" ]] ||
      fail "fresh requires an empty version state directory: $STATE_DIR"
    ;;
  resume)
    if [[ -L "$RELEASE_ASSETS_STATE" ||
      ( -e "$RELEASE_ASSETS_STATE" && ! -f "$RELEASE_ASSETS_STATE" ) ]]; then
      fail "release asset state path is unsafe: $RELEASE_ASSETS_STATE"
    elif [[ -f "$RELEASE_ASSETS_STATE" ]]; then
      RESUME_ASSETS_FROZEN=1
    else
      [[ -f "$SIGNED_APP_STATE" && ! -L "$SIGNED_APP_STATE" ]] ||
        fail "resume requires the signed App state: $SIGNED_APP_STATE"
    fi
    ;;
  publish)
    [[ -f "$RELEASE_ASSETS_STATE" && ! -L "$RELEASE_ASSETS_STATE" ]] ||
      fail "publish requires frozen release assets: $RELEASE_ASSETS_STATE"
    ;;
esac

for log_directory in "$LOG_ROOT" "$LOG_DIR"; do
  [[ ! -L "$log_directory" ]] ||
    fail "release log directory is a symlink: $log_directory"
  if [[ -e "$log_directory" && ! -d "$log_directory" ]]; then
    fail "release log directory path is unsafe: $log_directory"
  fi
done
/bin/mkdir -p "$LOG_DIR"
/bin/chmod 0700 "$LOG_ROOT" "$LOG_DIR"

run_logged() {
  local label="$1"
  shift
  local timestamp
  local log
  local command_status
  local tee_status
  local -a pipeline_status

  timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')" || return 1
  log="$(/usr/bin/mktemp "$LOG_DIR/$timestamp-$label.XXXXXX")" || return 1
  /bin/chmod 0600 "$log" || return 1
  print -- "phase=$label log=$log"

  set +e
  "$@" 2>&1 | /usr/bin/tee -a "$log"
  pipeline_status=("${pipestatus[@]}")
  set -e
  command_status="${pipeline_status[1]:-1}"
  tee_status="${pipeline_status[2]:-1}"
  print -- "${label}_exit=$command_status tee_exit=$tee_status log=$log"

  if (( tee_status != 0 )); then
    print -u2 -- "release log could not be written: $log"
    return 1
  fi
  return "$command_status"
}

run_validate() {
  local public_key_file="${SPARKLE_PUBLIC_ED_KEY_FILE:-}"
  [[ -n "${HOME:-}" && "$HOME" == /* ]] ||
    fail "HOME must be an absolute path for release validation"
  if [[ -z "$public_key_file" ]]; then
    public_key_file="$HOME/.config/mihomobox/sparkle-public-ed25519.b64"
  fi
  [[ -f "$public_key_file" && ! -L "$public_key_file" ]] ||
    fail "SPARKLE_PUBLIC_ED_KEY_FILE is missing or unsafe: $public_key_file"

  if ! run_logged validate \
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="${USER:-}" \
      LOGNAME="${LOGNAME:-${USER:-}}" \
      PATH="$PATH" \
      LC_ALL="$LC_ALL" \
      SWIFT_BUILD_ARCH="arm64" \
      MIHOMO_BUILD_VERSION="$VERSION" \
      SPARKLE_PUBLIC_ED_KEY_FILE="$public_key_file" \
      /bin/bash "$VALIDATE_SCRIPT"; then
    fail "validation failed"
  fi
}

verify_validated_app() {
  [[ -f "$BUILD_MANIFEST" && ! -L "$BUILD_MANIFEST" ]] ||
    fail "validated App BuildManifest is missing or unsafe"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$BUILD_MANIFEST")" == \
    "$VERSION" ]] || fail "validated App version does not match VERSION"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceCommit' "$BUILD_MANIFEST")" == \
    "$EXPECTED_COMMIT" ]] || fail "validated App source commit does not match HEAD"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SourceDirty' "$BUILD_MANIFEST")" == \
    "false" ]] || fail "validated App source was dirty"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :DevelopmentUpdatesDisabled' \
    "$BUILD_MANIFEST")" == "false" ]] ||
    fail "validated App has development updates disabled"
}

load_release_environment() {
  typeset -A allowed_release_variables=(
    CODESIGN_IDENTITY_FINGERPRINT 1
    RELEASE_STATE_DIR 1
    LEGACY_MINISIGN 1
    LEGACY_UPDATER_PRIVATE_KEY_FILE 1
    SPARKLE_DISTRIBUTION_ROOT 1
    SPARKLE_ED_KEY_PATH 1
    SPARKLE_GENERATE_APPCAST_SHA256 1
    SPARKLE_SIGN_UPDATE_SHA256 1
    SPARKLE_SIGNATURE_VERIFIER 1
    SPARKLE_SIGNATURE_VERIFIER_SHA256 1
  )
  typeset -A loaded_release_variables=()
  local environment_line
  local assignment
  local variable_name
  local quoted_value
  local variable_value
  local required_name
  local current_uid
  local key_file
  local key_name
  local key_mode
  local key_owner

  [[ -f "$RELEASE_ENV" && ! -L "$RELEASE_ENV" ]] ||
    fail "release input environment is missing or unsafe: $RELEASE_ENV"
  [[ "$(/usr/bin/shasum -a 256 "$RELEASE_ENV" | /usr/bin/awk '{print $1}')" == \
    "$EXPECTED_RELEASE_ENV_SHA256" ]] ||
    fail "release input environment checksum changed"

  unset CODESIGN_IDENTITY_FINGERPRINT RELEASE_STATE_DIR
  unset LEGACY_MINISIGN LEGACY_UPDATER_PRIVATE_KEY_FILE
  unset SPARKLE_DISTRIBUTION_ROOT SPARKLE_ED_KEY_PATH
  unset SPARKLE_GENERATE_APPCAST_SHA256 SPARKLE_SIGN_UPDATE_SHA256
  unset SPARKLE_SIGNATURE_VERIFIER SPARKLE_SIGNATURE_VERIFIER_SHA256

  while IFS= read -r environment_line || [[ -n "$environment_line" ]]; do
    [[ -z "$environment_line" || "$environment_line" == \#* ]] && continue
    [[ "$environment_line" == "export "* ]] ||
      fail "unsupported release environment line"
    assignment="${environment_line#export }"
    variable_name="${assignment%%=*}"
    quoted_value="${assignment#*=}"
    [[ "$variable_name" =~ '^[A-Z][A-Z0-9_]*$' ]] ||
      fail "release environment variable name is invalid"
    [[ -n "${allowed_release_variables[$variable_name]:-}" ]] ||
      fail "release environment contains an unexpected variable: $variable_name"
    [[ -z "${loaded_release_variables[$variable_name]:-}" ]] ||
      fail "release environment repeats variable: $variable_name"
    [[ "${quoted_value[1]:-}" == "'" && "${quoted_value[-1]:-}" == "'" ]] ||
      fail "release environment value is not one simple single-quoted string"
    variable_value="${quoted_value[2,-2]}"
    [[ "$variable_value" != *"'"* && "$variable_value" != *$'\r'* ]] ||
      fail "release environment value contains an unsupported character"
    loaded_release_variables[$variable_name]=1

    # These values are bound by the current repository and invocation. Never
    # reuse the old wrapper's state location or signing fingerprint.
    if [[ "$variable_name" != "RELEASE_STATE_DIR" &&
      "$variable_name" != "CODESIGN_IDENTITY_FINGERPRINT" ]]; then
      typeset -gx "$variable_name=$variable_value"
    fi
  done < "$RELEASE_ENV"

  for required_name in \
    LEGACY_MINISIGN \
    LEGACY_UPDATER_PRIVATE_KEY_FILE \
    SPARKLE_DISTRIBUTION_ROOT \
    SPARKLE_ED_KEY_PATH \
    SPARKLE_GENERATE_APPCAST_SHA256 \
    SPARKLE_SIGN_UPDATE_SHA256 \
    SPARKLE_SIGNATURE_VERIFIER \
    SPARKLE_SIGNATURE_VERIFIER_SHA256; do
    [[ -n "${(P)required_name:-}" ]] ||
      fail "$required_name is missing from $RELEASE_ENV"
  done

  current_uid="$(/usr/bin/id -u)" || fail "could not determine the operator uid"
  for key_name in LEGACY_UPDATER_PRIVATE_KEY_FILE SPARKLE_ED_KEY_PATH; do
    key_file="${(P)key_name}"
    [[ -f "$key_file" && ! -L "$key_file" ]] ||
      fail "$key_name must be a regular, non-symlink file"
    key_owner="$(/usr/bin/stat -f '%u' "$key_file")" ||
      fail "could not inspect $key_name ownership"
    [[ "$key_owner" == "$current_uid" ]] ||
      fail "$key_name must be owned by the current operator"
    key_mode="$(/usr/bin/stat -f '%Lp' "$key_file")" ||
      fail "could not inspect $key_name permissions"
    [[ "$key_mode" == "400" || "$key_mode" == "600" ]] ||
      fail "$key_name permissions must be 0400 or 0600"
  done

  unset CODESIGN_IDENTITY_FINGERPRINT
  export RELEASE_STATE_DIR="$STATE_DIR"
  export RELEASE_LOCK_DIR="$STATE_ROOT/release.lock"
}

load_notary_credentials() {
  if [[ -n "$SAVED_NOTARY_TEAM_ID" ]]; then
    NOTARY_TEAM_ID="$SAVED_NOTARY_TEAM_ID"
  fi
  if [[ -n "$SAVED_NOTARY_APPLE_ID" ]]; then
    NOTARY_APPLE_ID="$SAVED_NOTARY_APPLE_ID"
  fi
  if [[ -n "$SAVED_NOTARY_PASSWORD" ]]; then
    NOTARY_PASSWORD="$SAVED_NOTARY_PASSWORD"
  fi

  if [[ -z "${NOTARY_TEAM_ID:-}" ]]; then
    [[ -t 0 && -t 1 ]] ||
      fail "NOTARY_TEAM_ID is empty and no interactive terminal is available"
    read -r "NOTARY_TEAM_ID?Apple Developer Team ID: "
  fi
  if [[ -z "${NOTARY_APPLE_ID:-}" ]]; then
    [[ -t 0 && -t 1 ]] ||
      fail "NOTARY_APPLE_ID is empty and no interactive terminal is available"
    read -r "NOTARY_APPLE_ID?Apple ID email: "
  fi
  if [[ -z "${NOTARY_PASSWORD:-}" ]]; then
    [[ -t 0 && -t 1 ]] ||
      fail "NOTARY_PASSWORD is empty and no interactive terminal is available"
    read -r -s \
      "NOTARY_PASSWORD?Apple app-specific password (not the Mac login password): "
    print
  fi

  [[ "$NOTARY_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] ||
    fail "NOTARY_TEAM_ID must be one 10-character Apple Team ID"
  [[ -n "$NOTARY_APPLE_ID" && "$NOTARY_APPLE_ID" != *$'\r'* &&
    "$NOTARY_APPLE_ID" != *$'\n'* ]] || fail "NOTARY_APPLE_ID is invalid"
  [[ -n "$NOTARY_PASSWORD" && "$NOTARY_PASSWORD" != *$'\r'* &&
    "$NOTARY_PASSWORD" != *$'\n'* ]] || fail "NOTARY_PASSWORD is invalid"
  export NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
}

clear_release_environment() {
  unset CODESIGN_IDENTITY_FINGERPRINT RELEASE_STATE_DIR RELEASE_LOCK_DIR
  unset LEGACY_MINISIGN LEGACY_UPDATER_PRIVATE_KEY_FILE
  unset SPARKLE_DISTRIBUTION_ROOT SPARKLE_ED_KEY_PATH
  unset SPARKLE_GENERATE_APPCAST_SHA256 SPARKLE_SIGN_UPDATE_SHA256
  unset SPARKLE_SIGNATURE_VERIFIER SPARKLE_SIGNATURE_VERIFIER_SHA256
  unset RELEASE_ROOT LEGACY_UPDATER_SMOKE_ARCHIVE LEGACY_UPDATER_SMOKE_SIGNATURE
  unset PUBLISHED_080_ARCHIVE PUBLISHED_080_SIGNATURE
  unset SPARKLE_PUBLIC_ED_KEY_FILE
}

run_release() {
  local -a release_arguments=()
  load_release_environment
  load_notary_credentials
  if [[ "$MODE" == "resume" ]]; then
    release_arguments+=(--resume)
  fi
  if ! run_logged release /bin/bash "$RELEASE_SCRIPT" "${release_arguments[@]}"; then
    fail "release packaging, signing, or notarization failed"
  fi
  unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
  unset SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
  clear_release_environment
}

restore_github_credentials() {
  if [[ -n "$SAVED_GH_TOKEN" ]]; then
    export GH_TOKEN="$SAVED_GH_TOKEN"
  fi
}

run_github_prepare() {
  local -a arguments=(prepare --state-dir "$STATE_DIR")
  if [[ -n "$NOTES" ]]; then
    arguments+=(--notes "$NOTES")
  fi
  unset GH_TOKEN GITHUB_TOKEN
  verify_repository_snapshot "$EXPECTED_COMMIT" "$VERSION"
  unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
  unset SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
  restore_github_credentials
  if ! run_logged github-prepare /bin/zsh -f "$GITHUB_SCRIPT" "${arguments[@]}"; then
    fail "GitHub draft preparation or asset upload failed"
  fi
  unset GH_TOKEN GITHUB_TOKEN
}

run_github_publish() {
  unset GH_TOKEN GITHUB_TOKEN
  verify_repository_snapshot "$EXPECTED_COMMIT" "$VERSION"
  unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD
  unset SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD
  restore_github_credentials
  if ! run_logged github-publish /bin/zsh -f "$GITHUB_SCRIPT" publish \
    --state-dir "$STATE_DIR" --confirm "$CONFIRMATION"; then
    fail "GitHub release publication failed"
  fi
  unset GH_TOKEN GITHUB_TOKEN
}

cd "$ROOT"

case "$MODE" in
  fresh)
    run_validate
    verify_repository_snapshot "$EXPECTED_COMMIT" "$VERSION"
    verify_validated_app
    run_release
    run_github_prepare
    ;;
  resume)
    if (( RESUME_ASSETS_FROZEN )); then
      print -- "release assets are frozen; skipping validation and release-macos"
    else
      run_release
    fi
    verify_repository_snapshot "$EXPECTED_COMMIT" "$VERSION"
    run_github_prepare
    ;;
  publish)
    verify_repository_snapshot "$EXPECTED_COMMIT" "$VERSION"
    run_github_publish
    ;;
esac

if [[ "$MODE" != "publish" ]] && (( PUBLISH_REQUESTED )); then
  run_github_publish
fi

print -- "release_mode=$MODE"
print -- "release_version=$VERSION"
print -- "release_commit=$EXPECTED_COMMIT"
print -- "release_state=$STATE_DIR"
if [[ "$MODE" == "publish" || PUBLISH_REQUESTED -eq 1 ]]; then
  print -- "release_result=published"
else
  print -- "release_result=draft_uploaded"
fi
