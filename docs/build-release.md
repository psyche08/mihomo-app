# Build and Release

## Pinned Inputs

| Component | Pin | Verification |
|---|---|---|
| Tauri | `2.11.x` Cargo/npm lockfiles | Cargo/npm integrity metadata |
| MetaCubeXD visual reference | tag `v1.271.0`, commit `c4622599d0a597378729a91c3b7f76c5d9803831` | exact revision check; MIT license copied |
| Mihomo | release `v1.19.28` | architecture-specific SHA-256 |
| App icon | upstream Mihomo `Meta.png` | bundled source SHA-256 |

`scripts/prepare-metacubexd.sh` is an explicit reference-refresh tool. It builds
the pinned upstream dashboard for visual comparison and does not participate
in the App bundle. The shipped main window is native SwiftUI.

`scripts/fetch-mihomo.sh` selects the target-triple asset, verifies the pinned
archive checksum, and stages the executable using Tauri's required
`name-<target-triple>` convention.

`scripts/prepare-binaries.sh` builds the Swift release daemon, agent, XPC client,
and static `MihomoBoxUI` library, then stages the external executables. Cargo
links the SwiftUI library into `mihomo-app`; Tauri places the executables in
`Contents/MacOS` without the target suffix.

SwiftPM and Cargo both cache absolute build paths. Their preparation scripts
record the project root and clean only generated caches when the checkout moves.

`scripts/prepare-icons.sh` verifies the checked-in official Mihomo `Meta.png`
and all derived PNG/ICNS outputs by SHA-256. Generated icons are committed;
normal builds do not rewrite ICNS metadata.

## Local Validation

```bash
./scripts/validate.sh
```

The final bundle check must prove:

```text
MihomoBox.app/Contents/MacOS/mihomo-app
MihomoBox.app/Contents/MacOS/mihomo
MihomoBox.app/Contents/MacOS/mihomo-daemon
MihomoBox.app/Contents/MacOS/mihomo-agent
MihomoBox.app/Contents/MacOS/mihomoboxctl
```

For an explicit window smoke test without changing the default hidden startup:

```bash
'src-tauri/target/release/bundle/macos/MihomoBox.app/Contents/MacOS/mihomo-app' \
  --smoke-show-window
```

Add `--native-ui-preview` as well to use bounded in-memory fixtures for visual
QA without requiring a release-signed XPC peer. The environment variables
`MIHOMO_APP_SMOKE_SHOW_WINDOW=1` and `MIHOMO_NATIVE_UI_PREVIEW=1` are equivalent
for automation. Preview is honored only when the executable itself is running
from this checkout's `.build` or `src-tauri/target` tree; installed Apps ignore
it. Production code has no unsigned XPC bypass, and preview mode never opens a
control session.

The ad-hoc bundle produced by `validate.sh` proves native linkage, policy tests,
request mapping and packaging only. It cannot prove the certificate-constrained
Mach service handshake: ad-hoc processes are deliberately rejected, and local
validation never installs or activates the privileged daemon.

Before shipping, exercise the signed IPC path on an isolated macOS test machine:

1. build and sign the App and every bundled helper with the same Developer ID leaf;
2. explicitly install the bundled LaunchDaemon and activate a test profile;
3. run the signed `mihomoboxctl rpc version`, `rpc snapshot`, and
   `rpc connections` read-only probes;
4. open the SwiftUI window without preview mode and verify live proxy, rule,
   connection, traffic, memory, and log data;
5. exercise a proxy selection, rule toggle, connection close, and each safe
   Core Config control, then verify controller readback in the window and
   `rpc snapshot` where applicable.

This signed-machine check is a release acceptance gate, not part of ordinary
validation, because it requires an installed root service and changes test
network/runtime state.

## Signing and Notarization

Unsigned local builds are acceptable for development only. Release builds use
the Developer ID Application certificate whose team matches
`NOTARY_TEAM_ID`. The app, daemon, agent, and CLI helper are signed with that
same leaf certificate because the XPC boundary rejects a differently signed
peer. Credentials are supplied only through:

```text
NOTARY_TEAM_ID
NOTARY_APPLE_ID
NOTARY_PASSWORD
```

Run `scripts/release-macos.sh`; it selects the matching identity, builds and
signs the Tauri bundle, submits the App archive with `notarytool`, staples the
App, creates and signs the DMG, submits and staples the DMG, and verifies both
artifacts with Gatekeeper. Never print credential values.

