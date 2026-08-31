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

/usr/bin/grep -Eq '^[[:space:]]*\{' "$state_file"
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

release_script="$ROOT/scripts/release-macos.sh"
/usr/bin/grep -Fq \
  'PUBLISHED_070_ARCHIVE_SHA256="37a5ea188e7c95ef2e45768193c11c6a2cdd40f672135b613f51230f91efeb0e"' \
  "$release_script"
/usr/bin/grep -Fq \
  'PUBLISHED_070_DEVELOPER_ID_LEAF_SHA1="2E1EF531C972A15F5B5C58855001FA6FA1186383"' \
  "$release_script"
/usr/bin/grep -Fq \
  'XCODE_CLOUD_DEVELOPER_ID_LEAF_SHA1="44B2EB8C6C3C6A85A3687EEDED7D85EB7C13524A"' \
  "$release_script"
/usr/bin/grep -Fq \
  'PUBLISHED_080_ARCHIVE_SHA256="d04c8b432e39df1f2f66ed547f828c95fb490f7ff03c8719bbcbbcff25309c9b"' \
  "$release_script"
/usr/bin/grep -Fq \
  'PUBLISHED_080_SPARKLE_PUBLIC_ED_KEY="CL5i36xBB93GX8INJAcBAVFreeVys28Vu94mgAgTA00="' \
  "$release_script"
/usr/bin/grep -Fq 'verify_published_legacy_archive' "$release_script"
/usr/bin/grep -Fq 'selected Developer ID leaf does not match the leaf used for published 0.7.0' \
  "$release_script"
/usr/bin/grep -Fq \
  '0.9.1 bridge requires exactly the published and Xcode Cloud Developer ID leaves' \
  "$release_script"
/usr/bin/grep -Fq 'prebuilt App Sparkle public key does not match published 0.8.0' \
  "$release_script"

echo "release common tests passed"
