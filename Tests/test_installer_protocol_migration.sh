#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Load only the decision function, never the privileged installer entrypoint.
eval "$(/usr/bin/awk '/^enforce_component_version_floor\(\) \{/ {copy=1} copy {print} copy && /^\}$/ {exit}' "$ROOT/scripts/install-daemon.sh")"

DRY_RUN=0
VERIFIED_APP_VERSION=0.9.4
APP_SUPPORT="$ROOT/Sources"
PLIST="$ROOT/Tests/nonexistent-protocol-test.plist"
RENAMED_PLIST="$PLIST"
validate_existing_component_version_floor() { return "$floor_result"; }
probe_installed_daemon_protocol() { return "$probe_result"; }

check() {
  local expected="$1" actual=0
  enforce_component_version_floor >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -ne "$expected" ]]; then
    echo "unexpected migration result: probe=$probe_result floor=$floor_result actual=$actual" >&2
    exit 1
  fi
}

# A validated, non-downgrading root floor permits the authenticated v2 peer.
# Stub the floor validator here; its ownership/version checks remain separate.
COMPONENT_VERSION="$ROOT/VERSION"
floor_result=0
for probe_result in 0 10 14 13; do check 0; done
for probe_result in 11 12; do check 1; done
floor_result=1
for probe_result in 0 10 14 13; do check 1; done

# Missing floor must not turn v2, current, unknown or future into v1 legacy.
COMPONENT_VERSION="$ROOT/Tests/nonexistent-component-version"
floor_result=0
for probe_result in 0 11 12 13 14; do check 1; done
probe_result=10
check 0
test "$UNVERSIONED_INSTALLATION_AUTHORIZED" -eq 1
echo "installer protocol migration tests passed"
