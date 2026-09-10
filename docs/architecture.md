# Architecture

## Components

```text
MihomoBox.app (current user)
├── Contents/MacOS/mihomo-app       Swift/AppKit lifecycle + tray
├── linked MihomoBoxUI              SwiftUI window + typed controller store
├── embedded Sparkle.framework      signed App update and atomic relaunch
├── current-user login item         starts only the hidden tray App after login
├── linked MihomoControl            signed direct XPC client used by SwiftUI
├── Contents/MacOS/mihomoboxctl     signed XPC client used by CLI
└── Resources/daemon + scripts      bootstrap installer inputs
              │
              │ authenticated XPC (same signing certificate)
              ▼
/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist (root)
└── mihomo-daemon                   privileged XPC broker only
    ├── validates every peer's code-signing requirement
    ├── owns privileged lifecycle/profile transactions
    ├── keeps 127.0.0.1:9443 Local DoH alive independently of TUN
    └── launches and monitors exactly one mihomo-agent
              │
              ▼
    mihomo-agent (root worker)
    ├── launches and supervises the pinned Mihomo process
    ├── listens on 127.0.0.1:1054 for Mihomo's original-DNS escape
    ├── never replaces CurrentSet/Network/Service/*/DNS in normal use
    └── observes DHCP, interface, route, and split-DNS changes
```

The App bundle is the signed installation source. Initial bootstrap and an
explicit repair across an incompatible protocol, plist layout, or certificate
boundary are the only operations that use the macOS administrator dialog. They
copy the daemon, agent, Mihomo, configuration helper, and XPC client to stable
root-owned paths and register the daemon's Mach service. After a compatible
bootstrap, routine Desktop and CLI operations never invoke `sudo`, AppleScript
elevation, or the installer; they use authenticated XPC. Later App releases
synchronize the fixed `mihomo-daemon`, `mihomo-agent`, and `mihomo` component
set through that XPC boundary without modifying the LaunchDaemon plist.

An install without an existing root-owned active-profile marker stages the
bundled REJECT provisioning profile, but the LaunchDaemon starts only its XPC
control plane. After profile activation the agent starts in controller/DNS
standby with TUN off. The App then prepares the LocalHttpDns certificate and
split-DNS profile; only explicit macOS approval makes Enhanced TUN eligible.
This avoids both a DIRECT window and user-controlled paths inside root bootstrap.

## Ownership

| Resource | Owner | Reason |
|---|---|---|
| App lifecycle and tray | current-user Swift/AppKit process | app shell must not run as root |
| Main window and dashboard state | in-process SwiftUI module | native UI with no browser bridge |
| App update verification and replacement | embedded pinned Sparkle framework | mature EdDSA and atomic install boundary |
| Desktop/CLI control requests | signed XPC client | no direct privileged or controller access |
| XPC authentication and command authorization | root daemon | one narrow privilege boundary |
| Agent lifecycle and profile transactions | root daemon | serialized, rollback-capable mutations |
| Mihomo process, original-DNS escape, network observation | root agent | one runtime owner keeps proxy network state coherent |
| LocalHttpDns TLS endpoint and physical-DNS fallback | root daemon | encrypted split DNS survives agent, Mihomo and TUN failure |
| Controller credentials | root runtime boundary | clients receive typed results, never the secret |
| MetaCubeXD reference | pinned source and screenshots, not executable App content | reproducible visual provenance |

The daemon binds only the fixed LocalHttpDns TLS socket and observes physical
DNS for its fallback path. It does not own TUN, port 53, port 1054, or launch
Mihomo directly. No MihomoBox component replaces the macOS system DNS list.
The agent does not accept connections from Desktop or CLI. It is launched only
from the stable root-owned daemon and terminates through the daemon-controlled
safe shutdown path.

## XPC Trust Boundary

The daemon publishes the privileged Mach service
`dev.linsheng.mihomo.daemon.control`. Both sides derive a code-signing
requirement from their own leaf signing certificate and configure libxpc peer
validation before exchanging messages:

- the daemon accepts only clients signed by the exact same leaf certificate;
- Desktop/CLI accept replies only from a daemon signed by that same leaf
  certificate;
- an unsigned, ad-hoc-signed, differently signed, or invalid binary cannot use
  the control service;
- App and CLI signing identifiers may differ; certificate equality is the
  required release-family identity.

Requests are typed and versioned. The broker allowlist covers status/snapshot,
agent start-stop-restart, profile import/switch/reload, Enhanced TUN, outbound
mode, proxy selection, latency tests, signed component synchronization, the
fixed LocalHttpDns status projection and root-side prepare transaction, and the
native dashboard's validated controller REST and live stream routes. LocalHttpDns
preparation reads the authenticated controller state and exact managed
root-owned `GeoSite.dat`, writes one fixed root-owned `.mobileconfig` containing
the generated root-certificate and split-DNS payloads, prepares the fixed
loopback identity without stopping the standby agent, and returns aggregate counts only;
expanded domain names never cross XPC and the root daemon remains online.
Component synchronization
accepts exactly three named binary blobs with fixed size limits, validates each
against the daemon's leaf-certificate requirement, stages and backs up inside
the root-owned support directory, and rolls back the complete set on failure.
Controller proxy requests are checked against a fixed method/path contract.
SwiftUI receives decoded DTOs through a typed gateway; its public API cannot
express controller identity, managed DNS or TUN patches, arbitrary shell,
filesystem, arbitrary request bodies, or arbitrary network endpoints.

