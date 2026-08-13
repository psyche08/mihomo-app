#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="/Library/Application Support/Mihomo App"
MIHOMO_DATA="$APP_SUPPORT/mihomo-data"
PROFILES_DIR="$APP_SUPPORT/profiles"
ACTIVE_PROFILE="$APP_SUPPORT/active-profile"
CONTROLLER_SECRET="$APP_SUPPORT/controller-secret"
CONTROLLER_METADATA="$APP_SUPPORT/controller.json"
COMPONENT_VERSION="$APP_SUPPORT/component-version"
PROVISIONING_STATE="$APP_SUPPORT/provisioning"
CLI_ENTRY="/usr/local/bin/mihomoboxctl"
CLI_TARGET_METADATA="$APP_SUPPORT/cli-target"
LOG_DIR="/Library/Logs/Mihomo App"
PLIST="/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist"
LABEL="dev.linsheng.mihomo.daemon"
RENAMED_PLIST="/Library/LaunchDaemons/dev.linsheng.mihomo-app.daemon.plist"
RENAMED_LABEL="dev.linsheng.mihomo-app.daemon"
LEGACY_LABEL="homebrew.mxcl.mihomo"
LEGACY_MARKER="$APP_SUPPORT/homebrew-mihomo-was-running"
APP_BUNDLE=""
VERIFIED_APP_SNAPSHOT=0
VERIFIED_APP_VERSION=""
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
  echo "usage: $0 [--app-bundle PATH --dry-run] [--restore | --restore-network | --start | --restart | --import-profile PATH [--activate] | --switch-profile NAME]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle) APP_BUNDLE="${2:?missing app bundle path}"; shift 2 ;;
    --verified-app-snapshot)
      APP_BUNDLE="${2:?missing verified App snapshot path}"
      VERIFIED_APP_SNAPSHOT=1
      shift 2
      ;;
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

ensure_root_directory() {
  local path="$1"
  local mode="$2"
  run /bin/mkdir -p "$path"
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  [[ -d "$path" && ! -L "$path" &&
    "$(/usr/bin/stat -f '%u' "$path")" == "0" ]] || {
    echo "refusing non-root or symlinked managed directory" >&2
    return 1
  }
  /usr/sbin/chown root:wheel "$path"
  /bin/chmod "$mode" "$path"
}

require_root() {
  if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
    echo "install-daemon.sh must run as root" >&2
    exit 1
  fi
}

require_verified_bootstrap() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$VERIFIED_APP_SNAPSHOT" -eq 0 ]] || {
      echo "--verified-app-snapshot is reserved for the signed Swift bootstrap" >&2
      exit 1
    }
    return
  fi

  require_root
  [[ "$VERIFIED_APP_SNAPSHOT" -eq 1 ]] || {
    echo "refusing privileged execution outside the signed Swift bootstrap" >&2
    exit 1
  }
  [[ "$APP_BUNDLE" == /private/tmp/mihomobox-bootstrap.*/MihomoBox.app &&
    -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
    echo "invalid verified App snapshot" >&2
    exit 1
  }
  local stage="${APP_BUNDLE%/MihomoBox.app}"
  [[ -d "$stage" && ! -L "$stage" &&
    "$(/usr/bin/stat -f '%u:%Lp' "$stage")" == "0:700" ]] || {
    echo "verified App snapshot is not in a root-private directory" >&2
    exit 1
  }
  local installer="$APP_BUNDLE/Contents/Resources/scripts/install-daemon.sh"
  [[ -f "$installer" && ! -L "$installer" && -x "$installer" &&
    "$installer" -ef "${BASH_SOURCE[0]}" ]] || {
    echo "installer is not the verified regular snapshot resource" >&2
    exit 1
  }
  local info_plist="$APP_BUNDLE/Contents/Info.plist"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] || {
    echo "verified App snapshot is missing a regular Info.plist" >&2
    exit 1
  }
  VERIFIED_APP_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    -o - "$info_plist")" || {
    echo "verified App snapshot version is unavailable" >&2
    exit 1
  }
  [[ "$VERIFIED_APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo "verified App snapshot version is not strict semantic versioning" >&2
    exit 1
  }
  ROOT="$APP_BUNDLE/Contents/Resources"
}

