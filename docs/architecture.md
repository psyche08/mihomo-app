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
├── App Proxy system extension      optional; sends captured DNS as dns.resolve
└── Resources/daemon + scripts      bootstrap installer inputs
              │
              │ authenticated XPC (same signing certificate family;
              │ the extension may call only dns.resolve)
              ▼
/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist (root)
└── mihomo-daemon                   privileged XPC broker and utun owner
    ├── validates every peer's code-signing requirement and role
    ├── owns privileged lifecycle/profile transactions
    ├── precreates and retains the managed utun descriptor
    ├── answers dns.resolve from Mihomo DNS (127.0.0.1:1153)
    ├── removes legacy Local DoH artifacts at boot
    └── launches and monitors exactly one mihomo-agent
              │
              ▼
    mihomo-agent (root worker)
    ├── launches and supervises the pinned Mihomo process
    ├── listens on 127.0.0.1:1054 for Mihomo's original-DNS escape
    ├── with Enhanced TUN on, binds the 127.0.0.53:53 bridge and manages
    │   CurrentSet/Network/Service/<PrimaryService>/DNS
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
standby with TUN off and macOS DNS untouched. Enhanced TUN, which also takes
macOS Global DNS, starts only from an explicit user action.
This avoids both a DIRECT window and user-controlled paths inside root bootstrap.

## Ownership

| Resource | Owner | Reason |
|---|---|---|
| App lifecycle and tray | current-user Swift/AppKit process | app shell must not run as root |
| Main window and dashboard state | in-process SwiftUI module | native UI with no browser bridge |
| App update verification and replacement | embedded pinned Sparkle framework | mature EdDSA and atomic install boundary |
| Desktop/CLI control requests | signed XPC client | no direct privileged or controller access |
| XPC authentication and command authorization | root daemon | one narrow privilege boundary |
| Precreated utun interface and primary descriptor | root daemon | interface survives agent/kernel restart; no GUI-owned TUN |
| Agent lifecycle and profile transactions | root daemon | serialized, rollback-capable mutations |
| Mihomo process, original-DNS escape, network observation | root agent | one runtime owner keeps proxy network state coherent |
| Global DNS bridge and PrimaryService DNS while Enhanced TUN is on | root agent | DNS ownership moves with TUN |
| App Proxy DNS answers (`dns.resolve`) | root daemon | the sandboxed extension opens no DNS socket; port-53 interceptors are not crossed |
| Controller credentials | root runtime boundary | clients receive typed results, never the secret |
| MetaCubeXD reference | pinned source and screenshots, not executable App content | reproducible visual provenance |

The daemon owns the utun capability. Its agent inherits a duplicate,
configures addresses/routes, and passes another duplicate to the sole Mihomo
child. The daemon does not bind any DNS listener or launch Mihomo directly; it
answers App Proxy `dns.resolve` by querying Mihomo DNS on `127.0.0.1:1153`.
Only Enhanced TUN changes the macOS system DNS list.
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
  required release-family identity;
- the daemon classifies each connection once, from its first message, with
  `SecCodeCreateWithXPCMessage` and `SecCodeCheckValidity` against identifier
  `dev.linsheng.mihomo-app.app-proxy` plus the certificate family. That App
  Proxy extension role may call only `dns.resolve`, and `dns.resolve` is
  refused for every other peer (`AppProxyDNSPolicy.permits`).

