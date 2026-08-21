#!/usr/bin/env bash
# Source-contract needles intentionally use literal shell syntax.
# shellcheck disable=SC1003,SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="$ROOT/scripts/release-product.zsh"
GITHUB_HELPER="$ROOT/scripts/release-github.zsh"
RELEASE_MACOS="$ROOT/scripts/release-macos.sh"
VALIDATE="$ROOT/scripts/validate.sh"

fail() {
  echo "release product contract: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || fail "missing or unsafe file: $path"
}

require_literal() {
  local path="$1"
  local text="$2"
  /usr/bin/grep -Fq -- "$text" "$path" ||
    fail "missing source contract in ${path#"$ROOT"/}: $text"
}

require_regex() {
  local path="$1"
  local expression="$2"
  /usr/bin/grep -Eq -- "$expression" "$path" ||
    fail "missing source contract regex in ${path#"$ROOT"/}: $expression"
}

reject_literal() {
  local path="$1"
  local text="$2"
  if /usr/bin/grep -Fq -- "$text" "$path"; then
    fail "forbidden source contract in ${path#"$ROOT"/}: $text"
  fi
}

reject_regex() {
  local path="$1"
  local expression="$2"
  if /usr/bin/grep -Eq -- "$expression" "$path"; then
    fail "forbidden source contract regex in ${path#"$ROOT"/}: $expression"
  fi
}

for path in "$PRODUCT" "$GITHUB_HELPER" "$RELEASE_MACOS" "$VALIDATE"; do
  require_file "$path"
done

# Syntax inspection only: neither operator entry point is executed here.
/bin/zsh -n "$PRODUCT"
/bin/zsh -n "$GITHUB_HELPER"

# release-product is the operator boundary. A fresh run reaches compilation
# only through validate.sh; it must not grow a second build/sign/notary path.
require_literal "$PRODUCT" "Operator entry point for a complete MihomoBox release"
require_literal "$PRODUCT" 'readonly VALIDATE_SCRIPT="$ROOT/scripts/validate.sh"'
require_literal "$PRODUCT" '/bin/bash "$VALIDATE_SCRIPT"'
require_literal "$PRODUCT" 'fresh)'
require_literal "$PRODUCT" 'run_validate'
require_literal "$PRODUCT" 'verify_validated_app'
require_literal "$PRODUCT" 'run_release'
reject_regex "$PRODUCT" '(/usr/bin/)?(swift|xcodebuild)([[:space:]]|$)|build-macos-app\.sh'
reject_regex "$PRODUCT" '(/usr/bin/)?codesign([[:space:]]|$)|notarytool([[:space:]]|$)'

# Once five assets have been frozen, resume is a GitHub reconciliation only:
# rebuilding or re-running release-macos would destroy signed provenance.
require_literal "$PRODUCT" 'readonly RELEASE_ASSETS_STATE="$STATE_DIR/release-assets.tsv"'
require_literal "$PRODUCT" 'elif [[ -f "$RELEASE_ASSETS_STATE" ]]; then'
require_literal "$PRODUCT" 'RESUME_ASSETS_FROZEN=1'
require_literal "$PRODUCT" 'if (( RESUME_ASSETS_FROZEN )); then'
require_literal "$PRODUCT" \
  'release assets are frozen; skipping validation and release-macos'

# The product wrapper delegates GitHub mutations only through the exact helper
# interface, with version-and-commit state and confirmation supplied explicitly.
require_literal "$PRODUCT" \
  'local -a arguments=(prepare --state-dir "$STATE_DIR")'
require_literal "$PRODUCT" \
  '/bin/zsh -f "$GITHUB_SCRIPT" "${arguments[@]}"'
require_literal "$PRODUCT" \
  '/bin/zsh -f "$GITHUB_SCRIPT" publish \'
require_literal "$PRODUCT" \
  '--state-dir "$STATE_DIR" --confirm "$CONFIRMATION"'

# State is isolated by the full source commit, while product and signing locks
# remain global across every version.
require_literal "$PRODUCT" 'readonly PRODUCT_LOCK="$STATE_ROOT/release-product.lock"'
require_literal "$PRODUCT" 'readonly STATE_DIR="$STATE_ROOT/$VERSION-$EXPECTED_COMMIT"'
require_literal "$PRODUCT" '[[ "$actual_commit" =~ '\''^[0-9a-f]{40}$'\'' ]]'
require_literal "$PRODUCT" 'export RELEASE_STATE_DIR="$STATE_DIR"'
require_literal "$PRODUCT" 'export RELEASE_LOCK_DIR="$STATE_ROOT/release.lock"'
require_literal "$RELEASE_MACOS" \
  'EXPECTED_SHARED_RELEASE_LOCK_DIR="$(/usr/bin/dirname "$RELEASE_STATE_DIR")/release.lock"'