The script does not gate the upload behind a network precheck. One was tried and
removed: it probed the release endpoints over TLS and scanned the host's proxy
log for recent network errors, and in practice it only ever produced false
negatives — an unrelated OCSP timeout and a CDN host that answers `HEAD /` near
the probe timeout each blocked a release whose network was healthy. Transient
failures are handled where they actually occur instead, by the `notarytool`
retry loop and the resume state below.

The release host's outbound policy is a separate, manual concern, and keeping it
that way is deliberate: no script launches, reloads, configures, or sends a
command to whatever proxy the host runs.

Notarization progress is stored under `dist/.release-state/`, keyed by artifact
SHA-256. The state contains no credentials and records the submission ID,
whether upload completion was explicitly confirmed, and the last notarization
phase. Each artifact is submitted exactly once. As soon as `notarytool` exposes
one unambiguous submission ID, every retry and resumed run waits on that ID even
if the submit process later crashes or never prints its final upload marker. A
state or persistent submit log without one recoverable ID fails closed and must
be reconciled manually; it is never treated as permission to submit again. An
`Accepted` artifact proceeds directly to stapling. A changed artifact receives
a new state file and is never confused with an older submission.

If a release process exits after creating the signed artifacts, resume the exact
existing App/archive/DMG without rebuilding or re-signing:

```bash
scripts/release-macos.sh --resume
```

Resume mode verifies the existing App version and signatures, reuses the exact
artifact whose SHA-256 keys the saved state, and skips phases whose stapled
ticket already validates. It refuses to resume when the App/archive needed by
the current phase is missing or the source and bundle versions differ.

When the build is current but notarization never happened — the upload failed
before a submission was created, for example — skip the compile and go straight
to signing and notarization:

```bash
scripts/release-macos.sh --skip-build
```

`--skip-build` reuses the existing bundle but still re-signs it with the
Developer ID identity and the hardened runtime, then builds the pre-staple
archive from scratch. Re-signing is what makes the flag safe: `validate.sh`
leaves a bundle at the same path signed ad-hoc (`codesign --sign -`), which
notarization rejects. The App itself is the same either way — the release config
only adds `createUpdaterArtifacts` — so re-signing is the whole difference.

Use `--resume` instead whenever a notarization submission was already uploaded:
it must not rebuild the pre-staple archive, because that archive's SHA-256 keys
the saved submission state. The two flags are mutually exclusive.

## Automatic Updates

The signed App first synchronizes any changed root-owned `mihomo-daemon`,
`mihomo-agent`, and `mihomo` binaries through authenticated XPC. The installed
daemon accepts only the fixed component set, validates every replacement against
its own leaf certificate, performs a rollback-capable atomic replacement, and
lets launchd restart it when required. This does not replace or repair the
LaunchDaemon plist or the installation layout; those remain explicit
**Install / Repair Daemon** operations.

Profile configuration lives inside `mihomo-agent`, reached through
`--configure-profile`. It was previously a Python helper staged beside the
daemon, which put it outside that component set: a release could ship a fix
there and no existing installation would ever receive it, because only the
three binaries are replaced. Anything that rewrites a profile therefore belongs
in one of them.

Thirty seconds after startup, the App checks the latest GitHub release manifest.
A newer version is downloaded, verified with the updater public key, installed,
and the App restarts. The restarted App then synchronizes its signed root
components without another administrator prompt.

The updater private key is not part of the repository. Local releases default
to `~/.tauri/mihomobox.key`, or use `TAURI_SIGNING_PRIVATE_KEY` /
`TAURI_UPDATER_KEY_PATH`. Losing or rotating this key prevents already-installed
clients from accepting later updates.

## GitHub Release Notes

Every GitHub Release title and description must be written in English. This
includes the summary, change list, validation notes, and any manually added
upgrade instructions. Review all user-visible release text for this requirement
before publishing or updating a Release; tag names and artifact filenames remain
unchanged.

Each GitHub release must publish these assets from `dist/` under tag `vX.Y.Z`:

```text
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz.sig
MihomoBox-X.Y.Z-macos-arm64.dmg
latest.json
```

`latest.json` points `darwin-aarch64` at the versioned updater archive. The
archive is generated from the notarized and stapled App, then signed with the
Tauri updater key. GitHub's `releases/latest/download/latest.json` endpoint is
the stable update feed. Archive generation disables macOS AppleDouble metadata;
otherwise a leading `._MihomoBox.app` entry prevents Tauri's Rust extractor
from installing the update.

## License Outputs

The project MIT license and `THIRD_PARTY_NOTICES.md` are bundled. The
MetaCubeXD license is retained because its pinned interface and Sunset theme are
the design reference for the native reimplementation. Mihomo binaries are
unmodified official release artifacts.