write_component_version() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ atomically install component-version from the verified App snapshot"
    return
  fi
  [[ -n "$VERIFIED_APP_VERSION" ]] || {
    echo "verified App component version is unavailable" >&2
    return 1
  }
  local staged
  staged="$(/usr/bin/mktemp "$APP_SUPPORT/.component-version.XXXXXX")"
  /usr/bin/printf '%s\n' "$VERIFIED_APP_VERSION" > "$staged"
  /usr/sbin/chown root:wheel "$staged"
  /bin/chmod 0600 "$staged"
  /bin/mv -f "$staged" "$COMPONENT_VERSION"
  [[ -f "$COMPONENT_VERSION" && ! -L "$COMPONENT_VERSION" &&
    "$(/usr/bin/stat -f '%u:%g:%Lp' "$COMPONENT_VERSION")" == "0:0:600" &&
    "$(/usr/bin/sed -n '1p' "$COMPONENT_VERSION")" == "$VERIFIED_APP_VERSION" ]] || {
    echo "component-version atomic readback failed" >&2
    return 1
  }
}

require_verified_bootstrap

resolve_sources() {
  if [[ -n "$APP_BUNDLE" ]]; then
    DAEMON_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomo-daemon"
    AGENT_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomo-agent"
    MIHOMO_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomo"
    CLI_SOURCE="$APP_BUNDLE/Contents/MacOS/mihomoboxctl"
    RESOURCE_ROOT="$APP_BUNDLE/Contents/Resources/daemon"
  else
    DAEMON_SOURCE="$ROOT/.build/release/mihomo-daemon"
    AGENT_SOURCE="$ROOT/.build/release/mihomo-agent"
    CLI_SOURCE="$ROOT/.build/release/mihomoboxctl"
    local triple
    if [[ -n "${TARGET_TRIPLE:-}" ]]; then
      triple="$TARGET_TRIPLE"
    else
      case "${TARGET_ARCH:-$(/usr/bin/uname -m)}" in
        arm64) triple="aarch64-apple-darwin" ;;
        x86_64) triple="x86_64-apple-darwin" ;;
        *) echo "unsupported target architecture" >&2; exit 1 ;;
      esac
    fi
    MIHOMO_SOURCE="$ROOT/.build/staging/mihomo-$triple"
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

managed_daemon_pids() {
  /usr/bin/pgrep -f -x "$APP_SUPPORT/mihomo-daemon --config $APP_SUPPORT/daemon.json" 2>/dev/null || true
}

signal_managed_daemon_pids() {
  local signal="$1"
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    /bin/kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done <<< "$(managed_daemon_pids)"
}

wait_for_managed_process_absent() {
  [[ "$DRY_RUN" -eq 0 ]] || { echo "+ wait for managed daemon process exit"; return; }
  local deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    [[ -z "$(managed_daemon_pids)" ]] && return
    /bin/sleep 0.25
  done
  echo "managed daemon did not exit after launchd unload; sending SIGTERM" >&2
  signal_managed_daemon_pids TERM
  deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    [[ -z "$(managed_daemon_pids)" ]] && return
    /bin/sleep 0.25
  done
  echo "managed daemon remained stuck after cleanup; sending SIGKILL" >&2
  signal_managed_daemon_pids KILL
  wait_for "managed daemon process exit" /bin/sh -c \
    "! /usr/bin/pgrep -f -x '$APP_SUPPORT/mihomo-daemon --config $APP_SUPPORT/daemon.json' >/dev/null"
}

