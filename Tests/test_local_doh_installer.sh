#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-daemon.sh"
STATUS_PROVIDER="$ROOT/Sources/MihomoDaemon/LocalDoHStatusProvider.swift"

/bin/bash -n "$INSTALLER"

relative_line() {
  local start="$1"
  local pattern="$2"
  /usr/bin/awk -v start="$start" -v pattern="$pattern" \
    'NR >= start && index($0, pattern) { print NR - start + 1; exit }' "$INSTALLER"
}

remove_start="$(/usr/bin/grep -n '^remove_local_doh() {' "$INSTALLER" | /usr/bin/cut -d: -f1)"
remove_profile="$(relative_line "$remove_start" 'remove_local_doh_profile_if_installed')"
remove_stop="$(relative_line "$remove_start" '/bin/launchctl bootout "system/$LABEL"')"
remove_trust="$(relative_line "$remove_start" 'remove_local_doh_trust')"

if ((remove_profile >= remove_stop || remove_stop >= remove_trust)); then
  echo "Local DoH removal must verify profile removal before stopping the server and deleting trust" >&2
  exit 1
fi

install_start="$(/usr/bin/grep -n '^install_local_doh() {' "$INSTALLER" | /usr/bin/cut -d: -f1)"
install_profile_check="$(relative_line "$install_start" 'validate_local_doh_profile_artifact')"
install_stop="$(relative_line "$install_start" '/bin/launchctl bootout "system/$LABEL"')"
if ((install_profile_check >= install_stop)); then
  echo "Local DoH must validate the fixed root-owned profile before stopping the daemon" >&2
  exit 1
fi

/usr/bin/grep -Fq 'trap rollback_local_doh_remove ERR' "$INSTALLER"
/usr/bin/grep -Fq 'recover_classic_dns_after_local_doh_failure' "$INSTALLER"
/usr/bin/grep -Fq 'Local DoH removal failed, but classic managed DNS was restored' "$INSTALLER"
/usr/bin/grep -Fq '/usr/bin/ditto "$LOCAL_DOH_DIR" "$LOCAL_DOH_ROLLBACK_DIR/local-doh"' "$INSTALLER"
/usr/bin/grep -Fq '/usr/bin/ditto "$LOCAL_DOH_ROLLBACK_DIR/local-doh" "$LOCAL_DOH_DIR"' "$INSTALLER"
/usr/bin/grep -Fq -- '-identifier "$LOCAL_DOH_PROFILE_IDENTIFIER" -output stdout-xml' "$INSTALLER"
/usr/bin/grep -Fq '"$(/usr/bin/stat -f '\''%u:%g:%Lp'\'' "$LOCAL_DOH_PROFILE")" == "0:0:644"' "$INSTALLER"
/usr/bin/grep -Fq '"$server_url" == "https://127.0.0.1:9443/dns-query"' "$INSTALLER"
/usr/bin/grep -Fq '/bin/rm -f "$LOCAL_DOH_PROFILE"' "$INSTALLER"
/usr/bin/grep -Fq '"-output", "stdout-xml"' "$STATUS_PROVIDER"
if /usr/bin/grep -Fq '"-output", "-"' "$STATUS_PROVIDER"; then
  echo "profile status inspection must not create a literal -.plist file" >&2
  exit 1
fi

restore_start="$(/usr/bin/grep -n '^restore() {' "$INSTALLER" | /usr/bin/cut -d: -f1)"
restore_profile="$(relative_line "$restore_start" 'remove_local_doh_profile_if_installed')"
restore_stop="$(relative_line "$restore_start" 'launchctl bootout')"
if ((restore_profile >= restore_stop)); then
  echo "uninstall must verify Local DoH profile removal before deleting its server identity" >&2
  exit 1
fi

echo "Local DoH installer safety tests passed"
