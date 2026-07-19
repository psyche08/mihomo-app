#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="/Library/Application Support/Mihomo App"
MIHOMO_DATA="$APP_SUPPORT/mihomo-data"
PROFILES_DIR="$APP_SUPPORT/profiles"
ACTIVE_PROFILE="$APP_SUPPORT/active-profile"
CLI_ENTRY="/usr/local/bin/mihomoboxctl"
LOG_DIR="/Library/Logs/Mihomo App"
PLIST="/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist"
LABEL="dev.linsheng.mihomo.daemon"
RENAMED_PLIST="/Library/LaunchDaemons/dev.linsheng.mihomo-app.daemon.plist"
RENAMED_LABEL="dev.linsheng.mihomo-app.daemon"
LEGACY_DIR="/opt/homebrew/etc/mihomo"
LEGACY_LABEL="homebrew.mxcl.mihomo"
LEGACY_MARKER="$APP_SUPPORT/homebrew-mihomo-was-running"
APP_BUNDLE=""
DRY_RUN=0
RESTORE=0
RESTORE_NETWORK=0
START_SERVICE=0
RESTART_SERVICE=0
IMPORT_PROFILE=""
SWITCH_PROFILE=""
ACTIVATE_PROFILE=0
ROLLBACK_DIR=""
PROFILE_ROLLBACK_DIR=""
PROFILE_DAEMON_WAS_RUNNING=0
PREVIOUS_DAEMON_RUNNING=0
PREVIOUS_RENAMED_DAEMON_RUNNING=0
PREVIOUS_LEGACY_RUNNING=0
PREVIOUS_CLI_LINK=""
PREVIOUS_CLI_LINK_PRESENT=0
CLI_LINK_CHANGED=0

usage() {
  echo "usage: $0 [--app-bundle PATH] [--dry-run] [--restore | --restore-network | --start | --restart | --import-profile PATH [--activate] | --switch-profile NAME]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle) APP_BUNDLE="${2:?missing app bundle path}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --restore) RESTORE=1; shift ;;
    --restore-network) RESTORE_NETWORK=1; shift ;;
    --start) START_SERVICE=1; shift ;;
    --restart) RESTART_SERVICE=1; shift ;;
    --import-profile) IMPORT_PROFILE="${2:?missing profile path}"; shift 2 ;;
    --switch-profile) SWITCH_PROFILE="${2:?missing profile name}"; shift 2 ;;
    --activate) ACTIVATE_PROFILE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$IMPORT_PROFILE" && -n "$SWITCH_PROFILE" ]]; then
  echo "--import-profile and --switch-profile are mutually exclusive" >&2
  exit 2