require_literal "$RELEASE_MACOS" \
  'RELEASE_LOCK_DIR must be the release-state sibling lock'
require_literal "$RELEASE_MACOS" \
  '/bin/rmdir -- "$RELEASE_LOCK_DIR"'
reject_literal "$RELEASE_MACOS" '/bin/rm -rf -- "$RELEASE_LOCK_DIR"'

# The ignored release environment is parsed as allowlisted data. It is never
# sourced or evaluated as shell code.
require_literal "$PRODUCT" \
  'while IFS= read -r environment_line || [[ -n "$environment_line" ]]; do'
require_literal "$PRODUCT" 'allowed_release_variables=('
require_literal "$PRODUCT" 'release input environment checksum changed'
reject_regex "$PRODUCT" '^[[:space:]]*(source|eval)([[:space:]]|$)'
reject_regex "$PRODUCT" \
  '^[[:space:]]*\.[[:space:]].*(RELEASE_ENV|release-0\.8\.0\.env)'

# Non-empty operator-provided notarization values are restored directly. Only
# an empty value is prompted for, and the password prompt remains hidden.
for name in NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD; do
  require_literal "$PRODUCT" "typeset SAVED_${name}=\"\${${name}:-}\""
  require_literal "$PRODUCT" "if [[ -n \"\$SAVED_${name}\" ]]; then"
  require_literal "$PRODUCT" "${name}=\"\$SAVED_${name}\""
  require_literal "$PRODUCT" "if [[ -z \"\${${name}:-}\" ]]; then"
done
require_literal "$PRODUCT" \
  'typeset +x SAVED_NOTARY_TEAM_ID SAVED_NOTARY_APPLE_ID SAVED_NOTARY_PASSWORD'
require_literal "$PRODUCT" \
  'typeset SAVED_GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"'
require_literal "$PRODUCT" 'typeset +x SAVED_GH_TOKEN'
require_literal "$PRODUCT" 'typeset +x PRODUCT_LOCK_TOKEN'
require_literal "$PRODUCT" 'clear_release_environment() {'
require_literal "$GITHUB_HELPER" \
  'unset NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD'
require_literal "$PRODUCT" 'read -r "NOTARY_TEAM_ID?Apple Developer Team ID: "'
require_literal "$PRODUCT" 'read -r "NOTARY_APPLE_ID?Apple ID email: "'
require_literal "$PRODUCT" 'read -r -s \'
require_literal "$PRODUCT" 'export NOTARY_TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD'

for path in "$PRODUCT" "$GITHUB_HELPER" "$RELEASE_MACOS"; do
  reject_literal "$path" 'unlock-keychain'
done

# The GitHub helper freezes exactly the five formal assets for the current
# version. No zip, glob, previous-version artifact, or mutable latest selection
# is part of the upload set.
asset_block="$(
  /usr/bin/sed -n \
    '/^[[:space:]]*ASSET_NAMES=(/,/^[[:space:]]*)[[:space:]]*$/p' \
    "$GITHUB_HELPER"
)"
asset_count="$(
  /usr/bin/printf '%s\n' "$asset_block" |
    /usr/bin/grep -Ec "^[[:space:]]+(\"[^\"]+\"|'[^']+')[[:space:]]*$"
)"
[[ "$asset_count" == "5" ]] || fail "GitHub helper must define exactly five assets"
for asset in \
  'MihomoBox-$VERSION-macos-arm64.app.tar.gz' \
  'MihomoBox-$VERSION-macos-arm64.app.tar.gz.sig' \
  'MihomoBox-$VERSION-macos-arm64.dmg' \
  'latest.json' \
  'appcast.xml'; do
  /usr/bin/printf '%s\n' "$asset_block" | /usr/bin/grep -Fq -- "$asset" ||
    fail "missing exact GitHub asset: $asset"
done
require_literal "$GITHUB_HELPER" '(( ${#REMOTE_ASSET_SEEN[@]} == 5 ))'
require_literal "$GITHUB_HELPER" 'upload_asset_by_release_id() {'
require_literal "$GITHUB_HELPER" \
  'https://uploads.github.com/repos/$REPOSITORY/releases/$release_id/assets?name=$name'
