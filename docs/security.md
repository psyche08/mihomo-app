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
  MetaCubeXD forwarding accepts only the pinned UI's known method/path shapes;
  it strips the dashboard token and injects the root-owned controller secret.
- `mihomo-agent` has no public XPC/Mach service. Only the root daemon may launch
  it from its root-owned stable path.
- MetaCubeXD is immutable local content inside the signed App. It has no shell,
  installer, root filesystem, or direct privileged capability. Native control
  mutations cross the authenticated XPC boundary.
- Bootstrap/repair installation is explicit and uses the macOS administrator
  dialog. Subsequent lifecycle, profile reload, TUN, outbound-mode, and proxy
  operations do not elevate interactively.
- Post-bootstrap binary synchronization is a typed XPC operation, not an
  installer. It accepts exactly daemon, agent, and Mihomo bytes, caps their
  sizes, verifies every staged executable against the current daemon's exact
  leaf certificate, and rolls back on replacement or health-check failure.
- launchd executes stable root-owned copies, never files in a user-writable Git
  checkout or movable App bundle.

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

- MetaCubeXD uses a pinned tag.
- Mihomo uses a pinned release and SHA-256.
- Cargo/npm/pnpm lockfiles pin package dependency graphs.
- Daemon, agent, CLI, Desktop, and DMG use one Developer ID certificate.
- Automatic App updates require both the pinned updater public key and the
  Developer ID/notarized release chain. The updater private key never ships in
  the App or repository.
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