fi
if [[ $((RESTORE + RESTORE_NETWORK + START_SERVICE + RESTART_SERVICE + (${#IMPORT_PROFILE} > 0) + (${#SWITCH_PROFILE} > 0))) -gt 1 ]]; then
  echo "select only one restore or profile operation" >&2
  exit 2
fi
if [[ "$ACTIVATE_PROFILE" -eq 1 && -z "$IMPORT_PROFILE" ]]; then
  echo "--activate requires --import-profile" >&2
  exit 2
fi
if [[ "$DRY_RUN" -eq 1 && ( -n "$IMPORT_PROFILE" || -n "$SWITCH_PROFILE" ) ]]; then
  echo "--dry-run is not supported for profile operations" >&2
  exit 2
fi

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
    CLI_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomoboxctl"
    RESOURCE_ROOT="$APP_BUNDLE/Contents/Resources/daemon"
  else
    DAEMON_SOURCE="$ROOT/.build/release/mihomo-daemon"
    CLI_SOURCE="$ROOT/.build/release/mihomoboxctl"
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
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then return; fi
    /bin/sleep 0.25
  done
  echo "timed out waiting for $description" >&2
  return 1
}

wait_for_job_absent() {
  local label="$1"
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  for _ in {1..80}; do
    if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then return; fi
    /bin/sleep 0.25
  done
  echo "timed out waiting for launchd to remove $label" >&2
  return 1
}

managed_network_ready() {
  local health
  health="$("$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --health)" || return 1
  local field
  for field in controller_reachable dns_bridge_ready mihomo_dns_ready fake_ip_route_ready system_dns_managed tun_enabled network_consistent; do
    [[ "$health" == *"\"$field\":true"* ]] || return 1
  done
}

managed_cli_link() {
  local target="$1"
  [[ "$target" == */MihomoBox.app/Contents/MacOS/mihomoboxctl ]]
}

install_cli_entry() {
  if [[ -z "$APP_BUNDLE" ]]; then
    echo "warning: skipping global CLI link outside a MihomoBox.app installation" >&2
    return
  fi
  local parent="${CLI_ENTRY%/*}"
  if [[ -e "$CLI_ENTRY" && ! -L "$CLI_ENTRY" ]]; then
    echo "warning: preserving unrelated $CLI_ENTRY; use the CLI from MihomoBox.app/Contents/MacOS" >&2
    return
  fi
  if [[ -L "$CLI_ENTRY" ]]; then
    local target
    target="$(/usr/bin/readlink "$CLI_ENTRY")"
    if ! managed_cli_link "$target"; then
      echo "warning: preserving unrelated symlink $CLI_ENTRY -> $target" >&2
      return
    fi
    [[ "$target" == "$CLI_SOURCE" ]] && return
  fi
  run /bin/mkdir -p "$parent"
  if [[ "$DRY_RUN" -eq 0 ]]; then CLI_LINK_CHANGED=1; fi
  run /bin/ln -sfn "$CLI_SOURCE" "$CLI_ENTRY"
}

remove_cli_entry() {
  [[ -L "$CLI_ENTRY" ]] || return 0
  local target
  target="$(/usr/bin/readlink "$CLI_ENTRY")"
  if managed_cli_link "$target"; then
    run /bin/rm -f "$CLI_ENTRY"
  fi
}

validate_profile_name() {
  local name="$1"
  if [[ -z "$name" || "${#name}" -gt 128 || "$name" == .* || "$name" == */* || "$name" =~ [[:cntrl:]] ]]; then
    echo "invalid profile filename" >&2
    return 1
  fi
  case "$name" in
    *.yaml|*.yml|*.YAML|*.YML) ;;
    *) echo "profile must use a .yaml or .yml extension" >&2; return 1 ;;
  esac
}

prepare_profile() {
  local source="$1"
  local output="$2"
  local backup="$output.original"
  [[ -f "$source" ]] || { echo "profile does not exist" >&2; return 1; }
  local size
  size="$(/usr/bin/stat -f '%z' "$source")"
  [[ "$size" -gt 0 && "$size" -le 16777216 ]] || {
    echo "profile must be between 1 byte and 16 MiB" >&2
    return 1
  }
  /usr/bin/install -o root -g wheel -m 0600 "$source" "$output"
  /usr/bin/python3 "$RESOURCE_ROOT/configure_mihomo.py" \
    --config "$output" \
    --backup "$backup"
  /bin/rm -f "$backup"
  "$APP_SUPPORT/mihomo" -t -d "$MIHOMO_DATA" -f "$output"
}

rollback_profile_switch() {
  local status=$?
  trap - ERR
  echo "profile switch failed; restoring the previous active profile" >&2
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  wait_for_job_absent "$LABEL" || true
  if [[ -f "$PROFILE_ROLLBACK_DIR/config.yaml" ]]; then
    /usr/bin/install -o root -g wheel -m 0644 \
      "$PROFILE_ROLLBACK_DIR/config.yaml" "$MIHOMO_DATA/config.yaml"
  fi
  if [[ -f "$PROFILE_ROLLBACK_DIR/active-profile" ]]; then
    /usr/bin/install -o root -g wheel -m 0644 \
      "$PROFILE_ROLLBACK_DIR/active-profile" "$ACTIVE_PROFILE"
  else
    /bin/rm -f "$ACTIVE_PROFILE"
  fi
  if [[ "$PROFILE_DAEMON_WAS_RUNNING" -eq 1 && -f "$PLIST" ]]; then
    /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
    /bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
  fi
  [[ -z "$PROFILE_ROLLBACK_DIR" ]] || /bin/rm -rf "$PROFILE_ROLLBACK_DIR"
  exit "$status"
}

switch_profile() {
  require_root
  resolve_sources
  local name="$1"
  validate_profile_name "$name"
  local source="$PROFILES_DIR/$name"
  [[ -f "$source" ]] || { echo "profile is not imported: $name" >&2; exit 1; }
  [[ -x "$APP_SUPPORT/mihomo" ]] || { echo "Mihomo daemon is not installed" >&2; exit 1; }
  [[ -f "$RESOURCE_ROOT/configure_mihomo.py" ]] || { echo "missing profile configurator" >&2; exit 1; }

  PROFILE_ROLLBACK_DIR="$(/usr/bin/mktemp -d /private/tmp/mihomo-profile-switch.XXXXXX)"
  if [[ -f "$MIHOMO_DATA/config.yaml" ]]; then
    /bin/cp -p "$MIHOMO_DATA/config.yaml" "$PROFILE_ROLLBACK_DIR/config.yaml"
  fi
  if [[ -f "$ACTIVE_PROFILE" ]]; then
    /bin/cp -p "$ACTIVE_PROFILE" "$PROFILE_ROLLBACK_DIR/active-profile"
  fi
  trap rollback_profile_switch ERR

  local staged
  staged="$(/usr/bin/mktemp "$MIHOMO_DATA/.profile.XXXXXX")"
  prepare_profile "$source" "$staged"
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    PROFILE_DAEMON_WAS_RUNNING=1
    /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
    "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  /bin/chmod 0644 "$staged"
  /usr/sbin/chown root:wheel "$staged"
  /bin/mv -f "$staged" "$MIHOMO_DATA/config.yaml"

  local active_staged
  active_staged="$(/usr/bin/mktemp "$APP_SUPPORT/.active-profile.XXXXXX")"
  /usr/bin/printf '%s\n' "$name" > "$active_staged"
  /bin/chmod 0644 "$active_staged"
  /usr/sbin/chown root:wheel "$active_staged"
  /bin/mv -f "$active_staged" "$ACTIVE_PROFILE"

  if [[ "$PROFILE_DAEMON_WAS_RUNNING" -eq 1 ]]; then
    [[ -f "$PLIST" ]] || { echo "missing LaunchDaemon plist" >&2; false; }
    /bin/launchctl bootstrap system "$PLIST"
    /bin/launchctl enable "system/$LABEL"
    /bin/launchctl kickstart -k "system/$LABEL"
    wait_for "Mihomo controller after profile switch" /usr/bin/curl -fsS http://127.0.0.1:9090/version
    wait_for "macOS Global DNS after profile switch" \
      "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --check-system-dns
    wait_for "fully managed network after profile switch" managed_network_ready
  else
    echo "daemon is not loaded; profile will take effect on the next start"
  fi
  trap - ERR
  /bin/rm -rf "$PROFILE_ROLLBACK_DIR"
  PROFILE_ROLLBACK_DIR=""
  echo "activated profile $name"
}

import_profile() {
  require_root
  resolve_sources
  local source="$1"
  local name="${source##*/}"
  validate_profile_name "$name"
  [[ -x "$APP_SUPPORT/mihomo" ]] || { echo "Mihomo daemon is not installed" >&2; exit 1; }
  /bin/mkdir -p "$PROFILES_DIR" "$MIHOMO_DATA"
  /usr/sbin/chown root:wheel "$PROFILES_DIR"
  /bin/chmod 0755 "$PROFILES_DIR"

  local validation
  validation="$(/usr/bin/mktemp "$MIHOMO_DATA/.profile-import.XXXXXX")"
  if ! prepare_profile "$source" "$validation"; then
    /bin/rm -f "$validation" "$validation.original"
    return 1
  fi
  /bin/rm -f "$validation" "$validation.original"

  local staged
  staged="$(/usr/bin/mktemp "$PROFILES_DIR/.import.XXXXXX")"
  /usr/bin/install -o root -g wheel -m 0600 "$source" "$staged"
  /bin/mv -f "$staged" "$PROFILES_DIR/$name"
  echo "imported profile $name"
  if [[ "$ACTIVATE_PROFILE" -eq 1 ]]; then
    switch_profile "$name"
  fi
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
  if [[ -f "$RENAMED_PLIST" ]]; then
    /bin/cp -p "$RENAMED_PLIST" "$ROLLBACK_DIR/renamed-daemon.plist"
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    PREVIOUS_DAEMON_RUNNING=1
  elif /bin/launchctl print "system/$RENAMED_LABEL" >/dev/null 2>&1; then
    PREVIOUS_RENAMED_DAEMON_RUNNING=1
  fi
  if /bin/launchctl print "system/$LEGACY_LABEL" >/dev/null 2>&1; then
    PREVIOUS_LEGACY_RUNNING=1
  fi
  if [[ -L "$CLI_ENTRY" ]]; then
    PREVIOUS_CLI_LINK="$(/usr/bin/readlink "$CLI_ENTRY")"
    PREVIOUS_CLI_LINK_PRESENT=1
  fi
}

rollback_installation() {
  local status=$?
  trap - ERR
  echo "installation failed; restoring the previous DNS runtime" >&2
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootout "system/$RENAMED_LABEL" >/dev/null 2>&1 || true
  wait_for_job_absent "$LABEL" || true
  wait_for_job_absent "$RENAMED_LABEL" || true
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns \
      >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$APP_SUPPORT"
  /bin/rm -f "$PLIST" "$RENAMED_PLIST"
  if [[ "$CLI_LINK_CHANGED" -eq 1 ]]; then
    /bin/rm -f "$CLI_ENTRY"
    if [[ "$PREVIOUS_CLI_LINK_PRESENT" -eq 1 ]]; then
      /bin/mkdir -p "${CLI_ENTRY%/*}"
      /bin/ln -s "$PREVIOUS_CLI_LINK" "$CLI_ENTRY"
    fi
  fi
  if [[ -d "$ROLLBACK_DIR/app-support" ]]; then
    /usr/bin/ditto "$ROLLBACK_DIR/app-support" "$APP_SUPPORT"
  fi
  if [[ -f "$ROLLBACK_DIR/daemon.plist" ]]; then
    /bin/cp -p "$ROLLBACK_DIR/daemon.plist" "$PLIST"
  fi
  if [[ -f "$ROLLBACK_DIR/renamed-daemon.plist" ]]; then
    /bin/cp -p "$ROLLBACK_DIR/renamed-daemon.plist" "$RENAMED_PLIST"
  fi
  if [[ "$PREVIOUS_DAEMON_RUNNING" -eq 1 && -f "$PLIST" ]]; then
    /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
    /bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
  elif [[ "$PREVIOUS_RENAMED_DAEMON_RUNNING" -eq 1 && -f "$RENAMED_PLIST" ]]; then
    /bin/launchctl bootstrap system "$RENAMED_PLIST" >/dev/null 2>&1 || true
    /bin/launchctl enable "system/$RENAMED_LABEL" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$RENAMED_LABEL" >/dev/null 2>&1 || true
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
  if /bin/launchctl print "system/$RENAMED_LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$RENAMED_LABEL"
  fi
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  if [[ -f "$LEGACY_MARKER" ]]; then
    run /bin/launchctl kickstart -k "system/$LEGACY_LABEL"
  fi
  run /bin/rm -f "$PLIST" "$RENAMED_PLIST"
  remove_cli_entry
  run /bin/rm -rf "$APP_SUPPORT" "$LOG_DIR"
  echo "restored system DNS and removed $LABEL"
}

start_service() {
  require_root
  local restart="$1"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" && -f "$PLIST" ]] || {
      echo "Mihomo LaunchDaemon is not installed; run mihomoboxctl install first" >&2
      exit 1
    }
  fi

  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    if [[ "$restart" -eq 0 ]] && managed_network_ready; then
      echo "$LABEL is already running with a consistent network"
      return
    fi
    run /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
  fi
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  run /bin/launchctl bootstrap system "$PLIST"
  run /bin/launchctl enable "system/$LABEL"
  run /bin/launchctl kickstart -k "system/$LABEL"
  wait_for "Mihomo controller 127.0.0.1:9090" /usr/bin/curl -fsS http://127.0.0.1:9090/version
  wait_for "macOS Global DNS preferences" \
    "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --check-system-dns
  wait_for "effective macOS Global DNS" \
    /bin/sh -c "/usr/sbin/scutil --dns | /usr/bin/grep -q '127\\.0\\.0\\.53'"
  wait_for "fully managed network" managed_network_ready
  echo "started $LABEL with a consistent network"
}

restore_network() {
  require_root
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
  fi
  if /bin/launchctl print "system/$RENAMED_LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$RENAMED_LABEL"
    wait_for_job_absent "$RENAMED_LABEL"
  fi
  if [[ -x "$APP_SUPPORT/mihomo-daemon" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  echo "restored network and stopped Mihomo; configuration and installation were preserved"
}

install_daemon() {
  require_root
  resolve_sources
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -x "$DAEMON_SOURCE" ]] || { echo "missing daemon: $DAEMON_SOURCE" >&2; exit 1; }
    [[ -x "$MIHOMO_SOURCE" ]] || { echo "missing Mihomo: $MIHOMO_SOURCE" >&2; exit 1; }
    if [[ -n "$APP_BUNDLE" ]]; then
      [[ -x "$CLI_SOURCE" ]] || { echo "missing CLI: $CLI_SOURCE" >&2; exit 1; }
    fi
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

  if /bin/launchctl print "system/$RENAMED_LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$RENAMED_LABEL"
    wait_for_job_absent "$RENAMED_LABEL"
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
  fi
  run /usr/bin/install -o root -g wheel -m 0644 \
    "$RESOURCE_ROOT/dev.linsheng.mihomo.daemon.plist" "$PLIST"
  run /bin/rm -f "$RENAMED_PLIST"
  run /bin/launchctl bootstrap system "$PLIST"
  run /bin/launchctl enable "system/$LABEL"
  run /bin/launchctl kickstart -k "system/$LABEL"

  wait_for "Mihomo controller 127.0.0.1:9090" /usr/bin/curl -fsS http://127.0.0.1:9090/version
  wait_for "system DNS 127.0.0.53:53" /usr/bin/dig @127.0.0.53 -p 53 test.invalid A +time=1 +tries=1
  wait_for "macOS Global DNS preferences" \
    "$APP_SUPPORT/mihomo-daemon" --config "$APP_SUPPORT/daemon.json" --check-system-dns
  wait_for "effective macOS Global DNS" \
    /bin/sh -c "/usr/sbin/scutil --dns | /usr/bin/grep -q '127\\.0\\.0\\.53'"
  wait_for "fully managed network" managed_network_ready
  install_cli_entry
  trap - ERR
  if [[ -n "$ROLLBACK_DIR" ]]; then
    /bin/rm -rf "$ROLLBACK_DIR"
  fi
  echo "installed $LABEL"
}

if [[ -n "$IMPORT_PROFILE" ]]; then
  import_profile "$IMPORT_PROFILE"
elif [[ -n "$SWITCH_PROFILE" ]]; then
  switch_profile "$SWITCH_PROFILE"
elif [[ "$RESTORE" -eq 1 ]]; then
  restore
elif [[ "$RESTORE_NETWORK" -eq 1 ]]; then
  restore_network
elif [[ "$START_SERVICE" -eq 1 ]]; then
  start_service 0
elif [[ "$RESTART_SERVICE" -eq 1 ]]; then
  start_service 1
else
  install_daemon
fi
