#!/usr/bin/env bash
set -euo pipefail

# zsh hides a top-level EXIT trap while a function runs, so ERR_EXIT raised in
# a function exits without cleanup. The zsh release scripts therefore release
# their locks and temporary files from a shared ZERR hook too. These tests run
# the scripts' own functions through that failure, and run the hook through the
# shapes that must not release early: handled failures, ERR_EXIT turned off and
# failures inside subshells.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(/usr/bin/mktemp -d /private/tmp/mihomobox-zsh-cleanup-tests.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

GITHUB_HELPER="$ROOT/scripts/release-github.zsh"
PRODUCT_HELPER="$ROOT/scripts/release-product.zsh"
CLOUD_HELPER="$ROOT/scripts/prepare-cloud-release.zsh"

fail() {
  echo "release zsh cleanup test: $*" >&2
  exit 1
}

extract_function() {
  local script="$1"
  local name="$2"
  local block

  block="$(/usr/bin/awk -v header="$name() {" '
    $0 == header { found = 1 }
    found { print }
    found && $0 == "}" { exit }
  ' "$script")"
  [[ -n "$block" ]] || fail "${script##*/} does not define $name"
  printf '%s\n' "$block"
}

HOOK=''
for script in "$GITHUB_HELPER" "$PRODUCT_HELPER" "$CLOUD_HELPER"; do
  block="$(extract_function "$script" TRAPZERR)"
  [[ -z "$HOOK" || "$block" == "$HOOK" ]] ||
    fail "${script##*/} has a different TRAPZERR hook"
  HOOK="$block"
  extract_function "$script" release_owned_resources >/dev/null
done
/usr/bin/grep -Fxq 'trap cleanup EXIT' "$GITHUB_HELPER" ||
  fail 'release-github.zsh must run cleanup on EXIT'
/usr/bin/grep -Fxq 'trap release_owned_resources EXIT' "$PRODUCT_HELPER" ||
  fail 'release-product.zsh must release owned resources on EXIT'
/usr/bin/grep -Fxq 'trap release_owned_resources EXIT' "$CLOUD_HELPER" ||
  fail 'prepare-cloud-release.zsh must release owned resources on EXIT'

# Runs a generated zsh script and requires its exit status.
run_zsh() {
  local name="$1"
  local expected_status="$2"
  local script_path="$TEST_TMP/$name.zsh"
  local status

  /bin/cat >"$script_path"
  set +e
  CASE_DIR="$TEST_TMP/$name" /bin/zsh -f "$script_path" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "$expected_status" ]] ||
    fail "$name exited $status, expected $expected_status"
}

# The real release-github functions, failing inside a function after the lock
# is taken, as a failed `git ls-remote` did.
github_lock_case() {
  local name="$1"
  local recorded_token="$2"
  local case_dir="$TEST_TMP/$name"

  /bin/mkdir -p "$case_dir/state" "$case_dir/lock"
  : >"$case_dir/state/.tag-rows.fixture"
  /usr/bin/printf '%s\n' "$recorded_token" >"$case_dir/lock/repository.lock"
  {
    /usr/bin/printf '%s\n' \
      'set -e' \
      'set -u' \
      'setopt PIPE_FAIL' \
      'STATE_DIR="$CASE_DIR/state"' \
      'LOCK_BASE="$CASE_DIR/lock"' \
      'LOCK_TOKEN_FILE="$LOCK_BASE/repository.lock"' \
      "LOCK_TOKEN='own-token'" \
      "LOCK_TOKEN_TEMP=''" \
      'typeset -a TEMP_FILES=("$STATE_DIR/.tag-rows.fixture")'
    extract_function "$GITHUB_HELPER" cleanup_release_lock
    extract_function "$GITHUB_HELPER" release_owned_resources
    extract_function "$GITHUB_HELPER" cleanup
    printf '%s\n' "$HOOK"
    /usr/bin/printf '%s\n' \
      'trap cleanup EXIT' \
      'inspect_remote() { (exit 128); print reached; }' \
      'inspect_remote'
  } | run_zsh "$name" 128
  [[ ! -e "$case_dir/state/.tag-rows.fixture" ]] ||
    fail "$name left a temporary state file"
}

github_lock_case github-owned-lock own-token
[[ ! -e "$TEST_TMP/github-owned-lock/lock/repository.lock" ]] ||
  fail 'release-github left its own lock after a failure inside a function'
github_lock_case github-foreign-lock other-token
[[ "$(/bin/cat "$TEST_TMP/github-foreign-lock/lock/repository.lock")" == other-token ]] ||
  fail 'release-github removed a lock owned by another release'

