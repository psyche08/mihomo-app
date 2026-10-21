#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d /private/tmp/mihomobox-rollback-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export TEST_TMP
load_function() {
  eval "$(/usr/bin/awk -v name="$1" '$0 == name "() {" {copy=1} copy {print} copy && /^\}$/ {exit}' "$ROOT/scripts/install-daemon.sh")"
}
for name in rollback_installation rollback_profile_switch resume_previous_installation_after_preflight_failure restore_previous_installation_snapshot managed_runtime_dns_ready; do
  load_function "$name"
done

# Even if a rollback source vanishes, do not stop or delete live state.
validate_rollback_snapshot() { return 1; }
stop_replacement_installation() { touch "$TEST_TMP/stop-called"; }
APP_SUPPORT="$TEST_TMP/live-support"
mkdir "$APP_SUPPORT"
touch "$APP_SUPPORT/preserved"
if restore_previous_installation_snapshot; then exit 1; fi
test -f "$APP_SUPPORT/preserved"
test ! -e "$TEST_TMP/stop-called"

# A command substitution inherits ERR under macOS Bash 3.2 even when used in
# an if condition. The inherited handler must not mutate or clean snapshots.
restore_previous_installation_snapshot() { echo restore >> "$TEST_TMP/events"; }
restart_previous_installation() { echo restart >> "$TEST_TMP/events"; }
remove_rollback_snapshot() { echo cleanup >> "$TEST_TMP/events"; }
report_recovery_required() { echo recovery >> "$TEST_TMP/events"; }
export -f rollback_installation rollback_profile_switch resume_previous_installation_after_preflight_failure
export -f restore_previous_installation_snapshot restart_previous_installation remove_rollback_snapshot report_recovery_required
for handler in rollback_installation rollback_profile_switch resume_previous_installation_after_preflight_failure; do
  /bin/bash -c 'set -Eeuo pipefail; trap "$1" ERR; if [[ "$(false)" == true ]]; then exit 2; fi' _ "$handler"
  test ! -e "$TEST_TMP/events"
done

# A failure in the actual installer process still runs exactly one recovery.
status=0
/bin/bash -c 'set -Eeuo pipefail; trap rollback_installation ERR; false' || status=$?
test "$status" -eq 1
test "$(cat "$TEST_TMP/events")" = $'restore\ncleanup'
rm "$TEST_TMP/events"

# Missing optional DNS mode flags are normal, not a rollback trigger.
printf '%s\n' '{}' > "$TEST_TMP/daemon.json"
APP_SUPPORT="$TEST_TMP"
LOCAL_DOH_CERT="$TEST_TMP/absent.crt"
LOCAL_DOH_KEY="$TEST_TMP/absent.key"
managed_agent_standby_ready() { return 0; }
export APP_SUPPORT LOCAL_DOH_CERT LOCAL_DOH_KEY
export -f managed_runtime_dns_ready managed_agent_standby_ready
/bin/bash -c 'set -Eeuo pipefail; trap rollback_installation ERR; managed_runtime_dns_ready'
test ! -e "$TEST_TMP/events"

# An exited core leaves a Unix socket behind. Remove only that socket before
# copying the stopped installation; never follow a symlink or remove real data.
load_function remove_stopped_dns_socket
APP_SUPPORT="$TEST_TMP/socket-support"
mkdir -p "$APP_SUPPORT/mihomo-data/.dns-ipc"
socket="$APP_SUPPORT/mihomo-data/.dns-ipc/mihomo.sock"
python3 - "$socket" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
PY
remove_stopped_dns_socket
test ! -e "$socket"
printf 'preserve\n' > "$socket"
if remove_stopped_dns_socket 2>/dev/null; then exit 1; fi
test "$(cat "$socket")" = preserve
rm "$socket"
ln -s "$TEST_TMP/live-support/preserved" "$socket"
if remove_stopped_dns_socket 2>/dev/null; then exit 1; fi
test -L "$socket"
test -f "$TEST_TMP/live-support/preserved"
rm "$socket"
rmdir "$APP_SUPPORT/mihomo-data/.dns-ipc"
ln -s "$TEST_TMP/live-support" "$APP_SUPPORT/mihomo-data/.dns-ipc"
if remove_stopped_dns_socket 2>/dev/null; then exit 1; fi
test -L "$APP_SUPPORT/mihomo-data/.dns-ipc"
echo "installer rollback isolation tests passed"