managed_network_ready() {
  local health
  health="$("$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --health)" || return 1
  local field
  for field in controller_reachable dns_bridge_ready mihomo_dns_ready fake_ip_route_ready system_dns_managed tun_enabled network_consistent; do
    [[ "$health" == *"\"$field\":true"* ]] || return 1
  done
}

managed_controller_ready() {
  local health
  health="$("$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --health)" || return 1
  [[ "$health" == *'"controller_reachable":true'* ]]
}

install_cli_entry() {
  if [[ -z "$APP_BUNDLE" ]]; then
    echo "warning: skipping global CLI outside a MihomoBox.app installation" >&2
    return
  fi
  local parent="${CLI_ENTRY%/*}"
  local managed_target="$APP_SUPPORT/mihomoboxctl"
  if [[ -e "$CLI_ENTRY" && ! -L "$CLI_ENTRY" ]]; then
    echo "warning: preserving unrelated $CLI_ENTRY; use $managed_target" >&2
    return
  fi
  if [[ -L "$CLI_ENTRY" ]]; then
    local existing_target
    existing_target="$(/usr/bin/readlink "$CLI_ENTRY")"
    if [[ "$existing_target" != "$managed_target" ]]; then
      local recorded_target=""
      if [[ -f "$CLI_TARGET_METADATA" && ! -L "$CLI_TARGET_METADATA" &&
        "$(/usr/bin/stat -f '%u:%g' "$CLI_TARGET_METADATA")" == "0:0" ]]; then
        recorded_target="$(/usr/bin/sed -n '1p' "$CLI_TARGET_METADATA")"
      fi
      if [[ "$existing_target" != "$recorded_target" || -z "$recorded_target" ]]; then
        echo "warning: preserving unrelated symlink $CLI_ENTRY" >&2
        return
      fi
    fi
  fi
  run /bin/mkdir -p "$parent"
  run /bin/ln -sfn "$managed_target" "$CLI_ENTRY"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    CLI_LINK_CHANGED=1
    [[ -L "$CLI_ENTRY" && "$(/usr/bin/readlink "$CLI_ENTRY")" == "$managed_target" ]] || {
      echo "managed CLI link readback failed" >&2
      return 1
    }
    local staged
    staged="$(/usr/bin/mktemp "$APP_SUPPORT/.cli-target.XXXXXX")"
    /usr/bin/printf '%s\n' "$managed_target" > "$staged"
    /usr/sbin/chown root:wheel "$staged"
    /bin/chmod 0600 "$staged"
    /bin/mv -f "$staged" "$CLI_TARGET_METADATA"
  fi
}

remove_cli_entry() {
  local recorded_target=""
  if [[ -f "$CLI_TARGET_METADATA" && ! -L "$CLI_TARGET_METADATA" &&
    "$(/usr/bin/stat -f '%u:%g' "$CLI_TARGET_METADATA")" == "0:0" ]]; then
    recorded_target="$(/usr/bin/sed -n '1p' "$CLI_TARGET_METADATA")"
  fi
  if [[ -n "$recorded_target" && -L "$CLI_ENTRY" &&
    "$(/usr/bin/readlink "$CLI_ENTRY")" == "$recorded_target" ]]; then
    run /bin/rm -f "$CLI_ENTRY"
  fi
  run /bin/rm -f "$CLI_TARGET_METADATA"
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
  local publish_controller="${3:-0}"
  local backup="$output.original"
  [[ -f "$source" ]] || { echo "profile does not exist" >&2; return 1; }
  local size
  size="$(/usr/bin/stat -f '%z' "$source")"
  [[ "$size" -gt 0 && "$size" -le 16777216 ]] || {
    echo "profile must be between 1 byte and 16 MiB" >&2
    return 1
  }
  /usr/bin/install -o root -g wheel -m 0600 "$source" "$output"
  if [[ "$publish_controller" -eq 1 ]]; then
    "$AGENT_SOURCE" --configure-profile \
      --profile "$output" \
      --profile-backup "$backup" \
      --secret-file "$CONTROLLER_SECRET" \
      --controller-metadata "$CONTROLLER_METADATA" \
      --daemon-config "$APP_SUPPORT/daemon.json"
    /usr/sbin/chown root:wheel "$CONTROLLER_SECRET" "$APP_SUPPORT/daemon.json"
    /bin/chmod 0600 "$CONTROLLER_SECRET" "$APP_SUPPORT/daemon.json"
    /usr/sbin/chown root:wheel "$CONTROLLER_METADATA"
    /bin/chmod 0600 "$CONTROLLER_METADATA"
  else
    "$AGENT_SOURCE" --configure-profile \
      --profile "$output" \
      --profile-backup "$backup"
  fi
  /bin/rm -f "$backup"
  "$APP_SUPPORT/mihomo" -t -d "$MIHOMO_DATA" -f "$output"
}

