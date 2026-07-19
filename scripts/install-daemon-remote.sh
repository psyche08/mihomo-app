#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "install-daemon-remote.sh must run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$SCRIPT_DIR/install-daemon.sh"

if [[ "$APP_BUNDLE" != *.app || ! -x "$INSTALLER" ]]; then
  echo "invalid MihomoBox App bundle or missing installer" >&2
  exit 1
fi

RUN_DIR="$(/usr/bin/mktemp -d /private/tmp/mihomobox-install.XXXXXX)"
LOG_PATH="$RUN_DIR/install.log"
PID_PATH="$RUN_DIR/install.pid"

/usr/bin/nohup /bin/bash "$INSTALLER" --app-bundle "$APP_BUNDLE" \
  >"$LOG_PATH" 2>&1 </dev/null &
INSTALL_PID=$!
/bin/echo "$INSTALL_PID" >"$PID_PATH"

echo "MihomoBox daemon installation started"
echo "pid: $INSTALL_PID"
echo "log: $LOG_PATH"
