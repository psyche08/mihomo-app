#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/release-common.sh"

TEST_TMP="$(/usr/bin/mktemp -d /private/tmp/mihomobox-release-tests.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

artifact="$TEST_TMP/artifact.zip"
/usr/bin/printf 'notary fixture\n' >"$artifact"
artifact_sha256="$(release_sha256 "$artifact")"
export RELEASE_STATE_DIR="$TEST_TMP/state"
state_file="$(release_notary_state_file "$artifact" "$artifact_sha256")"
release_write_notary_state \
  "$state_file" "$artifact" "$artifact_sha256" "submission-1" true uploaded

test "$(release_read_notary_state "$state_file" artifact_sha256)" = \
  "$artifact_sha256"
test "$(release_read_notary_state "$state_file" submission_id)" = \
  "submission-1"
test "$(release_read_notary_state "$state_file" upload_confirmed)" = true
test "$(release_read_notary_state "$state_file" status)" = uploaded
test "$(/usr/bin/stat -f '%Lp' "$state_file")" = 600

echo "release common tests passed"
