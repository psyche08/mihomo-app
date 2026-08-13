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
  "$state_file" "$artifact" "$artifact_sha256" \
  "11111111-2222-4333-8444-555555555555" true submitted

test "$(release_read_notary_state "$state_file" artifact_sha256)" = \
  "$artifact_sha256"
test "$(release_read_notary_state "$state_file" submission_id)" = \
  "11111111-2222-4333-8444-555555555555"
test "$(release_read_notary_state "$state_file" upload_confirmed)" = true
test "$(release_read_notary_state "$state_file" status)" = submitted
test "$(/usr/bin/stat -f '%Lp' "$state_file")" = 600

submission_log="$TEST_TMP/submission.log"
/usr/bin/printf '%s\n' \
  'diagnostic request: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' \
  '  id: 11111111-2222-4333-8444-555555555555' \
  '  id: 11111111-2222-4333-8444-555555555555' >"$submission_log"
test "$(release_submission_id_from_log "$submission_log")" = \
  "11111111-2222-4333-8444-555555555555"
release_valid_submission_id "$(release_submission_id_from_log "$submission_log")"

/usr/bin/printf '%s\n' \
  '  id: 11111111-2222-4333-8444-555555555555' \
  '  id: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' >"$submission_log"
if release_submission_id_from_log "$submission_log" >/dev/null; then
  echo "multiple submission IDs must be rejected" >&2
  exit 1
fi

/usr/bin/printf '%s\n' \
  'diagnostic request: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' >"$submission_log"
if release_submission_id_from_log "$submission_log" >/dev/null; then
  echo "a diagnostic UUID must not become a submission ID" >&2
  exit 1
fi

echo "release common tests passed"