Requests are typed and versioned. The broker allowlist covers status/snapshot,
agent start-stop-restart, profile import/switch/reload, Enhanced TUN, outbound
mode, proxy selection, latency tests, signed component synchronization, the
native dashboard's validated controller REST and live stream routes, and, for
the App Proxy extension only, `dns.resolve`. The removed `local-doh.*` and
`runtime.set-dns-mode` operations no longer decode. `dns.resolve` carries one
wire-format query in the XPC `payload` field and returns the answer in
`payload`; it runs outside the transaction lock with its own bounds (see
[App Proxy DNS](daemon-and-dns.md#app-proxy-dns)).
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
after an uncached inspection proves the agent/controller and owned TUN interception are gone, system
DNS is unmanaged, and the remaining network state is consistent.

Protocol negotiation also fails closed. A native App that receives an
authenticated response from any older protocol marks that daemon as
reachable but incompatible, disables every runtime/profile mutation, and
offers an explicit verified `Install / Repair Daemon` action. It never retries
the request as version 1 and never sends the older non-transactional component
update operation. A response from a protocol newer than the App instead
requires an App update and disables repair so an older App cannot downgrade a
newer root service. Administrator authorization is therefore user initiated,
not a background consequence of polling or update checks. `dns.resolve` was
added within protocol 3; an older daemon rejects it and the extension fails
closed.

## Startup Sequence

1. launchd starts `mihomo-daemon` and registers its Mach service before login.
2. The daemon restores recorded DNS ownership with the persisted owner, removes
   legacy Local DoH artifacts, then normalizes `daemon.json`: an old `localDoH`
   key is dropped and DNS ownership follows the last saved TUN choice.
3. The agent discovers DHCP/supplemental resolvers, binds the original-DNS
   listener on `127.0.0.1:1054`, and starts Mihomo.
4. Its generation-bound observer commits either controller/DNS standby (TUN,
   Fake-IP route and system DNS ownership absent) or the persisted Enhanced
   state (controller, TUN, Fake-IP route and Mihomo DNS healthy, plus
   `system_dns_managed` and `dns_bridge_ready` for the `127.0.0.53:53` bridge).
   Either state survives reboot.
5. The Swift `NSApplication` starts with accessory activation policy, compares bundled and installed
   component digests through XPC, and synchronizes signed changes when the
   daemon protocol is compatible. An older-protocol reply enters the explicit
   verified repair state described above before any component mutation.
6. The AppKit tray polls runtime state through XPC. The first healthy Enhanced TUN state
   observed from an App in `/Applications` or `~/Applications` applies a
   one-time user-level default to start MihomoBox hidden at login. The root
   LaunchDaemon, rather than this login item, remains responsible for restoring
   the persisted standby or Global DNS + TUN state at system startup.
7. Sparkle checks the signed App update feed. The main `NSWindow` is still absent;
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

After a profile is activated, the daemon-owned core remains resident regardless
of the TUN, System Proxy and App Proxy switches. Routine TUN changes use a
root-only, generation-bound in-process configuration reload, retaining the
agent, original-DNS escape and unchanged proxy listeners. System Proxy controls
macOS proxy preferences; App Proxy controls the user-scoped NetworkExtension.
Neither switch controls the TUN lifecycle. Explicit service stop, uninstall,
component replacement and unprovable recovery retain their safe shutdown paths.

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
| XPC `dev.linsheng.mihomo.daemon.control`, `dns.resolve` only | App Proxy extension → daemon | per-app DNS answered from Mihomo DNS |
| `127.0.0.53:53` UDP/TCP | macOS → agent | Global DNS bridge; bound only while Enhanced TUN is on |
| `127.0.0.1:1153` UDP/TCP | agent bridge / daemon `dns.resolve` → Mihomo | shared Mihomo DNS listener |
| `127.0.0.1:1054` UDP/TCP | Mihomo → agent | nonrecursive path to current DHCP DNS |
| `127.0.0.1:<profile port>` HTTP/WS | agent-local control path | Mihomo controller; never a Desktop/CLI control boundary |

See [daemon-and-dns.md](daemon-and-dns.md) for failure and restoration rules.

## Optional App Proxy extension

The v4 identity and read-only code-access protocol is specified in
[Claude CLI identity and authorization](claude-app-proxy-identity.md), including
evidence limits and mandatory signed-extension acceptance gates. The application
embeds a per-user sandboxed `MihomoCodeAccess.xpc` broker with no network access;
it does not add a privileged daemon filesystem API.

The signed application additionally embeds
`Contents/Library/SystemExtensions/dev.linsheng.mihomo-app.app-proxy.systemextension`.
The AppKit `AppProxyCoordinator` owns user-scoped NetworkExtension preferences
and macOS activation requests. SwiftUI receives only typed service actions;
node configuration still goes through `ControlGateway` and authenticated root
XPC (`app-proxy.status`, `app-proxy.set-routing`). Starting in 1.1.1, master
on/off and cold recovery use the same signed host executable with fixed
`--app-proxy on/off` arguments in a short-lived process. This isolates the
NetworkExtension activation session from GUI polling. It reuses existing
consent, has a 180-second deadline, and performs privileged actions only through
the existing authenticated XPC interface. It cannot install components and does
not create another Mihomo process. Preference callbacks have 60-second deadlines to accommodate macOS assessment during upgrades.

The extension reuses the audited experiment's flow handling and signature
inspection, but `MAIN_APP_PROXY` requires the per-application routing schema
and rejects legacy test sessions. Proxied destinations use the
validated root-core loopback listeners: 17970–17974 for the built-in applications
(17970 JetBrains, 17971 OpenAI, 17973 Anthropic, 17972 and 17974 the legacy CLI
presets), and 17975–18002 for user-selected signed apps and CLI executables. The root
overlay assigns each listener a named sub-rule rather than an unconditional
`proxy` override. Mihomo evaluates Global/Direct before these Rule-mode app
rules. Each app gets a copy of the original ordered rule list and its sub-rules;
only outbound proxy targets are replaced with the app selector. Direct, reject,
pass and DNS adapters, rule-provider references and matching parameters are
retained. An unmatched flow retains the core's default direct route.
Policy-group targets are replaced as a whole, not evaluated for their selected
leaf first. The rule parser follows the pinned core's target positions, including
comma-bearing regex/logic payloads, and rejects YAML structures it cannot
faithfully copy. Hidden single-member selectors preserve arbitrary node names (including
commas) without interpolating them into rule syntax. Existing block-style
proxy groups and sub-rules are retained; the `mihomobox-app-` namespace is
reserved. The app's mode picker uses the shared authenticated mode transaction.
The root
settings schema bounds and validates application IDs, ports and route names;
the extension independently validates the same port mapping. Application paths
are discovery metadata, never root-side filesystem instructions. Unknown identities and unattributable
CLI hosts fail closed. Captured DNS flows go to the root daemon as `dns.resolve`
over one shared XPC connection, which the daemon answers from the shared
Mihomo DNS listener (`127.0.0.1:1153`); the extension opens no DNS socket, so
port-53 DNS Proxy providers do not see these queries. Requests are bounded
(6-second client timeout) and fail closed, with no public DNS fallback or
supplemental default resolver. The extension's sandbox entitlement adds
`com.apple.security.temporary-exception.mach-lookup.global-name` for
`dev.linsheng.mihomo.daemon.control`. The probe build without `MAIN_APP_PROXY`
still uses TCP to `127.0.0.1:1153`. App node selections govern
connections, while DNS policy and cache remain owned by the core;
loopback application callbacks remain explicit local bridges. Numeric addresses
matching the persisted `bypass.cidrs` list also use bounded TCP/UDP bridges and
macOS route selection, so existing private VPN routes take precedence over an
application's proxy node. Identity validation and capacity limits still precede
this decision. There is no direct retry after a proxy error. No controller
credentials or packet logs are added to the UI.

The independent App Proxy page owns the editable application list. Default
entries migrate from the original four-route settings without losing choices.
Changing the list requires disabling the extension first; node-only changes
retain stable ports. Each entry's policy is Team IDs, signing identifiers and code
folders (see `claude-app-proxy-identity.md`, Identifier and Team policy). The App
looks the installed applications up through LaunchServices before enabling, again
within seconds when FSEvents reports a change under a watched location, and every
3 minutes as a fallback. It never hashes or enumerates executables. Path-less rules
match each signing identifier anywhere; the provider then checks the running code
against the Team IDs of the route that lists its identifier. A (Team ID, identifier)
pair belongs to one entry. LoadBalance groups have no current selection; route
validation checks every member recursively.

The policy fields persist through the same typed XPC settings transaction. They are
match metadata, never root-executed paths. Code folders are granted read-only to the
provider by the code-access broker, because macOS validates a diverted process's
code inside the provider sandbox. There is no process-name matching or
parent-process inheritance in the provider: a listed CLI uses its route when
its own application, another selected application, or a listed terminal, editor or
SSH login starts it. Legacy entries decode with the preset's identifiers.

Network bypass defaults cover RFC1918, IPv4 link-local, IPv6 ULA and IPv6
link-local. Users can replace or empty this list on the App Proxy page, including
explicit CIDRs for VPNs using public or CGNAT addresses. The app never exempts
an entire VPN interface or automatically trusts its default route. DNS port 53
continues through the shared resolver before bypass matching. Fake-IP space is
not a local-network bypass; overlapping custom profile ranges are rejected.
The provider's v4 preferences bind validated CIDRs to identity and authorization
generations. Legacy root settings decode with default ranges, but saved v1–v3
VPN preferences require explicit reactivation to enroll read-only code access;
the UI marks this explicitly.
Changing bypass membership requires disabling and re-enabling the extension,
while public node selections continue to update through the root listeners.
This ordering is independent of the Mihomo Rule/Global/Direct mode and survives
profile regeneration because it is stored outside the generated YAML.

Bypassed TCP and UDP connections retain the original flow's `networkInterface`
through `nw_parameters_require_interface`. An unscoped provider-created
connection can select the default physical interface even when the intercepted
flow selected a bridge or private VPN. The native interface object is retained
without converting it to an interface name, interface type or cached index.
A non-loopback bypass with no interface fails closed; it never silently retries
through the default route or the app's remote node. Loopback callbacks and SOCKS
control connections remain unscoped loopback connections. The bounded setup,
stream half-close, cancellation and UDP association behavior is unchanged.
