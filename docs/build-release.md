# Build and Release

## Current release policy

Production release artifacts originate only from Xcode Cloud after the 0.9.1
certificate bridge. Xcode Cloud owns the release build, Developer ID signing,
notarization and packaging. If a later artifact is published through GitHub or
another download channel, it must be the exact Cloud-produced artifact; a
local build must never be substituted. Local compilation, tests and validation
use ad-hoc signing only.

Version 0.9.1 is the sole migration exception. It may reuse only the already
built App bound to source commit `acb6f380c76d5d5a8bd96d208ce6a5e3947cdb4f`,
signed by published Developer ID leaf
`2E1EF531C972A15F5B5C58855001FA6FA1186383`. Its exact pre-staple ZIP is
notarized through `tools/notarytool-rs`; packaging and GitHub publication may
then run locally. The exception does not authorize rebuilding or re-signing
the accepted App and expires immediately after 0.9.1.

## Pinned Inputs

| Component | Pin | Verification |
|---|---|---|
| Sparkle | `2.9.4` | SwiftPM exact version; binary artifact checksum `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0` |
| MetaCubeXD visual reference | tag `v1.271.0`, commit `c4622599d0a597378729a91c3b7f76c5d9803831` | exact revision check; MIT license copied |
| Mihomo | release `v1.19.28` | architecture-specific SHA-256 |
| App and tray icon | upstream Mihomo `Meta.png` | source, embedded tray resource and derived-output SHA-256 |

`VERSION` is the sole product-version source. SwiftPM builds the user App,
daemon, agent and operator CLI. `scripts/build-macos-app.sh` assembles those
products, the pinned Mihomo binary, Sparkle.framework and checked-in resources
into `build/MihomoBox.app`.

The pinned MetaCubeXD checkout is a visual reference only. Its JavaScript is
never linked, copied into the App, or executed at runtime.

## Operator-owned compilation

Compilation, tests, validation, signing, notarization, packaging and deployment
must be run by the operator outside an agent sandbox. An agent may edit or
statically inspect the commands, but must not execute them.

From the repository root, the operator runs:

```bash
./scripts/validate.sh
```

For a production bundle, set either `SPARKLE_PUBLIC_ED_KEY` or
`SPARKLE_PUBLIC_ED_KEY_FILE` to the base64 raw 32-byte public key. The file must
be regular and non-symlink; the key must be one token with no embedded
whitespace. With neither value, validation explicitly builds a development App
whose feed and automatic updates are disabled, and release rejects that App.

Validation resolves pinned Swift packages, refreshes the visual reference,
runs Swift and shell tests, builds the bundle through
`scripts/build-macos-app.sh`, and performs structural checks on the final App.
It never installs the LaunchDaemon and never changes the current network.

## Operator release orchestration

`scripts/release-product.zsh` is the operator-only release entry point. Because
its `fresh` mode invokes `scripts/validate.sh`, an agent must never run this
script: an agent may edit or statically inspect it, then give the exact command
to the operator to run in a normal Terminal outside the sandbox. The wrapper
does not unlock Keychain Access; an unavailable signing identity remains an
operator-controlled prerequisite and fails closed.

For a one-command local production package that validates and compiles with the
published Sparkle key, signs with Developer ID, notarizes, staples, and creates
the local artifacts without preparing or modifying GitHub, run:

```bash
./scripts/release-product.zsh local
```

`local` uses the same clean-commit, fixed-input, credential, signing identity,
notarization-state, and immutable-artifact gates as a full release. It ends
with `release_result=signed_notarized_local` and never invokes the GitHub
helper. Existing state remains fail-closed and must be resumed or reconciled;
the command never silently deletes or replaces an ambiguous submission.
When an earlier direct `release-macos.sh` attempt crashed before exposing any
submission ID, the operator must first prove from Apple history that no upload
was accepted. Only then may the one-time discard switch be used so `local`
automatically verifies and archives that direct state and ZIP before creating a
new artifact:

```bash
./scripts/release-product.zsh local --discard-direct-submit-unknown
```

The option accepts exactly one `submit_unknown`, `upload_confirmed=false`,
no-ID state whose ZIP bytes match its recorded SHA-256. Other or ambiguous
state remains blocked; the SHA-256 never needs to be entered manually.
If signing, upload, waiting, or stapling is interrupted after state has been
created, inspect the recorded log and resume only that exact local artifact:

```bash
./scripts/release-product.zsh local-resume
```

Start a new acceptance-gated release from a clean, committed, non-detached
branch. The wrapper refreshes `origin/main`, requires it to be an ancestor of
`HEAD`, and the GitHub phase atomically advances main together with the tag; an
intermediate feature-branch push is not required:

```bash
./scripts/release-product.zsh fresh
```

The default result is a draft GitHub Release. `fresh` validates and compiles
once, verifies that `BuildManifest.plist` records the same full source commit
with `SourceDirty=false`, signs and notarizes the prebuilt App, freezes the five
formal assets, creates an annotated `vX.Y.Z` tag, atomically pushes the exact
commit to `main` together with that tag, and uploads only to the release ID
bound in local state. The five-asset set is exactly:

```text
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz.sig
MihomoBox-X.Y.Z-macos-arm64.dmg
latest.json
appcast.xml
```

The wrapper uses non-empty `NOTARY_TEAM_ID`, `NOTARY_APPLE_ID`, and
`NOTARY_PASSWORD` values from the operator environment as-is; it prompts only
for a missing value, and the password is the Apple app-specific password. It
does not request the Mac login or Keychain password and never unlocks a
Keychain. GitHub authentication comes from the normal `gh` credential store or
`GH_TOKEN` (an inherited `GITHUB_TOKEN` is normalized to `GH_TOKEN` only for the
GitHub phase).

Every asset name, byte length and SHA-256 digest is frozen in
`release-assets.tsv` and verified against GitHub. An existing remote asset with
a different size or digest stops the release; the workflow never uses
`--clobber`, deletes an asset, chooses the first draft, or mutates a release by
an unbound tag or URL.

Resume the same version and full commit after inspecting the previous log:

```bash
./scripts/release-product.zsh resume
```

State lives under
`dist/.release-state/X.Y.Z-FULL_SOURCE_COMMIT/`, while
`dist/.release-state/release-product.lock` and
`dist/.release-state/release.lock` serialize product and signing operations
across every version. Before `release-assets.tsv` exists, `resume` delegates to
`release-macos.sh --resume` and retains the existing signed-App and
notarization bindings. Once that asset manifest exists, the artifacts are
immutable: `resume` skips validation and `release-macos.sh` completely and only
reconciles the state-bound GitHub draft, release ID and five remote digests.
Never delete state to force `fresh`.

After signed-machine acceptance, publish only the exact frozen draft using the
full confirmation printed by the wrapper:

```bash
./scripts/release-product.zsh publish \
  --confirm vX.Y.Z@FULL_SOURCE_COMMIT
```

For an explicitly approved release that does not require a separate acceptance
pause, publication may be requested in the initial operator run:

```bash
./scripts/release-product.zsh fresh --publish \
  --confirm vX.Y.Z@FULL_SOURCE_COMMIT
```

Both publication forms re-read the exact numeric GitHub `release_id`, tag,
commit and all five remote digests before making that release public and latest.
The ordinary `fresh` and `resume` forms never publish.

For a deliberate one-command public release, use:

```bash
./scripts/release-product.zsh ship
```

`ship` computes the exact `vX.Y.Z@FULL_SOURCE_COMMIT` confirmation from the
clean committed checkout, then runs the same validation/compilation,
signing/notarization, immutable GitHub upload and publication phases. It does
not bypass any artifact, remote-main, tag, digest or release-ID gate.

Release inputs are version-independent. The wrapper uses the audited Sparkle
tool digests checked into `scripts/release-product.zsh`, tools under
`build/release-inputs/`, and private keys under the operator-owned ignored
paths documented below. A new `VERSION` does not require creating or editing a
`release-X.Y.Z.env` file. The Developer ID Application identity is selected by
`NOTARY_TEAM_ID`; when the team has multiple valid identities,
`CODESIGN_IDENTITY_FINGERPRINT` must still resolve the ambiguity.

Versions `0.8.3`, `0.8.4`, and `0.9.0` are already public. Version `0.9.1` is a
separate native-dashboard release: it uses its own source commit, annotated
tag, state directory, notarization submissions and five assets. Preparing or
publishing `0.9.1` must not delete, resume, replace, upload to, or otherwise
alter any `0.8.x` or `0.9.0` state or GitHub assets.

The bundle gate must find exactly these product executables:

```text
MihomoBox.app/Contents/MacOS/mihomo-app
MihomoBox.app/Contents/MacOS/mihomo
MihomoBox.app/Contents/MacOS/mihomo-daemon
MihomoBox.app/Contents/MacOS/mihomo-agent
MihomoBox.app/Contents/MacOS/mihomoboxctl
```

It must also verify `Sparkle.framework`, `@executable_path/../Frameworks`, the
bundle identifier, `VERSION`, third-party licenses and the absence of WebView
or Tauri runtime assets.

