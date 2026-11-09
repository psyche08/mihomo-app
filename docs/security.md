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
- The daemon allocates a fresh kernel-selected utun and holds its primary fd.
  Only its root agent inherits a duplicate. The fixed signed exec-only agent
  entry validates the parent executable and live daemon ownership before moving
  stdin to fd 3 and execing the fixed managed core/config paths. It accepts no
  arbitrary command/path. Interface mutation verifies the actual utun control
  socket; a caller-supplied interface name grants no capability. Public XPC
  snapshots expose effective interception and omit the internal descriptor.
  Standby retains an attached interface but no interception routes; full stop
  clears addresses/routes and retains only the daemon's inactive capability.
- The in-process SwiftUI module has no shell, installer, root filesystem, raw
  controller endpoint, or direct privileged capability. Its public gateway is
  typed, and every control mutation crosses the authenticated XPC boundary.
- The native AppKit shell may create the current user's MihomoBox LaunchAgent
  on first installed App launch, without requiring TUN readiness. SwiftUI cannot write login items,
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
  the agent or TUN in this state. The App activates the selected
  profile through typed XPC; only its full-health transaction clears the
  provisioning marker and starts networking. A failed first activation keeps
  real system DNS and cannot silently direct or block traffic. Provisioning is
  accepted as safely stopped only after both persistent SystemConfiguration
  Global/service DNS entries and every effective dynamic Global/service resolver no longer
  contain the managed address, and no managed agent, Mihomo process, TUN interception,
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
- The App Proxy system extension (signing identifier
  `dev.linsheng.mihomo-app.app-proxy`) is a second kind of peer on the same
  Mach service, with a narrower role. The daemon classifies each connection
  once, from its first message, with `SecCodeCreateWithXPCMessage` and
  `SecCodeCheckValidity` against that identifier plus the release certificate
  family. The extension role may call only `dns.resolve`, and no other peer may
  call `dns.resolve`; a refused call is logged as
  `result=peer_not_permitted role=<role>`. The extension parses untrusted
  application traffic, so it gains no profile, lifecycle, controller or
  settings capability through this connection. Its sandbox entitlement adds
  only a `com.apple.security.temporary-exception.mach-lookup.global-name`
  exception for `dev.linsheng.mihomo.daemon.control`; whether that exception
  works for the sandboxed system extension is not yet verified on a device.
- `dns.resolve` carries one wire-format DNS query in the XPC `payload` field
  within protocol 3; it takes no host, port, path or other argument. The daemon
  accepts only a one-question standard query, forwards it to the fixed core DNS
  endpoint from `daemon.json` (`127.0.0.1:1153`), and returns only an answer
  that matches the query's ID, question and opcode. At most 128 queries are in
  flight; extras fail at once with `dns_busy` instead of queueing. Each query
  has a 4000 ms deadline, runs on a private event loop, and never takes the
  daemon's lifecycle lock, so DNS load cannot block lifecycle transactions.
  Queries and answers are never logged, and `dns.resolve` is excluded from the
  routine audit log. The extension holds one shared connection whose peer
  requirement is the release certificate family, waits at most 6 seconds, and
  fails closed: on any error, timeout or rejection the application gets no
  answer. There is no system-resolver or public fallback. An older daemon
  rejects the operation, which the extension treats the same way.
- Local DoH (LocalHttpDns) is retired. The daemon no longer runs a TLS server,
  listens on `127.0.0.1:443`, generates a local CA or server key, writes a
  configuration profile, requests certificate trust, or exposes a DNS Unix
  socket; the `local-doh.*` and `runtime.set-dns-mode` operations no longer
  exist. At each start the daemon removes the artifacts earlier releases left
  behind, using fixed commands only: `profiles show`/`profiles remove` for the
  fixed identifier `dev.linsheng.mihomobox.local-doh`, then
  `security remove-trusted-cert -d` and
  `security delete-certificate -Z <sha1> /Library/Keychains/System.keychain`.
  It reads certificate and fingerprint inputs only from root-owned regular
  files of at most 64 KB at fixed paths, deletes only the fixed `local-doh/`,
  prepared `.mobileconfig` and `mihomo-data/.dns-ipc` paths, and never unlocks
  a keychain, edits `authorizationdb`, or prompts for authorization. Its single
  `event=legacy_local_doh_cleanup` log line carries only fixed status words,
  nothing from profile or certificate contents. Uninstall repeats the profile
  and trust removal as a fallback.