All mutating operations share one daemon transaction lock, including requests
from different App/CLI peers. Outbound-mode and proxy-selection transactions
perform before-state capture, controller mutation, readback and rollback inside
that lock and return the verified post-snapshot in the same XPC response. Raw
controller forwarding cannot express mode, TUN, proxy-selector, proxy-provider,
DNS, or controller-identity mutations. A fail-closed stop is successful only
after an uncached inspection proves the agent/controller/TUN are gone, system
DNS is unmanaged, and the remaining network state is consistent.

Protocol negotiation also fails closed. A native App that receives an
authenticated response from any older protocol marks that daemon as
reachable but incompatible, disables every runtime/profile mutation, and
offers an explicit verified `Install / Repair Daemon` action. It never retries
the request as version 1 and never sends the older non-transactional component
update operation. A response from a protocol newer than the App instead
requires an App update and disables repair so an older App cannot downgrade a
newer root service. Administrator authorization is therefore user initiated,
not a background consequence of polling or update checks.

## Startup Sequence

1. launchd starts `mihomo-daemon` and registers its Mach service before login.
2. The daemon atomically migrates any legacy configuration to LocalHttpDns with
   TUN off and restores stale `127.0.0.53` DNS ownership once.
3. When a LocalHttpDns identity exists, it starts `127.0.0.1:9443`; a
   five-second supervisor rebinds after a transient port conflict or listener
   failure.
4. The agent discovers DHCP/supplemental resolvers, binds the original-DNS
   listener on `127.0.0.1:1054`, and starts Mihomo.
5. Its generation-bound observer commits either controller/DNS standby (TUN
   and Fake-IP route absent) or the persisted Enhanced state (controller, TUN,
   Fake-IP route and Mihomo DNS healthy). Neither state writes system DNS.
7. The Swift `NSApplication` starts with accessory activation policy, compares bundled and installed
   component digests through XPC, and synchronizes signed changes when the
   daemon protocol is compatible. An older-protocol reply enters the explicit
   verified repair state described above before any component mutation.
8. The AppKit tray polls runtime state through XPC. The first healthy Enhanced TUN state
   observed from an App in `/Applications` or `~/Applications` applies a
   one-time user-level default to start MihomoBox hidden at login. The root
   LaunchDaemon, rather than this login item, remains responsible for restoring
   LocalHttpDns and the persisted standby/Enhanced state at system startup.
9. Sparkle checks the signed App update feed. The main `NSWindow` is still absent;
   selecting `Show Main Window` creates one `NSHostingController`, starts the
   bounded SwiftUI controller streams, and reuses that window until App exit.
   The hosting controller follows AppKit's resizable content bounds. The last
   non-full-screen frame is restored on the next process launch and constrained
   to a connected display before presentation.

All user-interface control is in one process:

```text
NSMenu / SwiftUI
    → typed Swift control object
    → MihomoControlSession
    → authenticated Mach XPC
```

`DashboardStore`, `ControlGateway`, and the tray coordinator are in-process
types, not services or subprocesses. `mihomoboxctl` remains bundled for explicit
operator use, but the App never spawns it for normal control.

If the agent exits unexpectedly, the daemon restores the single-agent
invariant before relaunch. Requested stop/uninstall paths suppress restart and
wait for the agent's DNS restoration to finish.

When the daemon binary changes, the old authenticated daemon keeps a root-only
pending record and complete signed backup, atomically replaces the fixed set,
then exits after a short grace period. launchd starts the new daemon, which
commits only after full route/TUN/DNS health validation. A failed or interrupted
boot atomically restores the old set and restarts again; the App/CLI sees
`update_pending` until commit and cannot report transient new hashes as
success. Agent or Mihomo-only changes validate before deleting their backup.
Routine compatible component synchronization never opens an administrator
dialog; only the explicit repair boundaries described above do.

## Runtime Endpoints

| Endpoint | Direction | Purpose |
|---|---|---|
| XPC `dev.linsheng.mihomo.daemon.control` | Desktop/CLI → daemon | authenticated control plane |
| `127.0.0.1:9443` HTTPS | macOS → daemon | always-on split DoH with managed-Mihomo then physical-DNS fallback |
| `127.0.0.53:53` UDP/TCP | legacy only | restored during protocol-3 migration; not bound in normal operation |
| `127.0.0.1:1153` UDP/TCP | agent → Mihomo | Mihomo DNS listener |
| `127.0.0.1:1054` UDP/TCP | Mihomo → agent | nonrecursive path to current DHCP DNS |
| `127.0.0.1:<profile port>` HTTP/WS | agent-local control path | Mihomo controller; never a Desktop/CLI control boundary |

See [daemon-and-dns.md](daemon-and-dns.md) for failure and restoration rules.