## Xcode Cloud Developer ID transition

The committed Cloud product is `XcodeCloud/MihomoBox.xcodeproj` with the shared
`MihomoBox` scheme. It is a thin archive surface over the package-owned source:
the App and three native helper targets consume local Swift package library
products, while a checksum-pinned Mihomo binary and audited resources are
embedded before Xcode's signing phase. `Package.resolved` is committed in both
the package root and the Xcode project workspace.

Xcode Cloud is configured in two stages:

1. Create a macOS Archive action for the shared `MihomoBox` scheme, Developer ID
   distribution, clean build, and the current Xcode/macOS image.
2. Add Apple's Notarize post-action. Do not add notary credentials, a Developer
   ID private key, the Sparkle private key, or Keychain commands to custom
   scripts; Xcode Cloud owns Developer ID signing and the built-in post-action
   owns App notarization.

The first Cloud archive is bootstrap evidence, not a public update.
`ci_post_xcodebuild.sh` verifies Team ID `89LGY6BD53`, requires all five product
executables to share the App leaf, and logs exactly one
`MIHOMOBOX_CLOUD_DEVELOPER_ID_LEAF_SHA1=...` marker when the Developer ID export
is available. Download the archive and inspect it manually if Xcode Cloud does
not expose that path to the post-build script.

The first notarized Cloud archive, Build 4 from commit `d437935`, observed leaf
`44B2EB8C6C3C6A85A3687EEDED7D85EB7C13524A` on all five product executables.
`SigningCertificateRequirement.migrationLeafSHA1s` pins it beside the published
`2E1EF531C972A15F5B5C58855001FA6FA1186383` leaf. The local release script
refuses to sign 0.9.1 unless that source allowlist contains exactly those two
unique leaves. Publish 0.9.1 with the published certificate; only a later
version may be distributed from the Cloud certificate. Keep the Sparkle EdDSA
key unchanged during this Developer ID rotation.

Xcode Cloud's notarized App archive does not replace the separate DMG, Sparkle
appcast, legacy 0.7 manifest, GitHub immutable-asset, or signed-machine runtime
acceptance gates. Those remain explicit release stages until their artifact
provenance and secret-handling contracts are migrated independently.

The source tree also contains the independent cross-platform Notary API client
at `tools/notarytool-rs`. It uses App Store Connect API-key JWT authentication,
uploads through Apple's temporary S3 credentials, and supports submission
status, history, waiting, developer logs, and append-only recovery state. It
does not sign or staple software. Its only production use is the explicitly
authorized 0.9.1 bridge described above; it otherwise remains a compatibility
and recovery tool for designated test artifacts and must not substitute for a
Cloud production artifact.

For an explicit development-window smoke test:

```bash
'build/MihomoBox.app/Contents/MacOS/mihomo-app' --smoke-show-window
```

Add `--native-ui-preview` to use bounded in-memory visual fixtures. Preview is
honored only for development executables in this checkout; an installed App
always uses authenticated XPC.

An ad-hoc validation bundle proves linkage, tests and packaging only. The Mach
service deliberately rejects an ad-hoc peer, so a release-signed machine gate
must still verify the real App-to-daemon IPC path.

## Signed-machine acceptance

Before publication, use an isolated Mac with a release-signed App and an
explicitly installed test LaunchDaemon:

1. verify all five executables share the App's Developer ID leaf;
2. run signed, read-only `mihomoboxctl rpc version`, `rpc snapshot` and
   `rpc connections` probes;
3. open the SwiftUI window without preview and verify all live pages;
4. verify tray TUN, mode, proxy and profile controls with authoritative XPC
   readback;
5. verify component synchronization, hidden login startup, window restoration,
   DNS/TUN health and one daemon-owned Mihomo process;
6. exercise the legacy 0.7-to-current-0.8.x updater, its explicit verified
   daemon-repair migration, and the Sparkle updater path from 0.8.0.

This acceptance changes runtime state and is not part of normal validation.

## Signing and notarization

`scripts/release-macos.sh` never compiles. It accepts the already validated
`build/MihomoBox.app`, verifies its version, build manifest, and the external
`build/MihomoBox-X.Y.Z-unsigned-bundle.sha256` provenance tree, then signs from
the inside out. The external tree records every unsigned bundle directory,
regular file and safe relative symbolic link, including modes, file hashes and
link-target hashes. Links whose normalized target escapes the App and all
socket, device, FIFO or unknown entries are rejected. Release recomputes the
whole tree byte-for-byte, so extra, missing or modified entries fail even if an
in-bundle manifest is also changed. A non-default App path must supply the
matching external manifest with `--provenance`. Sparkle helpers/framework,
`mihomo-app`, `mihomo`, daemon, agent, CLI and the outer App must all use the
same Developer ID Application leaf.
Do not use `codesign --deep` to sign; use it only for final verification.