- A signed legacy protocol response is not permission to downgrade the App's
  XPC requests. An older version is classified only from the authenticated response
  envelope, never from a marker file or error string. The tray disables all
  incompatible mutations and requires the user to select the exact-CDHash
  verified installer; polling and component synchronization cannot open an
  administrator prompt. An already-open dashboard request still fails at the
  typed version-3 boundary and cannot mutate or elevate. A peer newer than the
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
- App Proxy system extension: sandboxed NetworkExtension provider; on the
  daemon's control service it may call only `dns.resolve`.

The daemon answers `dns.resolve` by querying the core's DNS listener but does
not own the Mihomo child. The agent never accepts Desktop/CLI requests. Typed
XPC actions remain the only unprivileged entry into network and profile
mutations.

## Supply Chain

- MetaCubeXD uses a pinned tag as the native UI's design reference; no upstream
  JavaScript executes in the App.
- Mihomo uses a pinned release and SHA-256.
- SwiftPM lockfiles pin the native dependency graph. The pinned Sparkle binary
  artifact is additionally protected by SwiftPM's recorded checksum.
- Daemon, agent, CLI, and Desktop in any one release use one Developer ID
  certificate. Starting with 0.9.3, their exact Xcode Cloud notarized and
  ticket-attached App ZIP is the update artifact. During the bounded 0.9.1
  Xcode Cloud migration, peer policy is
  the exact union of the published leaf and the observed Cloud leaf; it never
  falls back to Team ID. The old-signed bridge is not releasable until both
  fingerprints are source-pinned.
- Automatic App updates require Sparkle EdDSA verification and the Developer
  ID/notarized release chain. Signed appcasts prevent feed-field substitution.
  The Sparkle private key never ships in the App or repository. During the 0.7
  migration window, the release-only legacy archive is separately signed with
  the existing minisign-compatible key; that key also never ships.
- Root component updates add a second check at the privilege boundary: each
  executable must satisfy the already-installed daemon's certificate
  requirement before it can replace a root-owned binary.
- Third-party license notices ship with the application. swift-nio-ssl is no
  longer a dependency, so its LICENSE and NOTICE are no longer bundled.

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

- Legacy original DNS is restored once during protocol-3 migration; its backup
  and compare-before-write guarantees are retained for uninstall/recovery.
- Pre-existing `127.0.0.53` aliases are not removed by legacy cleanup.
- Original-DNS sockets bind to the physical interface to avoid TUN recursion.
- Global DNS is owned only together with Enhanced TUN (`manageSystemDNS`,
  `globalDNSFallbackEnabled` and `enhancedTUNEnabled` stay equal). It is applied
  only after Enhanced TUN and DNS validate, and original DNS is restored when
  TUN is turned off or that path fails. TUN-off standby leaves system DNS
  untouched.
- The retired Local DoH profile is removed at daemon start and again before
  TUN is enabled while its absence is unconfirmed; removal that macOS does not
  confirm is reported as `profile=removal_required`, never as success.
- A stale PID is terminated only after executable-path verification.
- Profile reload is serialized by the daemon and rolls back configuration and
  agent state together on failure.
- The daemon writes an exact-path-verified `mihomo-agent.pid`; a restarted
  daemon harvests an orphan before launching another agent, and each agent also
  watches its daemon parent PID so a daemon crash triggers DNS restoration and
  self-termination.
- Repeated child failures use bounded exponential backoff and open a circuit
  after six short-lived failures instead of looping indefinitely.

## App Proxy code access

[Claude CLI identity and authorization](claude-app-proxy-identity.md) documents
the v5 trust boundary and its unverified deployment gates. A per-user sandboxed
XPC broker, with read-only exceptions for the home directory, `/opt/homebrew/` and
`/usr/local/`, stores the folders the user approved and delegates ephemeral
read-only folder capabilities. Writable, linked and broad folders (a whole home,
Library, Documents, Desktop, Downloads or system prefix) are refused. Both XPC peers
check the exact signing leaf and bundle ID; the broker also checks the caller UID.
The root provider opens every granted folder read-only before rule publication and
admits a flow only when its running code carries a listed signing identifier, is
signed by that identifier's listed Team ID and passes `SecCodeCheckValidity`; it
holds no file exception and keeps console-owner leases. Trust is the publisher:
later versions need no approval, unsigned and ad-hoc code is never routed, and a new
Team ID or identifier needs a policy edit. Same-UID and separate root sandbox fixture
success are not evidence that real NetworkExtension or Claude end-to-end behavior
has been validated.

In 1.1.2, renewal of a previously loaded generation is independent of preference
I/O. This cannot publish new rules: policy changes still require fresh stored
configuration readback, and every renewal verifies the console owner, current
generation, active session and unchanged 90-second lease.
A configuration-read timeout cannot itself authorize a new generation. An OS
request that has timed out remains single-flight until its actual completion.