write_active_profile_name() {
  local name="$1"
  local active_staged
  active_staged="$(/usr/bin/mktemp "$APP_SUPPORT/.active-profile.XXXXXX")"
  /usr/bin/printf '%s\n' "$name" > "$active_staged"
  /bin/chmod 0644 "$active_staged"
  /usr/sbin/chown root:wheel "$active_staged"
  /bin/mv -f "$active_staged" "$ACTIVE_PROFILE"
}

install_profile_for_first_start() {
  local source="$1"
  local name="${source##*/}"
  validate_profile_name "$name"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ validate, install, and activate initial profile $name"
    return 0
  fi
  [[ -f "$source" && ! -L "$source" ]] || {
    echo "selected profile does not exist or is not a regular file" >&2
    return 1
  }
  ensure_root_directory "$PROFILES_DIR" 0755
  ensure_root_directory "$MIHOMO_DATA" 0755

  local stored
  stored="$(/usr/bin/mktemp "$PROFILES_DIR/.import.XXXXXX")"
  /usr/bin/install -o root -g wheel -m 0600 "$source" "$stored"
  local staged_config
  staged_config="$(/usr/bin/mktemp "$MIHOMO_DATA/.profile-install.XXXXXX")"
  prepare_profile "$stored" "$staged_config" 1
  /bin/chmod 0600 "$staged_config"
  /usr/sbin/chown root:wheel "$staged_config"
  /bin/mv -f "$stored" "$PROFILES_DIR/$name"
  /bin/mv -f "$staged_config" "$MIHOMO_DATA/config.yaml"
  write_active_profile_name "$name"
  echo "selected profile $name for first start"
}

