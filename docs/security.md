# Security Model

## Trust Boundaries

- The only privileged client boundary is the launchd Mach service
  `dev.linsheng.mihomo.daemon.control`.
- The daemon and each client configure mutual libxpc code-signing requirements
  derived from their own leaf signing certificate. Requests are delivered only
  when both processes have valid signatures from the exact same certificate.
- App/CLI bundle identifiers are not treated as sufficient identity. Team ID
  alone is not sufficient either; a different certificate for the same team is
  rejected.
- The daemon exposes a typed allowlist, never shell execution, arbitrary file
  reads/writes, arbitrary controller paths, or arbitrary network requests.
  Native controller forwarding accepts only fixed known method/path shapes and
  injects the root-owned controller secret inside the daemon.
- `mihomo-agent` has no public XPC/Mach service. Only the root daemon may launch
  it from its root-owned stable path.
- The in-process SwiftUI module has no shell, installer, root filesystem, raw
  controller endpoint, or direct privileged capability. Its public gateway is
  typed, and every control mutation crosses the authenticated XPC boundary.
- The native AppKit shell may create the current user's MihomoBox LaunchAgent
  after a healthy Enhanced TUN activation. SwiftUI cannot write login items,
  and that LaunchAgent starts only the unprivileged Swift App.
- Bootstrap/repair installation is explicit and uses the macOS administrator
  dialog. Before elevation, the currently executing signed App or CLI derives
  its exact Apple-issued leaf-certificate and designated requirements plus the
  current Code Directory hash. Signed Swift code gives root only a fixed
  system-tool bootstrap:
  root creates a mode-`0700` private directory, copies the complete App with
  `ditto`, then runs `codesign --verify --deep --strict` against the combined
  exact requirement. The copied caller Mach-O is checked against its own exact
  designated requirement as well. Only after both checks pass may root execute
  the snapshot's regular, non-symlink installer resource. The Code Directory
  hash also prevents swapping in an older App signed with the same identity.
  Root never extracts a
  requirement from, or executes a script in, the original movable App path.
  Source-path replacement and arbitrary self-signed requirement tautologies
  therefore fail closed. An optional first profile is snapshotted into bounded
  bytes by the unprivileged App before authorization; root never reopens its
  user-writable path, and activation happens afterward through typed XPC.
  When no root-owned active-profile marker exists, the installer always stages
  the bundled REJECT-only provisioning profile and never reuses an unowned
  legacy config. The LaunchDaemon exposes authenticated XPC but does not start
  the agent, TUN, or managed DNS in this state. The App activates the selected
  profile through typed XPC; only its full-health transaction clears the
  provisioning marker and starts networking. A failed first activation keeps
  real system DNS and cannot silently direct or block traffic. Provisioning is
  accepted as safely stopped only after both persistent SystemConfiguration
  Global/service DNS entries and every effective dynamic Global/service resolver no longer
  contain the managed address, and no managed agent, Mihomo process, TUN,
  route, or DNS listener remains.
  Subsequent lifecycle, profile reload, TUN,
  outbound-mode, and proxy operations do not elevate interactively.
- Post-bootstrap binary synchronization is a typed XPC operation, not an
  installer. It accepts exactly daemon, agent, and Mihomo bytes, caps their
  sizes, verifies every staged executable against the current daemon's exact
  leaf certificate, rejects versions below the root-owned installation floor,
  and rolls back on replacement or health-check failure. A successful verified
  bootstrap atomically records that semantic version in mode-`0600`
  `component-version`; user-controlled App state cannot lower it.
  The verified root installer enforces the same floor before replacing any
  installed artifact. Beside existing managed files, a missing marker is
  accepted only when the exact snapshot CLI authenticates a live protocol-v1
  daemon; malformed, unreachable, current, and future unversioned states fail
  closed. An authenticated future protocol always blocks repair regardless of
  the App's semantic version.
  Every privileged installer mode holds one persistent root-owned BSD file
  lock, so install, restore, profile, and lifecycle transactions cannot modify
  Application Support concurrently. The file's existence is not a stale-lock
  signal: the kernel releases the lock when the process exits. Repair stops the
  old daemon and rejects any component-update pending record before it captures
  the rollback tree, so only stable, transaction-free bytes can be restored.
  This floor is enforced by 0.8.1 and later installers. It cannot revoke an
  already distributed 0.8.0 installer after an administrator explicitly
  authorizes that older root script; operators must treat such authorization
  as an intentional recovery/downgrade action and use the newest installed App.
  Daemon replacement is a two-boot transaction: a mode-`0600` pending record
  binds old/new digests and a root-only backup; the new daemon must prove full
  network health before clearing it. Power loss or failed health restores the
  complete prior signed set with same-filesystem atomic replacement. While
  recovery is incomplete, runtime mutations fail closed.
