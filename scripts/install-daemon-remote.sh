#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
  echo "do not run install-daemon-remote.sh with sudo or as root" >&2
  echo "run it as the SSH user from a trusted, signature-verified MihomoBox.app" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI="$APP_BUNDLE/Contents/MacOS/mihomoboxctl"

if [[ "$APP_BUNDLE" != *.app || -L "$APP_BUNDLE" ||
  ! -f "$CLI" || -L "$CLI" || ! -x "$CLI" ]]; then
  echo "invalid MihomoBox App bundle or missing signed CLI" >&2
  exit 1
fi

# This wrapper is deliberately unprivileged. Its trusted-source boundary is the
# complete App delivered through the operator's authenticated channel. The
# signed CLI derives the exact certificate/designated requirements and gives
# sudo only a fixed system-tool bootstrap; this shell resource is never run by
# root.
if ! /usr/bin/codesign --verify --deep --strict --all-architectures "$APP_BUNDLE" ||
  ! /usr/sbin/spctl --assess --type execute "$APP_BUNDLE"; then
  echo "MihomoBox App signature or Gatekeeper assessment failed" >&2
  exit 1
fi

exec "$CLI" install --detached
