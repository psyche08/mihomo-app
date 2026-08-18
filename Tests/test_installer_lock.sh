#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-daemon.sh"
TEST_TMP="$(/usr/bin/mktemp -d /private/tmp/mihomobox-installer-lock-tests.XXXXXX)"

cleanup() {
  exec 9>&- 2>/dev/null || true
  /bin/rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

# This is an exact source-contract string, not shell interpolation.
# shellcheck disable=SC2016
/usr/bin/grep -Fq \
  'fd_identity="$(/usr/bin/stat -f '\''%d:%i:%u:%g:%Lp'\'' <&9)"' \
  "$INSTALLER"
if /usr/bin/grep -Eq '^[[:space:]]*fd_identity=.* /dev/fd/9' "$INSTALLER"; then
  echo "installer must fstat the opened lock descriptor instead of statting /dev/fd/9" >&2
  exit 1
fi

lock="$TEST_TMP/lock"
/usr/bin/touch "$lock"
/bin/chmod 0600 "$lock"
exec 9<>"$lock"

path_identity="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp' "$lock")"
fd_identity="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp' <&9)"
test "$path_identity" = "$fd_identity"

# Replacing the path after open must not make the original descriptor appear
# to reference the replacement.
/bin/mv "$lock" "$TEST_TMP/opened-lock"
/usr/bin/touch "$lock"
/bin/chmod 0600 "$lock"
replacement_identity="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp' "$lock")"
test "$replacement_identity" != "$fd_identity"
exec 9>&-

# The fd form used by the installer must retain the BSD lock in the parent
# shell, reject a competing process, and release it when the fd closes.
exec 9<>"$lock"
/usr/bin/lockf -s -t 0 9
competitor_status=0
/bin/bash -c 'exec 8<>"$1"; /usr/bin/lockf -s -t 0 8' _ "$lock" ||
  competitor_status=$?
if [[ "$competitor_status" -ne 75 ]]; then
  echo "a competing process acquired the privileged mutation lock" >&2
  exit 1
fi
exec 9>&-
/bin/bash -c 'exec 8<>"$1"; /usr/bin/lockf -s -t 0 8' _ "$lock"

echo "installer lock tests passed"
