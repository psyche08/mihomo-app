#!/usr/bin/env bash

RELEASE_ROOT="${RELEASE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

release_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

release_notary_state_file() {
  local target="$1"
  local artifact_sha256="$2"
  local state_dir="${RELEASE_STATE_DIR:-$RELEASE_ROOT/dist/.release-state}"
  local safe_name
  safe_name="$(/usr/bin/basename "$target" |
    /usr/bin/tr -d '\n' |
    /usr/bin/tr -c 'A-Za-z0-9._-' '_')"
  echo "$state_dir/${safe_name}.${artifact_sha256}.json"
}

release_write_notary_state() {
  local state_file="$1"
  local target="$2"
  local artifact_sha256="$3"
  local submission_id="$4"
  local uploaded="$5"
  local status="$6"
  local state_dir
  local temporary
  local updated_at
  state_dir="$(/usr/bin/dirname "$state_file")"
  /bin/mkdir -p "$state_dir"
  temporary="$(/usr/bin/mktemp "$state_dir/.notary-state.XXXXXX")"
  case "$uploaded" in
    true|false) ;;
    *) echo "invalid upload confirmation state" >&2; return 1 ;;
  esac
  updated_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  /usr/bin/plutil -create json "$temporary"
  /usr/bin/plutil -insert schema_version -integer 1 "$temporary"
  /usr/bin/plutil -insert artifact -string "$target" "$temporary"
  /usr/bin/plutil -insert artifact_sha256 -string "$artifact_sha256" "$temporary"
  if [[ -n "$submission_id" ]]; then
    /usr/bin/plutil -insert submission_id -string "$submission_id" "$temporary"
  fi
  /usr/bin/plutil -insert upload_confirmed -bool "$uploaded" "$temporary"
  /usr/bin/plutil -insert status -string "$status" "$temporary"
  /usr/bin/plutil -insert updated_at -string "$updated_at" "$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$state_file"
}

release_read_notary_state() {
  local state_file="$1"
  local key="$2"
  if /usr/bin/plutil -type "$key" "$state_file" >/dev/null 2>&1; then
    /usr/bin/plutil -extract "$key" raw -n -o - "$state_file"
  fi
}

release_valid_submission_id() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# notarytool may emit other diagnostic UUIDs. Only an explicit `id:` field is
# a submission identity, and multiple distinct IDs are ambiguous rather than a
# reason to guess and risk waiting on or stapling the wrong artifact.
release_submission_id_from_log() {
  local log="$1"
  local ids
  local count
  [[ -f "$log" && ! -L "$log" ]] || return 1
  ids="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*id:[[:space:]]*([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})[[:space:]]*$/\1/p' \
      "$log" |
      /usr/bin/sort -u
  )"
  count="$(
    /usr/bin/printf '%s\n' "$ids" |
      /usr/bin/sed '/^[[:space:]]*$/d' |
      /usr/bin/wc -l |
      /usr/bin/tr -d '[:space:]'
  )"
  [[ "$count" == 1 ]] || return 1
  /usr/bin/printf '%s\n' "$ids"
}
