#!/bin/zsh -f
# Local production archive/export, resumable notarization, and signed Sparkle ZIP.
# Publishing remains a separate release-github.zsh operation.
emulate -LR zsh
unsetopt XTRACE VERBOSE
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly ROOT="${0:A:h:h}"
fail() { print -u2 -- "release-local: $*"; exit 1; }
[[ $# == 1 && ( "$1" == prepare || "$1" == resume ) ]] || fail 'usage: release-local.zsh prepare|resume'
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
: "${NOTARY_KEYCHAIN_PROFILE:?Set an existing notarytool keychain profile; keychain must already be available}"
mkdir -p "$ROOT/dist/.release-state"
readonly LOCK="$ROOT/dist/.release-state/release.lock"
mkdir "$LOCK" 2>/dev/null || fail 'release lock exists; inspect its owner before recovery'
trap 'rmdir "$LOCK"' EXIT
if [[ "$MODE" == prepare ]]; then
  [[ ! -e "$STATE" ]] || fail 'state exists; use resume'
  mkdir "$STATE"
  # A numeric build greater than all previous releases is required for Sparkle.
  : "${RELEASE_BUILD_NUMBER:?Set a numeric build greater than the latest published Sparkle build}"
  : "${PREVIOUS_RELEASE_BUILD_NUMBER:?Set the latest published Sparkle build}"
  [[ "$RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' && "$PREVIOUS_RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail 'invalid build numbers'
  (( RELEASE_BUILD_NUMBER > PREVIOUS_RELEASE_BUILD_NUMBER )) || fail 'build must increase for Sparkle upgrades'
  print -r -- "$RELEASE_BUILD_NUMBER" > "$STATE/build-number"
  # Only the previously published local leaf is accepted: old daemons already trust it.
  security find-identity -v -p codesigning | grep -F "$LEAF" >/dev/null || fail 'published Developer ID private key is unavailable'
  "$ROOT/scripts/validate.sh" > "$STATE/validation.log" 2>&1
  xcodebuild archive -project "$ROOT/XcodeCloud/MihomoBox.xcodeproj" -scheme MihomoBox \
    -configuration Release -destination 'generic/platform=macOS' -archivePath "$STATE/MihomoBox.xcarchive" \
    CURRENT_PROJECT_VERSION="$RELEASE_BUILD_NUMBER" > "$STATE/archive.log" 2>&1
  cat > "$STATE/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>signingCertificate</key><string>$LEAF</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$STATE/MihomoBox.xcarchive" \
    -exportPath "$STATE/export" -exportOptionsPlist "$STATE/export.plist" > "$STATE/export.log" 2>&1
fi
readonly APP="$STATE/export/MihomoBox.app"
[[ -d "$APP" && ! -L "$APP" ]] || fail 'no exported App; inspect archive/export logs (resume never rebuilds)'
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
  [[ "$MODE" == prepare ]] || fail 'missing sealed submission ZIP'
  ditto -c -k --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" > "$STATE/notary.sha256"
fi
shasum -a 256 -c "$STATE/notary.sha256" >/dev/null || fail 'submission bytes changed'
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
  [[ ! -e "$STATE/accepted" ]] || fail 'incomplete packaging; inspect accepted directory before recovery'
  mkdir "$STATE/accepted"
  ditto -x -k "$ZIP" "$STATE/accepted"
  xcrun stapler staple "$STATE/accepted/MihomoBox.app"
  xcrun stapler validate "$STATE/accepted/MihomoBox.app"
  spctl --assess --type execute "$STATE/accepted/MihomoBox.app"
  ditto -c -k --keepParent "$STATE/accepted/MihomoBox.app" "$STATE/notarized.zip.tmp"
  mv "$STATE/notarized.zip.tmp" "$STATE/notarized.zip"
fi
"$ROOT/scripts/prepare-cloud-release.zsh" --local-zip "$STATE/notarized.zip"
print -- "Local release prepared. Review and publish separately with release-github.zsh."