require_literal "$GITHUB_HELPER" \
  'gh_with_auth auth token --hostname github.com |'
require_literal "$GITHUB_HELPER" '/usr/bin/curl \'
require_literal "$GITHUB_HELPER" '--disable \'
require_literal "$GITHUB_HELPER" '--config - \'
require_literal "$GITHUB_HELPER" "--proto-redir '=https' \\"
reject_regex "$GITHUB_HELPER" '(^|[[:space:]])release[[:space:]]+upload([[:space:]]|$)'

# Draft creation is single-shot and persisted through exact phases and an
# immutable numeric release_id. Upload and publication remain bound to it.
for phase in create_pending draft_bound uploaded_verified; do
  require_literal "$GITHUB_HELPER" "$phase"
done
require_literal "$GITHUB_HELPER" \
  '/usr/bin/plutil -insert release_id -integer "$release_id" "$state_temporary"'
require_literal "$GITHUB_HELPER" 'STATE_RELEASE_ID="$(state_value release_id)"'
require_literal "$GITHUB_HELPER" 'exact tag no longer resolves to the locked release ID'
require_literal "$GITHUB_HELPER" '-F draft=true'
require_literal "$GITHUB_HELPER" '-f make_latest=false'

# The tag must be annotated and pushed atomically with the exact main update;
# broad tag pushes and mutable overwrite/delete operations are forbidden.
require_literal "$GITHUB_HELPER" 'cat-file -t "refs/tags/$TAG"'
require_literal "$GITHUB_HELPER" '-c tag.gpgSign=false tag -a "$TAG" "$HEAD_SHA"'
require_literal "$GITHUB_HELPER" 'push --no-verify --atomic origin \'
require_literal "$GITHUB_HELPER" "'HEAD:refs/heads/main'"
require_literal "$GITHUB_HELPER" '"refs/tags/$TAG:refs/tags/$TAG"'
require_literal "$GITHUB_HELPER" 'inspect_remote_annotated_tag() {'
require_literal "$GITHUB_HELPER" \
  '/usr/bin/git -C "$ROOT" ls-remote origin "$tag_ref" "$peeled_ref"'
require_literal "$GITHUB_HELPER" \
  '/usr/bin/git -C "$ROOT" ls-remote origin "$main_ref"'
require_literal "$GITHUB_HELPER" \
  'remote main does not equal the release commit'
require_literal "$GITHUB_HELPER" 'typeset HELPER_GH_TOKEN="${GH_TOKEN:-}"'
require_literal "$GITHUB_HELPER" 'typeset +x HELPER_GH_TOKEN'
require_literal "$GITHUB_HELPER" 'gh_with_auth auth token --hostname github.com'
reject_literal "$GITHUB_HELPER" '"$GH_BIN" auth token --hostname github.com'
require_literal "$GITHUB_HELPER" \
  'remote annotated tag $TAG does not peel to HEAD'
require_literal "$GITHUB_HELPER" \
  '[[ "$RELEASE_BODY_SHA256" == "$NOTES_SHA256" ]]'
reject_literal "$GITHUB_HELPER" 'push --tags'
reject_literal "$GITHUB_HELPER" '--clobber'
reject_regex "$GITHUB_HELPER" \
  '(^|[[:space:]])(release|asset)[[:space:]]+delete([[:space:]]|$)|--method[[:space:]]+DELETE'

# Publication requires the exact version@commit confirmation and PATCHes only
# the state-bound release ID after all five remote digests were verified.
require_literal "$PRODUCT" 'readonly EXPECTED_CONFIRMATION="v$VERSION@$EXPECTED_COMMIT"'
require_literal "$PRODUCT" \
  '[[ "$CONFIRMATION" == "$EXPECTED_CONFIRMATION" ]]'
require_literal "$GITHUB_HELPER" \
  'if [[ "$ACTION" == '\''publish'\'' && "$CONFIRM" != "$TAG@$HEAD_SHA" ]]; then'
require_literal "$GITHUB_HELPER" \
  'gh_api --method PATCH "repos/$REPOSITORY/releases/$release_id" \'
require_literal "$GITHUB_HELPER" '-F draft=false'
require_literal "$GITHUB_HELPER" '-f make_latest=true'
require_literal "$GITHUB_HELPER" 'verify_exact_five_assets "$release_id"'

require_literal "$VALIDATE" '/bin/bash Tests/test_release_product.sh'

echo "release product source contracts passed"