/bin/mkdir -p "$TEST_TMP/product/release-product.lock"
/usr/bin/printf '%s' own-token >"$TEST_TMP/product/release-product.lock/token"
{
  /usr/bin/printf '%s\n' \
    'setopt ERR_EXIT NO_UNSET PIPE_FAIL' \
    'PRODUCT_LOCK="$CASE_DIR/release-product.lock"' \
    "PRODUCT_LOCK_TOKEN='own-token'" \
    'PRODUCT_LOCK_OWNED=1' \
    'CLEANUP_RUNNING=0'
  extract_function "$PRODUCT_HELPER" release_product_lock
  extract_function "$PRODUCT_HELPER" release_owned_resources
  printf '%s\n' "$HOOK"
  /usr/bin/printf '%s\n' \
    'trap release_owned_resources EXIT' \
    'run_phase() { /usr/bin/false; print reached; }' \
    'run_phase'
} | run_zsh product 1
[[ ! -e "$TEST_TMP/product/release-product.lock" ]] ||
  fail 'release-product left its lock after a failure inside a function'

/bin/mkdir -p "$TEST_TMP/cloud/stage"
{
  /usr/bin/printf '%s\n' \
    'set -e' \
    'setopt PIPE_FAIL' \
    'STAGE="$CASE_DIR/stage"'
  extract_function "$CLOUD_HELPER" release_owned_resources
  printf '%s\n' "$HOOK"
  /usr/bin/printf '%s\n' \
    'trap release_owned_resources EXIT' \
    'check_stage() { /usr/bin/false; print reached; }' \
    'check_stage'
} | run_zsh cloud 1
[[ ! -e "$TEST_TMP/cloud/stage" ]] ||
  fail 'prepare-cloud-release left its stage after a failure inside a function'

# The hook with a recording release: it must release on every exit-causing
# failure, keep the exit status, and never release while the script continues
# or from a subshell.
hook_case() {
  local name="$1"
  local expected_status="$2"
  local body="$3"

  /bin/mkdir -p "$TEST_TMP/$name"
  {
    /usr/bin/printf '%s\n' \
      'set -e' \
      'setopt PIPE_FAIL' \
      'mark() { print -r -- "$1" >> "$CASE_DIR/events"; }' \
      'release_owned_resources() { mark "release subshell=$ZSH_SUBSHELL"; }'
    printf '%s\n' "$HOOK"
    /usr/bin/printf '%s\n' 'trap release_owned_resources EXIT' "$body"
  } | run_zsh "$name" "$expected_status"
}

# Requires the non-release events, then releases only after all of them and
# only from the main shell; zsh may or may not also run the EXIT trap after the
# hook.
require_events() {
  local name="$1"
  local expected="$2"
  local events="$TEST_TMP/$name/events"
  local actual

  [[ -f "$events" ]] || fail "$name recorded no events"
  /usr/bin/grep -q '^release subshell=0$' "$events" || fail "$name never released"
  if /usr/bin/grep '^release' "$events" | /usr/bin/grep -vq '^release subshell=0$'; then
    fail "$name released from a subshell"
  fi
  actual="$(/usr/bin/awk '!/^release/ { print }' "$events")"
  [[ "$actual" == "$expected" ]] || fail "$name recorded: $actual"
  if /usr/bin/awk '/^release/ { released = 1; next } released { early = 1 } END { exit !early }' \
    "$events"; then
    fail "$name released before its last step"
  fi
}

hook_case nested 7 'inner() { (exit 7); mark reached; }; outer() { inner; }; outer'
require_events nested ''
hook_case top-level 5 '(exit 5); mark reached'
require_events top-level ''
hook_case handled 0 "$(/usr/bin/printf '%s\n' \
  'step() { mark entered; /usr/bin/false; }' \
  'step || mark handled' \
  'if step; then mark then; else mark else; fi' \
  'mark done')"
require_events handled "$(/usr/bin/printf '%s\n' entered handled entered else done)"
hook_case errexit-off 0 "$(/usr/bin/printf '%s\n' \
  'step() { set +e; /usr/bin/false; mark "status=$?"; set -e; }' \
  'step' \
  'mark done')"
require_events errexit-off "$(/usr/bin/printf '%s\n' status=1 done)"
hook_case command-substitution 1 \
  'step() { local value; value="$(/usr/bin/false; print text)"; mark reached; }; step'
require_events command-substitution ''
hook_case subshell 1 'step() { ( /usr/bin/false; mark subshell-reached ); mark reached; }; step'
require_events subshell ''
hook_case pipeline 1 'step() { /usr/bin/false | /bin/cat; mark reached; }; step'
require_events pipeline ''
hook_case explicit-exit 3 'stop() { exit 3; }; step() { stop; mark reached; }; step'
require_events explicit-exit ''

echo "release zsh cleanup tests passed"
