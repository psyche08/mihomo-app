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
  state_dir="$(/usr/bin/dirname "$state_file")"
  /bin/mkdir -p "$state_dir"
  temporary="$(/usr/bin/mktemp "$state_dir/.notary-state.XXXXXX")"
  /usr/bin/env node -e '
    const fs = require("fs");
    const [path, target, sha256, submissionId, uploaded, status] =
      process.argv.slice(1);
    const state = {
      schema_version: 1,
      artifact: target,
      artifact_sha256: sha256,
      submission_id: submissionId || null,
      upload_confirmed: uploaded === "true",
      status,
      updated_at: new Date().toISOString(),
    };
    fs.writeFileSync(path, `${JSON.stringify(state, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
  ' "$temporary" "$target" "$artifact_sha256" "$submission_id" \
    "$uploaded" "$status"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$state_file"
}

release_read_notary_state() {
  local state_file="$1"
  local key="$2"
  /usr/bin/env node -e '
    const fs = require("fs");
    const [path, key] = process.argv.slice(1);
    const state = JSON.parse(fs.readFileSync(path, "utf8"));
    const value = state[key];
    if (value === null || value === undefined) process.exit(0);
    process.stdout.write(typeof value === "boolean" ? String(value) : value);
  ' "$state_file" "$key"
}
