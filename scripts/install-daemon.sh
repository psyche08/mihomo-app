#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="/Library/Application Support/Mihomo App"
MIHOMO_DATA="$APP_SUPPORT/mihomo-data"
LOG_DIR="/Library/Logs/Mihomo App"
PLIST="/Library/LaunchDaemons/dev.linsheng.mihomo-app.daemon.plist"
LABEL="dev.linsheng.mihomo-app.daemon"
LEGACY_DIR="/opt/homebrew/etc/mihomo"
LEGACY_LABEL="homebrew.mxcl.mihomo"
LEGACY_MARKER="$APP_SUPPORT/homebrew-mihomo-was-running"
APP_BUNDLE=""
DRY_RUN=0
RESTORE=0
ROLLBACK_DIR=""
PREVIOUS_DAEMON_RUNNING=0
PREVIOUS_LEGACY_RUNNING=0

usage() {
  echo "usage: $0 [--app-bundle PATH] [--dry-run] [--restore]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle) APP_BUNDLE="${2:?missing app bundle path}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --restore) RESTORE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_root() {
  if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
    echo "install-daemon.sh must run as root" >&2
    exit 1
  fi
}

resolve_sources() {
  if [[ -n "$APP_BUNDLE" ]]; then
    DAEMON_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomo-daemon"
    MIHOMO_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomo"
    RESOURCE_ROOT="$APP_BUNDLE/Contents/Resources/daemon"
  else
    DAEMON_SOURCE="$ROOT/.build/release/mihomo-daemon"
    local triple
    triple="${TARGET_TRIPLE:-$(rustc -vV | /usr/bin/sed -n 's/^host: //p')}"
    MIHOMO_SOURCE="$ROOT/src-tauri/binaries/mihomo-$triple"
    RESOURCE_ROOT="$ROOT/deploy"
  fi
}

wait_for() {
  local description="$1"
  shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ wait for $description"
    return
  fi
  for _ in {1..80}; do
    if "$@" >/dev/null 2>&1; then return; fi
    /bin/sleep 0.25
  done
  echo "timed out waiting for $description" >&2
  return 1
}

snapshot_installation() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  ROLLBACK_DIR="$(/usr/bin/mktemp -d /private/tmp/mihomo-app-install.XXXXXX)"
  if [[ -d "$APP_SUPPORT" ]]; then
    /usr/bin/ditto "$APP_SUPPORT" "$ROLLBACK_DIR/app-support"
  fi
  if [[ -f "$PLIST" ]]; then
    /bin/cp -p "$PLIST" "$ROLLBACK_DIR/daemon.plist"
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    PREVIOUS_DAEMON_RUNNING=1
  fi
  if /bin/launchctl print "system/$LEGACY_LABEL" >/dev/null 2>&1; then
    PREVIOUS_LEGACY_RUNNING=1
  fi
}

rollback_installation() {
  local status=$?
  trap - ERR
  echo "installation failed; restoring the previous DNS runtime" >&2
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns \
      >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$APP_SUPPORT"
  /bin/rm -f "$PLIST"
  if [[ -d "$ROLLBACK_DIR/app-support" ]]; then
    /usr/bin/ditto "$ROLLBACK_DIR/app-support" "$APP_SUPPORT"
  fi
  if [[ -f "$ROLLBACK_DIR/daemon.plist" ]]; then
    /bin/cp -p "$ROLLBACK_DIR/daemon.plist" "$PLIST"
  fi
  if [[ "$PREVIOUS_DAEMON_RUNNING" -eq 1 && -f "$PLIST" ]]; then
    /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
    /bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
  elif [[ "$PREVIOUS_LEGACY_RUNNING" -eq 1 ]]; then
    /bin/launchctl kickstart -k "system/$LEGACY_LABEL" >/dev/null 2>&1 || true
  fi
  [[ -z "$ROLLBACK_DIR" ]] || /bin/rm -rf "$ROLLBACK_DIR"
  exit "$status"
}

restore() {
  require_root
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$LABEL"
  fi
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  if [[ -f "$LEGACY_MARKER" ]]; then
    run /bin/launchctl kickstart -k "system/$LEGACY_LABEL"
  fi
  run /bin/rm -f "$PLIST"
  run /bin/rm -rf "$APP_SUPPORT" "$LOG_DIR"
  echo "restored system DNS and removed $LABEL"
}

install_daemon() {
  require_root
  resolve_sources
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -x "$DAEMON_SOURCE" ]] || { echo "missing daemon: $DAEMON_SOURCE" >&2; exit 1; }
    [[ -x "$MIHOMO_SOURCE" ]] || { echo "missing Mihomo: $MIHOMO_SOURCE" >&2; exit 1; }
  fi

  snapshot_installation
  if [[ "$DRY_RUN" -eq 0 ]]; then
    trap rollback_installation ERR
  fi

  run /bin/mkdir -p "$APP_SUPPORT" "$MIHOMO_DATA" "$LOG_DIR"
  run /usr/bin/install -o root -g wheel -m 0755 "$DAEMON_SOURCE" "$APP_SUPPORT/mihomo-daemon"
  run /usr/bin/install -o root -g wheel -m 0755 "$MIHOMO_SOURCE" "$APP_SUPPORT/mihomo"
  run /usr/bin/install -o root -g wheel -m 0644 "$RESOURCE_ROOT/daemon.json" "$APP_SUPPORT/daemon.json"

  if [[ ! -f "$MIHOMO_DATA/config.yaml" ]]; then
    if [[ -d "$LEGACY_DIR" ]]; then
      run /bin/cp -R "$LEGACY_DIR/." "$MIHOMO_DATA/"
    else
      run /usr/bin/install -o root -g wheel -m 0644 \
        "$RESOURCE_ROOT/default-config.yaml" "$MIHOMO_DATA/config.yaml"
    fi
  fi
  run /usr/bin/python3 "$RESOURCE_ROOT/configure_mihomo.py" \
    --config "$MIHOMO_DATA/config.yaml" \
    --backup "$APP_SUPPORT/config.before-mihomo-app.yaml"
  run "$APP_SUPPORT/mihomo" -t -d "$MIHOMO_DATA" -f "$MIHOMO_DATA/config.yaml"

  if /bin/launchctl print "system/$LEGACY_LABEL" >/dev/null 2>&1; then
    run /usr/bin/touch "$LEGACY_MARKER"
    run /bin/launchctl bootout "system/$LEGACY_LABEL"
  fi

  run /usr/bin/install -o root -g wheel -m 0644 \
    "$RESOURCE_ROOT/dev.linsheng.mihomo-app.daemon.plist" "$PLIST"
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$LABEL"
  fi
  run /bin/launchctl bootstrap system "$PLIST"
  run /bin/launchctl enable "system/$LABEL"
  run /bin/launchctl kickstart -k "system/$LABEL"

  wait_for "Mihomo controller 127.0.0.1:9090" /usr/bin/curl -fsS http://127.0.0.1:9090/version
  wait_for "system DNS 127.0.0.53:53" /usr/bin/dig @127.0.0.53 -p 53 test.invalid A +time=1 +tries=1
  wait_for "macOS Global DNS" /bin/sh -c "/usr/sbin/scutil --dns | /usr/bin/grep -q '127\\.0\\.0\\.53'"
  trap - ERR
  if [[ -n "$ROLLBACK_DIR" ]]; then
    /bin/rm -rf "$ROLLBACK_DIR"
  fi
  echo "installed $LABEL"
}

if [[ "$RESTORE" -eq 1 ]]; then
  restore
else
  install_daemon
fi