The release pipeline uses these operator credentials and fixed audited inputs.
The wrapper derives the fixed paths/pins automatically; only the credential
variables and an optional disambiguating identity fingerprint are inherited:

```text
NOTARY_TEAM_ID
NOTARY_APPLE_ID
NOTARY_PASSWORD
CODESIGN_IDENTITY_FINGERPRINT (optional; required only when the team has multiple identities)
SPARKLE_DISTRIBUTION_ROOT
SPARKLE_ED_KEY_PATH
SPARKLE_GENERATE_APPCAST_SHA256
SPARKLE_SIGN_UPDATE_SHA256
SPARKLE_SIGNATURE_VERIFIER
SPARKLE_SIGNATURE_VERIFIER_SHA256
LEGACY_MINISIGN
LEGACY_UPDATER_PRIVATE_KEY_FILE
LEGACY_UPDATER_SMOKE_ARCHIVE (optional path override)
LEGACY_UPDATER_SMOKE_SIGNATURE (optional path override)
PUBLISHED_080_ARCHIVE (optional path override)
PUBLISHED_080_SIGNATURE (optional path override)
```

`SPARKLE_DISTRIBUTION_ROOT` points at the complete Sparkle 2.9.4 binary
distribution containing `Sparkle.framework`, `bin/generate_appcast` and
`bin/sign_update`. `SPARKLE_ED_KEY_PATH` is a regular non-symlink file with
mode `0400` or `0600`; it contains the base64 Sparkle Ed25519 private key and is
never copied into the App. Because these two tools receive release material and
the private key, their lower-case SHA-256 values must independently match the
audited `SPARKLE_GENERATE_APPCAST_SHA256` and
`SPARKLE_SIGN_UPDATE_SHA256` pins. Do not derive those expected values from the
same untrusted directory during a release. If the requested team has more than one matching
Developer ID Application identity, `CODESIGN_IDENTITY_FINGERPRINT` must be the
exact 40-hex fingerprint. The script never silently selects the first identity.
`LEGACY_MINISIGN` points at the external standard Minisign executable used only
for the temporary 0.7 migration feed.

Before the first release signature, the script authenticates the frozen
published 0.7.0 and 0.8.0 legacy updater archives with the embedded legacy
Minisign public key and requires their exact published SHA-256 values, product
versions and bundle identifier. The default inputs are the corresponding
archive and `.sig` pairs already under `dist/`; the optional path overrides
must still contain those exact bytes and cannot replace the pins. The selected
Developer ID Application fingerprint must equal the frozen 0.7.0 leaf
fingerprint, and both the authenticated 0.8.0 archive and the new App must
contain the frozen 0.8.0 `SUPublicEDKey`. A missing asset, altered wrapper,
different certificate or rotated Sparkle key stops before `codesign`.

`SPARKLE_SIGNATURE_VERIFIER` is a separately audited Ed25519 verifier, not a
build command or a Keychain wrapper. It must be an executable regular
non-symlink file whose lower-case SHA-256 exactly equals
`SPARKLE_SIGNATURE_VERIFIER_SHA256`. Its stable command-line contract is:

```text
verifier --public-key BASE64_RAW_32_BYTE_KEY \
         --signature BASE64_RAW_64_BYTE_SIGNATURE \
         --file EXACT_MESSAGE_FILE
```

`--help` must advertise all three options. Exit status zero means the signature
is valid for the exact bytes of `EXACT_MESSAGE_FILE`; every malformed input,
signature mismatch, read failure or unsupported format must return nonzero. It
must not read a private key, contact a network service, access or unlock a
Keychain, rewrite the input, or accept a digest in place of the file bytes.
Before signing any release artifacts, the release script asks Sparkle 2.9.4
`sign_update` to sign a fresh challenge with the private key file and verifies
that challenge against the App's `SUPublicEDKey`. After `generate_appcast`, it
extracts the signature from the single enclosure whose URL names the current
DMG and verifies the exact DMG bytes with that same App public key. Thus a wrong
private key, wrong App public key, stale enclosure or altered DMG fails closed.

Private keys and credentials never enter the repository or logs. The release
workflow must never invoke `security unlock-keychain`; keychain access is an
operator-controlled prerequisite.

