#!/bin/zsh -f
# Local production archive/export, resumable notarization, and signed Sparkle ZIP.
# Explicit publish mode delegates immutable asset handling to release-github.zsh.
emulate -LR zsh
unsetopt XTRACE VERBOSE
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly ROOT="${0:A:h:h}"
fail() { print -u2 -- "release-local: $*"; exit 1; }
[[ $# == 1 && ( "$1" == prepare || "$1" == resume || "$1" == publish ) ]] || fail 'usage: release-local.zsh prepare|resume|publish'
readonly MODE="$1"
readonly VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail 'invalid VERSION'
readonly MAJOR="${VERSION%%.*}"
readonly REST="${VERSION#*.}"
readonly MINOR="${REST%%.*}"
(( MAJOR > 1 || (MAJOR == 1 && MINOR >= 1) )) || fail 'local releases start at 1.1.0'
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || fail 'release requires a clean checkout'
readonly COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
readonly STATE="$ROOT/dist/.release-state/local-$VERSION-$COMMIT"
readonly LEAF=2E1EF531C972A15F5B5C58855001FA6FA1186383
readonly TEAM=89LGY6BD53
# Non-secret operator defaults persist across releases; never source/eval this file.
readonly CONFIG="${MIHOMOBOX_RELEASE_CONFIG:-${HOME}/.config/mihomobox/release.json}"
config_value() {
  /usr/bin/python3 - "$CONFIG" "$1" <<'PYCONFIG'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
if p.exists():
    if p.is_symlink(): raise SystemExit('release config must not be a symlink')
    v=json.loads(p.read_text()).get(sys.argv[2], '')
    if not isinstance(v, (str,int)) or any(c in str(v) for c in '\r\n\0'): raise SystemExit('invalid release config value')
    print(v)
PYCONFIG
}
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-$(config_value notary_profile)}"
RELEASE_PROFILE_DIR="${RELEASE_PROFILE_DIR:-$(config_value profiles_directory)}"
if [[ "$MODE" == publish ]]; then
  # Publication remains an explicit operator action, bound to the existing exact assets.
  [[ -f "$STATE/notarized.zip" && -f "$STATE/status.json" ]] || fail 'complete prepare/resume and acceptance first'
  [[ "$(plutil -extract status raw -o - "$STATE/status.json")" == Accepted ]] || fail 'notarization not accepted'
  if [[ ! -f "$ROOT/dist/.release-state/$VERSION-$COMMIT/release-assets.tsv" ]]; then
    "$ROOT/scripts/prepare-cloud-release.zsh" --local-zip "$STATE/notarized.zip"
  else
    # Never regenerate feed bytes after GitHub has frozen their digest.
    cmp "$STATE/notarized.zip" "$ROOT/dist/MihomoBox-$VERSION-macos-arm64.zip" || fail 'frozen ZIP changed'
  fi
  typeset -a github_args=(prepare --state-dir "$ROOT/dist/.release-state/$VERSION-$COMMIT")
  [[ -z "${RELEASE_NOTES_FILE:-}" ]] || github_args+=(--notes "$RELEASE_NOTES_FILE")
  "$ROOT/scripts/release-github.zsh" "${github_args[@]}"
  exec "$ROOT/scripts/release-github.zsh" publish --state-dir "$ROOT/dist/.release-state/$VERSION-$COMMIT" --confirm "v$VERSION@$COMMIT"
fi
: "${NOTARY_KEYCHAIN_PROFILE:?Set notary_profile in release.json or NOTARY_KEYCHAIN_PROFILE}"
typeset ruby_gems="$(config_value ruby_gem_home)"
if [[ -n "$ruby_gems" ]]; then export GEM_HOME="$ruby_gems" GEM_PATH="$ruby_gems"; fi
# Validate access before building; credentials remain in the already available keychain.
xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json >/dev/null
mkdir -p "$ROOT/dist/.release-state"
readonly LOCK="$ROOT/dist/.release-state/release.lock"
mkdir "$LOCK" 2>/dev/null || fail 'release lock exists; inspect its owner before recovery'
trap 'rmdir "$LOCK"' EXIT
if [[ "$MODE" == prepare ]]; then
  [[ ! -e "$STATE" ]] || fail 'state exists; use resume'
  mkdir "$STATE"
  # VERSION encodes a stable minimum (1.1.1 -> 1101); a saved floor covers historical Cloud builds.
  typeset patch="${REST#*.}"
  typeset floor="$(config_value build_floor)"
  floor="${floor:-1100}"
  [[ "$floor" =~ '^[1-9][0-9]*$' ]] || fail 'invalid build_floor'
  typeset default_build=$(( MAJOR * 1000 + MINOR * 100 + patch ))
  (( default_build > floor )) || default_build=$(( floor + 1 ))
  RELEASE_BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$default_build}"
  PREVIOUS_RELEASE_BUILD_NUMBER="${PREVIOUS_RELEASE_BUILD_NUMBER:-$floor}"
  [[ "$RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' && "$PREVIOUS_RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail 'invalid build numbers'
  (( RELEASE_BUILD_NUMBER > floor )) || fail 'build must exceed the saved historical floor'
  (( RELEASE_BUILD_NUMBER > PREVIOUS_RELEASE_BUILD_NUMBER )) || fail 'build must increase for Sparkle upgrades'
  print -r -- "$RELEASE_BUILD_NUMBER" > "$STATE/build-number"
  # Reserve build numbers even if a later stage fails. This file contains no secrets.
  /usr/bin/python3 - "$CONFIG" "$RELEASE_BUILD_NUMBER" <<'PYFLOOR'
import json,pathlib,sys,os,tempfile
p=pathlib.Path(sys.argv[1]);p.parent.mkdir(parents=True,exist_ok=True)
if p.is_symlink():raise SystemExit('unsafe release config')
d=json.loads(p.read_text()) if p.exists() else {}
d['build_floor']=max(int(d.get('build_floor',0)),int(sys.argv[2]))
fd,name=tempfile.mkstemp(prefix='.release-',dir=p.parent)
with os.fdopen(fd,'w') as f:json.dump(d,f,indent=2);f.write('\n')
os.replace(name,p)
PYFLOOR
fi
[[ -f "$STATE/build-number" && ! -L "$STATE/build-number" ]] || fail 'missing release state; run prepare'
readonly BUILD_NUMBER="$(cat "$STATE/build-number")"
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail 'invalid saved build number'
# Once sealed, no path below can rebuild or re-sign the accepted submission.
if [[ ! -f "$STATE/notary.zip" ]]; then
  security find-identity -v -p codesigning | grep -F "$LEAF" >/dev/null || fail 'published Developer ID private key is unavailable'
  typeset -a profile_args=(prepare --state "$STATE")
  [[ -z "$RELEASE_PROFILE_DIR" ]] || profile_args+=(--directory "$RELEASE_PROFILE_DIR")
  /usr/bin/python3 "$ROOT/scripts/release-profiles.py" "${profile_args[@]}"
  if [[ ! -f "$STATE/validation.complete" ]]; then
    "$ROOT/scripts/validate.sh" > "$STATE/validation.log" 2>&1
    touch "$STATE/validation.complete"
  fi
  # SwiftPM supplies the checksum-pinned Sparkle distribution after validation.
  if [[ ! -d "$ROOT/build/release-inputs/Sparkle-2.9.4" ]]; then
    mkdir -p "$ROOT/build/release-inputs"
    ditto "$ROOT/.build/artifacts/sparkle/Sparkle" "$ROOT/build/release-inputs/Sparkle-2.9.4"
  fi
  if [[ ! -d "$ROOT/build/release-inputs/Sparkle-2.9.4/Sparkle.framework" ]]; then
    ditto "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$ROOT/build/release-inputs/Sparkle-2.9.4/Sparkle.framework"
  fi
  if [[ ! -f "$STATE/archive.complete" ]]; then
    # Preserve an interrupted, unsealed archive for diagnosis, then start a fresh archive.
    [[ ! -e "$STATE/MihomoBox.xcarchive" ]] || mv "$STATE/MihomoBox.xcarchive" "$STATE/archive-interrupted-$(date +%s).xcarchive"
    xcodebuild archive -project "$ROOT/XcodeCloud/MihomoBox.xcodeproj" -scheme MihomoBox \
      -configuration Release -destination 'generic/platform=macOS' -archivePath "$STATE/MihomoBox.xcarchive" \
      ARCHS=arm64 CURRENT_PROJECT_VERSION="$BUILD_NUMBER" > "$STATE/archive.log" 2>&1
    touch "$STATE/archive.complete"
  fi
  if [[ ! -f "$STATE/export.complete" ]]; then
    [[ ! -e "$STATE/export" ]] || mv "$STATE/export" "$STATE/export-interrupted-$(date +%s)"
    /usr/bin/python3 "$ROOT/scripts/release-profiles.py" verify --state "$STATE"
    /bin/bash "$ROOT/scripts/release-export.sh" "$STATE/MihomoBox.xcarchive" \
      "$STATE/export" "$STATE/export.plist" "$STATE/export.log"
    touch "$STATE/export.complete"
  fi
fi
readonly APP="$STATE/export/MihomoBox.app"
[[ -d "$APP" && ! -L "$APP" ]] || fail 'no exported App; inspect archive/export stage logs'
readonly INFO="$APP/Contents/Info.plist"
readonly MANIFEST="$APP/Contents/Resources/BuildManifest.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")" == "$VERSION" ]] || fail 'App version mismatch'
[[ "$(plutil -extract CFBundleVersion raw -o - "$INFO")" == "$(cat "$STATE/build-number")" ]] || fail 'App build mismatch'
[[ "$(plutil -extract SourceCommit raw -o - "$MANIFEST")" == "$COMMIT" ]] || fail 'App source mismatch'
[[ "$(plutil -extract SourceDirty raw -o - "$MANIFEST")" == false ]] || fail 'App source was dirty'
[[ "$(plutil -extract SUPublicEDKey raw -o - "$INFO")" == 'CL5i36xBB93GX8INJAcBAVFreeVys28Vu94mgAgTA00=' ]] || fail 'Sparkle key changed'
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || fail 'source changed during build'
codesign --verify --deep --strict "$APP"
for code in "$APP" "$APP"/Contents/MacOS/*; do
  codesign --verify --strict -R="anchor apple generic and certificate leaf = H\"$LEAF\"" "$code"
done
"$ROOT/scripts/check-app-proxy-bundle.sh" "$APP" --signed
readonly ZIP="$STATE/notary.zip"
# The exact signed tree is sealed by its ZIP; never recreate an existing submission.
if [[ ! -f "$ZIP" ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP.tmp"
  typeset zip_digest="$(shasum -a 256 "$ZIP.tmp" | awk '{print $1}')"
  printf '%s  %s\n' "$zip_digest" "$ZIP" > "$STATE/notary.sha256.tmp"
  mv "$ZIP.tmp" "$ZIP"
fi
if [[ ! -f "$STATE/notary.sha256" && -f "$STATE/notary.sha256.tmp" && ! -e "$STATE/submit-attempted" ]]; then
  shasum -a 256 -c "$STATE/notary.sha256.tmp" >/dev/null || fail 'incomplete ZIP seal is invalid'
  mv "$STATE/notary.sha256.tmp" "$STATE/notary.sha256"
fi
shasum -a 256 -c "$STATE/notary.sha256" >/dev/null || fail 'submission bytes changed'
if [[ ! -f "$STATE/submission.json" ]]; then
  if [[ -s "$STATE/submission.json.tmp" ]]; then
    # Recover an observed ID after a crash, without submitting the same bytes again.
    /usr/bin/plutil -extract id raw -o - "$STATE/submission.json.tmp" >/dev/null || fail 'ambiguous submission response'
    mv "$STATE/submission.json.tmp" "$STATE/submission.json"
  fi
fi
if [[ ! -f "$STATE/submission.json" ]]; then
  [[ ! -e "$STATE/submit-attempted" ]] || fail 'ambiguous submission; recover its JSON by ID before resuming'
  touch "$STATE/submit-attempted"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json > "$STATE/submission.json.tmp"
  plutil -extract id raw -o - "$STATE/submission.json.tmp" >/dev/null || fail 'submission returned no ID'
  mv "$STATE/submission.json.tmp" "$STATE/submission.json"
fi
readonly ID="$(plutil -extract id raw -o - "$STATE/submission.json")"
[[ "$ID" =~ '^[0-9a-fA-F-]{36}$' ]] || fail 'invalid submission ID'
xcrun notarytool wait "$ID" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json > "$STATE/status.json"
[[ "$(plutil -extract status raw -o - "$STATE/status.json")" == Accepted ]] || fail 'notarization was not accepted'
# Reconstruct from sealed bytes so resume cannot staple/package a modified export.
if [[ ! -f "$STATE/notarized.zip" ]]; then
  if [[ ! -e "$STATE/accepted" ]]; then
    typeset extracted="$(mktemp -d "$STATE/.accepted.XXXXXX")"
    ditto -x -k "$ZIP" "$extracted"
    mv "$extracted" "$STATE/accepted"
  fi
  codesign --verify --deep --strict "$STATE/accepted/MihomoBox.app"
  xcrun stapler staple "$STATE/accepted/MihomoBox.app"
  xcrun stapler validate "$STATE/accepted/MihomoBox.app"
  spctl --assess --type execute "$STATE/accepted/MihomoBox.app"
  ditto -c -k --keepParent "$STATE/accepted/MihomoBox.app" "$STATE/notarized.zip.tmp"
  mv "$STATE/notarized.zip.tmp" "$STATE/notarized.zip"
fi
"$ROOT/scripts/prepare-cloud-release.zsh" --local-zip "$STATE/notarized.zip"
print -- "Local release prepared. Complete signed-machine acceptance, then run release-local.zsh publish."