rollback_profile_switch() {
  local status=$?
  trap - ERR
  echo "profile switch failed; restoring the previous active profile" >&2
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  wait_for_job_absent "$LABEL" || true
  wait_for_managed_process_absent || true
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
  for controller_file in daemon.json controller.json controller-secret; do
    if [[ -f "$PROFILE_ROLLBACK_DIR/$controller_file" ]]; then
      /bin/cp -p "$PROFILE_ROLLBACK_DIR/$controller_file" "$APP_SUPPORT/$controller_file"
    else
      /bin/rm -f "$APP_SUPPORT/$controller_file"
    fi
  done
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
  [[ -x "$AGENT_SOURCE" ]] || { echo "missing profile configurator" >&2; exit 1; }

  PROFILE_ROLLBACK_DIR="$(/usr/bin/mktemp -d /private/tmp/mihomo-profile-switch.XXXXXX)"
  if [[ -f "$MIHOMO_DATA/config.yaml" ]]; then
    /bin/cp -p "$MIHOMO_DATA/config.yaml" "$PROFILE_ROLLBACK_DIR/config.yaml"
  fi
  if [[ -f "$ACTIVE_PROFILE" ]]; then
    /bin/cp -p "$ACTIVE_PROFILE" "$PROFILE_ROLLBACK_DIR/active-profile"
  fi
  for controller_file in daemon.json controller.json controller-secret; do
    if [[ -f "$APP_SUPPORT/$controller_file" ]]; then
      /bin/cp -p "$APP_SUPPORT/$controller_file" "$PROFILE_ROLLBACK_DIR/$controller_file"
    fi
  done
  trap rollback_profile_switch ERR

  local staged
  staged="$(/usr/bin/mktemp "$MIHOMO_DATA/.profile.XXXXXX")"
  prepare_profile "$source" "$staged" 1
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    PROFILE_DAEMON_WAS_RUNNING=1
    /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
    wait_for_managed_process_absent
    "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  /bin/chmod 0600 "$staged"
  /usr/sbin/chown root:wheel "$staged"
  /bin/mv -f "$staged" "$MIHOMO_DATA/config.yaml"

  write_active_profile_name "$name"

  if [[ "$PROFILE_DAEMON_WAS_RUNNING" -eq 1 ]]; then
    [[ -f "$PLIST" ]] || { echo "missing LaunchDaemon plist" >&2; false; }
    /bin/launchctl bootstrap system "$PLIST"
    /bin/launchctl enable "system/$LABEL"
    /bin/launchctl kickstart -k "system/$LABEL"
    wait_for "authenticated Mihomo controller after profile switch" managed_controller_ready
    wait_for "macOS PrimaryService DNS after profile switch" \
      "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --check-system-dns
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
  ensure_root_directory "$PROFILES_DIR" 0755
  ensure_root_directory "$MIHOMO_DATA" 0755

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
  wait_for_managed_process_absent || true
  if [[ -x "$APP_SUPPORT/mihomo-agent" && -f "$APP_SUPPORT/daemon.json" ]]; then
    "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns \
      >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$APP_SUPPORT"
  /bin/rm -f "$PLIST" "$RENAMED_PLIST"
  if [[ "$CLI_LINK_CHANGED" -eq 1 ]]; then
    local installed_target="$APP_SUPPORT/mihomoboxctl"
    if [[ -L "$CLI_ENTRY" &&
      "$(/usr/bin/readlink "$CLI_ENTRY")" == "$installed_target" ]]; then
      /bin/rm -f "$CLI_ENTRY"
      if [[ "$PREVIOUS_CLI_LINK_PRESENT" -eq 1 ]]; then
        /bin/mkdir -p "${CLI_ENTRY%/*}"
        /bin/ln -s "$PREVIOUS_CLI_LINK" "$CLI_ENTRY"
      fi
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
  wait_for_job_absent "$LABEL"
  wait_for_job_absent "$RENAMED_LABEL"
  wait_for_managed_process_absent
  if [[ -x "$APP_SUPPORT/mihomo-agent" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
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
    [[ ! -f "$PROVISIONING_STATE" ]] || {
      echo "activate a profile before starting the managed runtime" >&2
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
  wait_for_managed_process_absent
  if [[ -x "$APP_SUPPORT/mihomo-agent" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  run /bin/launchctl bootstrap system "$PLIST"
  run /bin/launchctl enable "system/$LABEL"
  run /bin/launchctl kickstart -k "system/$LABEL"
  wait_for "authenticated Mihomo controller" managed_controller_ready
  wait_for "macOS PrimaryService DNS preferences" \
    "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --check-system-dns
  wait_for "effective macOS DNS" \
    /bin/sh -c "/usr/sbin/scutil --dns | /usr/bin/grep -q '127\\.0\\.0\\.53'"
  wait_for "fully managed network" managed_network_ready
  echo "started $LABEL with a consistent network"
}

restore_network() {
  require_root
  if [[ -x "$APP_SUPPORT/mihomo-agent" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$LABEL"
    wait_for_job_absent "$LABEL"
  fi
  if /bin/launchctl print "system/$RENAMED_LABEL" >/dev/null 2>&1; then
    run /bin/launchctl bootout "system/$RENAMED_LABEL"
    wait_for_job_absent "$RENAMED_LABEL"
  fi
  wait_for_managed_process_absent
  if [[ -x "$APP_SUPPORT/mihomo-agent" && -f "$APP_SUPPORT/daemon.json" ]]; then
    run "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --restore-system-dns
  fi
  echo "restored network and stopped Mihomo; configuration and installation were preserved"
}

install_daemon() {
  require_root
  resolve_sources
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -f "$DAEMON_SOURCE" && ! -L "$DAEMON_SOURCE" && -x "$DAEMON_SOURCE" ]] || {
      echo "missing regular daemon: $DAEMON_SOURCE" >&2
      exit 1
    }
    [[ -f "$AGENT_SOURCE" && ! -L "$AGENT_SOURCE" && -x "$AGENT_SOURCE" ]] || {
      echo "missing regular agent: $AGENT_SOURCE" >&2
      exit 1
    }
    [[ -f "$MIHOMO_SOURCE" && ! -L "$MIHOMO_SOURCE" && -x "$MIHOMO_SOURCE" ]] || {
      echo "missing regular Mihomo: $MIHOMO_SOURCE" >&2
      exit 1
    }
    if [[ -n "$APP_BUNDLE" ]]; then
      [[ -f "$CLI_SOURCE" && ! -L "$CLI_SOURCE" && -x "$CLI_SOURCE" ]] || {
        echo "missing regular CLI: $CLI_SOURCE" >&2
        exit 1
      }
    fi
  fi

  snapshot_installation
  if [[ "$DRY_RUN" -eq 0 ]]; then
    trap rollback_installation ERR
  fi

  ensure_root_directory "$APP_SUPPORT" 0755
  ensure_root_directory "$MIHOMO_DATA" 0755
  ensure_root_directory "$LOG_DIR" 0755
  run /usr/bin/install -o root -g wheel -m 0755 "$DAEMON_SOURCE" "$APP_SUPPORT/mihomo-daemon"
  run /usr/bin/install -o root -g wheel -m 0755 "$AGENT_SOURCE" "$APP_SUPPORT/mihomo-agent"
  run /usr/bin/install -o root -g wheel -m 0755 "$MIHOMO_SOURCE" "$APP_SUPPORT/mihomo"
  if [[ -n "$APP_BUNDLE" ]]; then
    run /usr/bin/install -o root -g wheel -m 0755 "$CLI_SOURCE" "$APP_SUPPORT/mihomoboxctl"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if ! [[ -f "$APP_SUPPORT/mihomoboxctl" && ! -L "$APP_SUPPORT/mihomoboxctl" &&
        "$(/usr/bin/stat -f '%u:%g:%Lp' "$APP_SUPPORT/mihomoboxctl")" == "0:0:755" ]] ||
        ! /usr/bin/cmp -s "$CLI_SOURCE" "$APP_SUPPORT/mihomoboxctl"; then
        echo "installed CLI readback failed" >&2
        exit 1
      fi
    fi
  fi
  run /usr/bin/install -o root -g wheel -m 0600 "$RESOURCE_ROOT/daemon.json" "$APP_SUPPORT/daemon.json"
  # Left behind by installations up to 0.6.1, when profile configuration was a
  # Python helper staged here. Nothing calls it any more. Removed only on an
  # explicit install or repair: a component-update rollback can restore a 0.6.1
  # daemon, which still expects to find it.
  run /bin/rm -f "$APP_SUPPORT/configure_mihomo.py"

  local selected_profile=""
  local provisioning_install=0
  if [[ -z "$selected_profile" && -f "$ACTIVE_PROFILE" ]]; then
    local selected_name
    selected_name="$(/usr/bin/sed -n '1p' "$ACTIVE_PROFILE")"
    validate_profile_name "$selected_name"
    selected_profile="$PROFILES_DIR/$selected_name"
  fi
  if [[ -n "$selected_profile" ]]; then
    install_profile_for_first_start "$selected_profile"
    run /bin/rm -f "$PROVISIONING_STATE"
  else
    # A configuration without an active-profile marker has no authenticated
    # product-level owner. Never reuse it during install/repair: older builds
    # could leave a DIRECT fallback here. The bundled provisioning profile is
    # deliberately REJECT-only; the signed App activates the selected profile
    # over typed XPC after this verified installer returns.
    run /usr/bin/install -o root -g wheel -m 0644 \
      "$RESOURCE_ROOT/default-config.yaml" "$MIHOMO_DATA/config.yaml"
    run "$AGENT_SOURCE" --configure-profile \
      --profile "$MIHOMO_DATA/config.yaml" \
      --profile-backup "$APP_SUPPORT/config.before-mihomo-app.yaml" \
      --secret-file "$CONTROLLER_SECRET" \
      --controller-metadata "$CONTROLLER_METADATA" \
      --daemon-config "$APP_SUPPORT/daemon.json"
    run /usr/sbin/chown root:wheel "$CONTROLLER_SECRET" "$APP_SUPPORT/daemon.json" "$MIHOMO_DATA/config.yaml" "$APP_SUPPORT/config.before-mihomo-app.yaml"
    run /bin/chmod 0600 "$CONTROLLER_SECRET" "$APP_SUPPORT/daemon.json" "$MIHOMO_DATA/config.yaml" "$APP_SUPPORT/config.before-mihomo-app.yaml"
    run /usr/sbin/chown root:wheel "$CONTROLLER_METADATA"
    run /bin/chmod 0600 "$CONTROLLER_METADATA"
    run "$APP_SUPPORT/mihomo" -t -d "$MIHOMO_DATA" -f "$MIHOMO_DATA/config.yaml"
    provisioning_install=1
    run /usr/bin/touch "$PROVISIONING_STATE"
    run /usr/sbin/chown root:wheel "$PROVISIONING_STATE"
    run /bin/chmod 0600 "$PROVISIONING_STATE"
  fi

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
  wait_for_managed_process_absent
  run /bin/rm -f \
    "$LOG_DIR/mihomo.log" \
    "$LOG_DIR/mihomo.log.1" \
    "$LOG_DIR/mihomo.log.2" \
    "$LOG_DIR/mihomo.log.3"
  run /usr/bin/install -o root -g wheel -m 0644 \
    "$RESOURCE_ROOT/dev.linsheng.mihomo.daemon.plist" "$PLIST"
  run /bin/rm -f "$RENAMED_PLIST"
  # Commit the version floor before the new daemon starts so its first
  # component-update request cannot observe an unversioned installation. The
  # surrounding installation rollback restores the prior marker on any later
  # health failure.
  write_component_version
  run /bin/launchctl bootstrap system "$PLIST"
  run /bin/launchctl enable "system/$LABEL"
  run /bin/launchctl kickstart -k "system/$LABEL"

  if [[ "$provisioning_install" -eq 1 ]]; then
    # The root daemon is available for authenticated profile activation, but
    # it deliberately has not launched the agent or modified system networking.
    wait_for "authenticated daemon XPC" "$APP_SUPPORT/mihomoboxctl" profiles --json
  else
    wait_for "authenticated Mihomo controller" managed_controller_ready
    wait_for "system DNS 127.0.0.53:53" /usr/bin/dig @127.0.0.53 -p 53 test.invalid A +time=1 +tries=1
    wait_for "macOS PrimaryService DNS preferences" \
      "$APP_SUPPORT/mihomo-agent" --config "$APP_SUPPORT/daemon.json" --check-system-dns
    wait_for "effective macOS DNS" \
      /bin/sh -c "/usr/sbin/scutil --dns | /usr/bin/grep -q '127\\.0\\.0\\.53'"
    wait_for "fully managed network" managed_network_ready
  fi
  install_cli_entry
  trap - ERR
  if [[ -n "$ROLLBACK_DIR" ]]; then
    /bin/rm -rf "$ROLLBACK_DIR"
  fi
  echo "installed $LABEL provisioning=$provisioning_install"
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