Notarization state is stored under `dist/.release-state/`, keyed by the exact
artifact SHA-256. Once one unambiguous submission ID has been observed, that ID
is permanent for the state: retries only query or wait and never submit again.
A missing or ambiguous ID after a submit attempt fails closed for manual
reconciliation. Accepted artifacts proceed directly to stapling.

One atomic `dist/.release-state/release.lock` covers signing through final feed
generation. A live owner blocks a concurrent release; a stale lock is diagnosed
but never removed automatically. Before fresh signing, all five executable
SHA-256 values must match the bundle's `BuildManifest.plist`. Immediately after
signing, an external state file binds the source commit, signing fingerprint,
App CodeDirectory hash, `CodeResources` SHA-256 and all five signed executable
hashes. `--resume` requires that complete binding to match the existing App and
will not re-sign it. Any previous state for the same version makes a fresh run
fail closed and require explicit `--resume`.

Resume the exact existing artifact without rebuilding or re-signing:

```bash
./scripts/release-macos.sh --resume
```

Do not delete a state file to force another submission. A rejected artifact
requires a new build; a transport failure with a known ID requires resuming the
same state.

## Automatic-update migration

The native 0.8 App uses Sparkle's signed `appcast.xml`, EdDSA enclosure
signatures and Apple code signing. Sparkle performs update verification,
permission handling, atomic replacement and relaunch. Its private EdDSA key is
separate from the legacy updater key.

Production bundles default `SUEnableAutomaticChecks` and
`SUAutomaticallyUpdate` to true. The Config switch writes those two Sparkle
settings through `SPUUpdater`; an explicit user choice therefore overrides the
bundle defaults across later launches. Development bundles continue to disable
the updater when the release public key is absent.

Existing 0.7 clients only understand the previous Minisign-compatible manifest.
During the migration window every 0.8.x GitHub Release therefore carries both
feeds:

```text
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz.sig
MihomoBox-X.Y.Z-macos-arm64.dmg
latest.json
appcast.xml
```

`latest.json`, the tar archive and its signature exist only to move installed
0.7 clients onto 0.8. The native App never parses that manifest. The archive is
created with `COPYFILE_DISABLE=1`, starts with `MihomoBox.app/`, and contains no
AppleDouble or `__MACOSX` entries. A standard external Minisign implementation
must be proven byte-compatible with the existing public key by a real 0.7
updater smoke test before publication.

Replacing the App is not proof that privileged migration succeeded. A real
0.7 acceptance run must continue after relaunch: the native App must classify
the authenticated version-1 daemon as repair-required, keep incompatible
controls disabled, and migrate only after the operator explicitly selects the
verified installer. Acceptance then requires protocol version 2, a current
root-owned `component-version`, matching daemon/agent/Mihomo/CLI artifacts,
exactly one managed runtime, and complete TUN/Fake-IP/DNS health. Also replay
the mixed state produced by 0.8.0 (0.8 App with a 0.7 daemon) and the normal
Sparkle update from a healthy 0.8 daemon.

`appcast.xml` and the DMG serve 0.8 and later. Appcast generation must use the
Sparkle tools from the exact resolved 2.9.4 package, a private key supplied by
path, and a feed URL under the matching GitHub tag. `sign_update --verify` is
not used on the XML feed: that mode verifies an update archive against an
explicit signature. The release gate instead selects the exact DMG enclosure
from the generated XML and verifies its Ed25519 signature over the DMG bytes
with the pinned verifier and the public key embedded in the App.

Keep the legacy feed for at least 180 days or two stable releases. Removal is a
separate measured decision; repository cleanup alone is not evidence that all
installed 0.7 clients have migrated.

## GitHub Release assets

Release titles and descriptions are English. The three artifacts plus two
feeds are treated as one atomic five-file release set: do not upload a subset
while DMG notarization, Sparkle signing or legacy compatibility is incomplete.

Before uploading, freeze SHA-256 values and verify:

- App, updater archive and mounted DMG all report the same product version;
- App and all five executables have the expected leaf certificate;
- App and DMG pass code-sign, stapler, Gatekeeper and DMG verification;
- `latest.json` URL, version and signature match the legacy archive;
- `appcast.xml` enclosure URL, length, version and EdDSA signature match the DMG;
- no asset, state or submission identifier from a previous release is reused.

## License outputs

The project MIT license, `THIRD_PARTY_NOTICES.md`, Mihomo, MetaCubeXD and Sparkle
license texts are bundled. Mihomo remains an unmodified official release
artifact; MetaCubeXD remains a non-shipped design reference.