- A signed legacy protocol response is not permission to downgrade the App's
  XPC requests. Version 1 is classified only from the authenticated response
  envelope, never from a marker file or error string. The tray disables all
  incompatible mutations and requires the user to select the exact-CDHash
  verified installer; polling and component synchronization cannot open an
  administrator prompt. An already-open dashboard request still fails at the
  typed version-2 boundary and cannot mutate or elevate. A peer newer than the
  App disables repair to prevent signed downgrade. The legacy component-update
  path is never re-enabled.
- The privileged root LaunchDaemon executes stable root-owned copies, never
  files in a user-writable Git checkout or movable App bundle. The separate
  current-user LaunchAgent may execute only an installed App under
  `/Applications` or `~/Applications` and has no privileged capability.
- The optional `/usr/local/bin/mihomoboxctl` entry points only to the signed CLI
  copied from the verified snapshot into root-owned Application Support. It
  never points back into the movable App. That standalone entry may perform
  typed XPC operations, but install and uninstall fail closed unless invoked by
  a caller currently executing inside the signed App snapshot source.

Release XPC intentionally fails closed for unsigned and ad-hoc development
builds because they have no Apple-issued leaf signing certificate. XPC
integration tests use explicitly signed fixtures; production code has no
unsigned bypass or environment-variable override.

## Process Privileges

- `mihomo-daemon`: root XPC broker, authorization, transaction serialization,
  agent supervision.
- `mihomo-agent`: root network worker, Mihomo supervision, DNS sockets,
  SystemConfiguration writes, and network-change observation.
- `mihomo-app` / `mihomoboxctl`: current user, authenticated XPC clients only.

The daemon never parses DNS packets or owns the Mihomo child. The agent never
accepts Desktop/CLI requests. This separation keeps authorization policy out of
the network data plane.

## Supply Chain

- MetaCubeXD uses a pinned tag as the native UI's design reference; no upstream
  JavaScript executes in the App.
- Mihomo uses a pinned release and SHA-256.
- SwiftPM lockfiles pin the native dependency graph. The pinned Sparkle binary
  artifact is additionally protected by SwiftPM's recorded checksum.
- Daemon, agent, CLI, Desktop, and DMG use one Developer ID certificate.
- Automatic App updates require Sparkle EdDSA verification and the Developer
  ID/notarized release chain. Signed appcasts prevent feed-field substitution.
  The Sparkle private key never ships in the App or repository. During the 0.7
  migration window, the release-only legacy archive is separately signed with
  the existing minisign-compatible key; that key also never ships.
- Root component updates add a second check at the privilege boundary: each
  executable must satisfy the already-installed daemon's certificate
  requirement before it can replace a root-owned binary.
- Third-party license notices ship with the application.

## Sensitive Data

Do not log or publish:

- DNS query names or packets;
- proxy nodes containing credentials;
- subscription URLs;
- controller tokens;
- XPC request payloads containing profiles;
- notarization credentials.

Tray labels necessarily show configured proxy names and latency to the local
logged-in user; they are never written to daemon or agent logs. Controller
credentials remain root-owned and are never returned over XPC. Profile bytes
are capped, validated, handled in memory or mode-`0600` root-owned staging, and
never passed through command-line arguments.

Mihomo stdout/stderr is reduced in memory to aggregate line, byte, and severity
counts before it reaches disk. Upgrade installation removes legacy raw Mihomo
log generations that could predate this boundary. Normal audit logs are
batch-written; fatal-signal logs remain isolated and synchronous.

The SwiftUI Logs page redacts credential-shaped values before a controller
frame enters observable state, retains at most 500 entries in memory, and has
no export or persistence path. Connection and usage details are likewise
bounded to the current UI session and are never written to application logs.

HTTP subscription credentials live only in the importing user process and are
not persisted. Downloads use an ephemeral URL session, reject non-HTTP(S) and
HTTPS downgrade redirects, remove authentication headers on cross-origin
redirects, cap the response at 16 MiB, and send only the downloaded profile
bytes to the daemon through XPC.

## Recovery Guarantees

- Original DNS is backed up before mutation.
- Restore is compare-before-write and respects external changes.
- Pre-existing `127.0.0.53` aliases are not removed.
- Original-DNS sockets bind to the physical interface to avoid TUN recursion.
- A stale PID is terminated only after executable-path verification.
- Profile reload is serialized by the daemon and rolls back configuration and
  agent state together on failure.
- The daemon writes an exact-path-verified `mihomo-agent.pid`; a restarted
  daemon harvests an orphan before launching another agent, and each agent also
  watches its daemon parent PID so a daemon crash triggers DNS restoration and
  self-termination.
- Repeated child failures use bounded exponential backoff and open a circuit
  after six short-lived failures instead of looping indefinitely.
