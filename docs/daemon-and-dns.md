# Daemon and DNS

## Responsibilities

`mihomo-agent` combines the Mihomo runtime responsibilities so ownership never
splits while moving between standby and Enhanced TUN:

- supervise exactly one bundled Mihomo process and restart it after failure;
- keep the original-DNS escape bound to the current physical/scoped resolver;
- observe controller, DNS and route health; own macOS DNS only while Enhanced
  TUN is on.

The agent records the Mihomo child PID. A later agent instance validates the PID's
executable path with `proc_pidpath` before terminating a stale owned process;
it never kills an unrelated process merely because a PID file exists.

`mihomo-daemon` binds no DNS listener. It answers App Proxy DNS queries over
XPC ([App Proxy DNS](#app-proxy-dns)) and removes what the retired Local DoH
feature installed ([Legacy Local DoH cleanup](#legacy-local-doh-cleanup)).

## DNS ownership

macOS Global DNS is owned together with Enhanced TUN ("TUN-only"). There are
two valid states:

| State | macOS DNS | Mihomo DNS |
|---|---|---|
| Enhanced TUN on | PrimaryService DNS set to the `127.0.0.53:53` bridge | Fake-IP, TUN route `198.18.0.0/16` |
| Standby (TUN off) | untouched | real-IP filter; stays up for App Proxy |

`manageSystemDNS`, `globalDNSFallbackEnabled` and `enhancedTUNEnabled` in
`daemon.json` are always equal. `DNSOwnershipStore` writes them together, and
`ProxyConfiguration.load()` normalizes the two DNS keys from an explicit
`enhancedTUNEnabled`. Validation rejects mixed ownership and Global DNS with
TUN disabled: Fake-IP answers without the tunnel are unroutable, and a tunnel
without the bridge leaves applications on real answers that bypass the Fake-IP
rules. The key name `globalDNSFallbackEnabled` is historical; there is no
separate DNS mode in the App, CLI or control protocol.

With TUN on, the agent sets the PrimaryService DNS to the `127.0.0.53:53`
bridge, which forwards to Mihomo DNS on `127.0.0.1:1153`. macOS's effective
resolver then shows `198.18.0.1`. With TUN off, all three keys are false, the
system DNS list is left alone, and Mihomo keeps serving the App Proxy.

Installing the root helper creates a valid Mihomo standby runtime with TUN
disabled. Enabling Enhanced TUN is an explicit user action and takes Global DNS
in the same validated transaction.

Standby health permits another VPN to own the Fake-IP destination route: the
managed core has TUN disabled and answers with real addresses. Enhanced TUN
still requires a route owned by this runtime; a preexisting VPN route cannot
satisfy that check. This allows installation and updates while another VPN is
active without changing that VPN's routes.

```text
Enhanced TUN:   macOS PrimaryService DNS -> 127.0.0.53:53 (agent UDP/TCP bridge)
                                         -> 127.0.0.1:1153 (Mihomo, Fake-IP)
App Proxy DNS:  extension -> XPC dns.resolve -> mihomo-daemon -> 127.0.0.1:1153

Mihomo -> 127.0.0.1:1054 -> scoped or PrimaryService DHCP DNS
```

The daemon's `validateStartedRuntime` commits a started or switched runtime
only after a fresh, generation-bound agent health snapshot matches the
persisted owner. When Global DNS is owned it requires `system_dns_managed` and
`dns_bridge_ready`; otherwise it requires that the agent neither manages nor
reports managed system DNS. Controller, Mihomo DNS, network consistency and the
expected TUN/route state are required in both states.

The separate `1054` listener is mandatory. Pointing Mihomo at macOS `system`
DNS could recurse back through the managed `127.0.0.53` bridge. The configurator forces
`dns.respect-rules: false`, so Mihomo never routes its loopback `1054` upstream
through a proxy rule and accidentally breaks this recursion boundary. Mihomo
uses the agent's TCP `1054` listener for its upstream requests so Enhanced TUN
cannot recapture a UDP loopback flow emitted by Mihomo itself.

The `1054` listeners are supervised like the bridge's
([Global DNS bridge](#global-dns-bridge)), but rebind themselves: `127.0.0.1`
never goes away, and a plain forwarder has no consistency observer. An
unexpected close of either transport, for example after SwiftNIO closes the UDP
listener on an `ENOBUFS` reply, is logged as `dns_escape_listener_closed
protocol=udp|tcp` and rebound after 0.1 s, retrying after 1, 5 and then every
30 s (`dns_escape_listener_rebound`, or `dns_escape_listener_rebind_failed`
once per distinct error). The UDP escape matters even though Mihomo uses TCP:
the proxy-server address resolver queries it, and falls back to the system
resolver, which answers from Fake-IP while the agent owns system DNS.

The bridge forwarders and the original-DNS escape use non-blocking SwiftNIO
clients. Truncated UDP replies on the original-DNS escape continue
asynchronously over TCP on the same selected endpoint and interface.

The port-53 bridge is bound only while Enhanced TUN owns system DNS. It
forwards to Mihomo DNS once the runtime is ready. Before that, or when Mihomo
does not answer, it applies its Fake-IP fail-closed policy: only names the
managed Fake-IP filter excludes may resolve through the current network's DNS;
other names fail. The original-DNS path follows DHCP/service DNS changes,
binds to the selected network interface, excludes loopback and Fake-IP resolver
addresses, and never uses the macOS default resolver API or invented public DNS
servers. In TUN-off standby, the managed configuration uses
`fake-ip-filter-mode: rule` with `MATCH,real-ip` (not the single-label `*`
wildcard) so Mihomo returns real addresses. Enabling TUN restores the protected
source profile’s Fake-IP policy through the resident core.

The core's own listener is probed directly with an exact DNS STATUS wire
message. The pinned Mihomo UDP server rejects this opcode locally with NOTIMP;
readiness verifies the response identifier, opcode and error without querying
an external resolver. This probe is never sent to port 53. The Global DNS
bridge uses a standard query instead ([DNS Proxy providers](#dns-proxy-providers-mtta)).
Both prove local transport liveness, not external resolution: controller, route
and DNS ownership checks remain required, while external reachability
diagnostics run independently. Native core tests verify this behavior with an
unresponsive upstream in both Fake-IP and real-IP modes.

Managed fake-IP responses use a one-second TTL. This limits stale mappings
after a profile, TUN, or resolver transition; rollback and shutdown also flush
Mihomo's fake-IP and DNS caches.

## Split DNS and interface scope

`NetworkDNSState` tracks every active `State:/Network/Service/*/DNS` resolver.
For resolvers with `SupplementalMatchDomains`, the original-DNS forwarder uses
longest-suffix matching, then `SupplementalMatchOrders`, and binds its TCP/UDP
socket to that service's IPv4/IPv6 interface. Queries without a matching domain
use the DHCP DNS servers and interface of `PrimaryService`.

A root (`.`) scoped resolver is intentionally not selected as split DNS. Once a
query reaches the loopback bridge, macOS no longer supplies the originating
application/interface scope, so choosing a non-primary root resolver would be
ambiguous. Domain-scoped VPN and enterprise resolvers remain deterministic.

## TUN transitions

`runtime.set-tun` is a persistent transition between the two valid agent
states. Standby retains the controller and Mihomo DNS with TUN interception,
the Fake-IP route and system DNS ownership absent. Enhanced mode takes Global
DNS through the bridge and the owned TUN route, and commits only after the
validation above. If boot has not confirmed the legacy Local DoH profile
absent, enabling TUN first re-runs the cleanup. Disabling Enhanced TUN restores
the original system DNS before the core returns to standby.

TUN switches now retain the same agent and Mihomo process. The daemon changes
only TUN/DNS policy in the installed managed profile, restoring the protected
source's Fake-IP filters or the standby real-IP filter as needed. It does not
resolve proxy hostnames, rebuild App Proxy providers, or launch `mihomo -t` on
each switch. Full rendering and standalone validation remain on import,
activation and cold start. The resident core parses the candidate before
applying it; rejection still takes the verified rollback path.
The daemon then sends a one-shot resident
transition request with a fresh health generation. The agent quiesces the old
observer, restores and verifies any owned Global DNS before withdrawing TUN routes, and
applies the profile through the root-only controller using `PUT /configs?force=false`.
The original-DNS escape stays bound; the mixed proxy listener and unchanged
App Proxy listeners remain in the core. The Global DNS bridge is bound only
while Enhanced TUN owns system DNS. A new observer verifies the requested
TUN/DNS state before the daemon commits. Directory change notifications wake the
daemon when the agent atomically publishes its snapshot. Notifications are only
hints: the daemon still validates the generation and complete health. Bounded
polling (10 ms initially, backing off to 50 and 250 ms) handles missed/coalesced
notifications; it never substitutes an optimistic UI state for readiness.
Fixed phase names and monotonic millisecond timings identify preparation,
observer quiescence, route withdrawal, application, both cache flushes and
confirmation costs without recording configuration contents. Final GLOBAL and
App Proxy route validation shares one authenticated controller snapshot under
the daemon mutation lock.
Proxy-server loop diagnostics run on a separate serial worker and are cancelled
between DNS queries when the runtime changes. Their external DNS latency never
blocks health publication or shutdown, and old-generation findings are discarded.
System DNS cache-flush commands still finish before readiness, using process-exit
notifications instead of Foundation's run-loop polling delay.
Legacy Local DoH cleanup runs fixed system commands with a bounded wait. The LaunchDaemon uses the
`Standard` process class: `Background` is inappropriate for the user-requested
network data path and delays interactive work under load. Agent lifecycle
signals and synchronous inspection/cache-flush children use user-initiated QoS;
periodic external diagnostics retain their utility workers.
Route ownership still excludes any
preexisting VPN interface. Failed live transitions use the existing verified
stop/restore and protected-file rollback path.

The daemon precreates a fresh kernel-assigned utun and retains its primary
file descriptor across agent and Mihomo restarts. The signed agent passes an
explicit duplicate through stdin to its fixed exec-only launcher, which moves
it to descriptor 3 and execs the fixed managed Mihomo binary. No shell, arbitrary
path or GUI descriptor transport is involved. The mode-0600 owner record is
accepted only while its root daemon PID still resolves to the managed executable.

On cold start Mihomo parses the configuration with its listener disabled. The
agent reads those parsed addresses, configures the precreated interface without
traffic routes, then attaches Mihomo through `tun.file-descriptor`. Mixed/system
stacks require the local addresses before binding. Routine off/on keeps this
listener, addresses, fd and interface identity alive; only interception routes
and real/Fake-IP DNS policy change. Full stop removes addresses and routes while
the daemon keeps the inactive interface. Child death triggers the same cleanup;
a stale controller response cannot re-enable routes for a replaced/dead child.
Verified service stop removes the internal descriptor/device fields from the
managed YAML and restores the requested TUN enable value. This keeps signed
component rollback compatible with older daemons that create their own TUN.

Route writes use acknowledged Darwin routing sockets and preserve configured
prefix exclusions. An existing conflicting route causes rollback; it is never
replaced. Cleanup derives the interface from the actual owned descriptor and
filters its route index. Effective TUN health and public controller snapshots
require the probe route on this exact interface, rather than mere interface
existence or the permanently enabled internal listener. Descriptor details stay
inside the privileged boundary. General IPv6 preferences are restored after
reload without changing the attached listener’s startup address identity.
The cached route-query socket drains stale broadcasts before sending each
request. Otherwise a full receive buffer can discard the new reply, introduce
a false 200 ms timeout, and delay confirmation until the next observer tick.
The privileged regression test saturates that buffer with real route events.

DNS policy changes with TUN: standby returns real addresses, Enhanced mode
restores the source Fake-IP policy, and DNS caches are flushed after application.
The live routing mode and supported general scalar settings are retained across
this transition. TUN does not change System Proxy preferences or the App Proxy
extension's activation state. Profile import/switch, explicit restart, component
updates, uninstall and failed recovery may still replace the process.

The pinned core's [configuration endpoint](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/hub/route/configs.go)
and [listener reconciliation](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/listener/listener.go)
are the contract for this non-forced reload. The native integration test verifies
PID continuity, existing and new mixed/App Proxy TCP streams, real/Fake-IP DNS
transitions, routing-mode retention and rejection of malformed configuration
using isolated loopback sockets. It leaves TUN disabled; real route teardown,
Global DNS restoration and NetworkExtension coexistence still require signed
machine acceptance before release.
The opt-in `DaemonOwnedTUNTests` root acceptance additionally exercises real
IPv4/IPv6 interface configuration, inherited-descriptor packet delivery, two
core lifetimes, repeated route switches, foreign-route conflicts and cleanup.
It uses only benchmark/documentation prefixes and never changes default routes
or system DNS. Run the built core XCTest bundle with
`MIHOMO_PRIVILEGED_TUN_TESTS=1` explicitly under root.

`enhancedTUNResumeEnabled` remembers the last explicit TUN choice. Turning TUN
off persists standby across daemon restarts, component updates and App launches.
Migration uses the old current TUN state and ignores the legacy sticky
`enhancedTUNPreviouslyEnabled` history. A temporary base-service migration keeps
the new resume preference separate from the runtime state. When enabled, startup
uses the same validated Global DNS + TUN transaction. `daemon.json` still
decodes an old `localDoH` key and drops it on the next write; on upgrade, DNS
ownership is normalized from the last saved TUN choice.

### Global DNS bridge

Enhanced TUN persists `enhancedTUNEnabled`, `manageSystemDNS` and
`globalDNSFallbackEnabled` as `true`; standby persists all three as `false`.
Starting with 1.1.2:

```text
macOS Global DNS -> 127.0.0.53:53 (agent UDP/TCP bridge) -> 127.0.0.1:1153 (Mihomo)
Mihomo upstream -> 127.0.0.1:1054 -> physical/scoped DNS
```

The agent owns the loopback alias and independent DNS listeners. The bridge
survives child reloads and uses the original-DNS fallback policy above while
the core recovers. The owned TUN route remains required for Fake-IP traffic.
`dns_bridge_ready` checks the loopback bridge in this state. An isolated bridge
probe failure does not restore/reapply DNS or restart a healthy kernel. Three
observer timer failures restore owned DNS; acquisition then backs off. Network
configuration notifications do not advance failure counters.

The bridge's UDP and TCP listeners are supervised. SwiftNIO closes a datagram
channel after any send error other than `EMSGSIZE` or `EHOSTUNREACH`, without
an `errorCaught` callback, while the kernel keeps an idle socket bound to the
alias across its removal and re-addition. Previously a rollback removed the
alias under in-flight queries; each pending reply then failed with
`EADDRNOTAVAIL`, the UDP listener closed silently, the TCP listener survived,
and nothing rebound UDP until the agent restarted. Under MTTA the bridge probe
was still answered (MTTA's SERVFAIL for the unreachable bridge), so the
observer kept pointing system DNS at a bridge with no UDP listener (m4pro,
2026-11-09). Now:

- an unexpected listener close is logged as `dns_bridge_listener_closed
  protocol=udp|tcp` and triggers an immediate evaluation; the first failed UDP
  reply of a channel is logged as `udp_listener_write_failed
  listener=bridge|escape` with its errno;
- every evaluation rebinds a closed listener while the alias is present
  (`dns_bridge_listener_rebound`, or `dns_bridge_listener_rebind_failed` once
  per distinct error);
- `dns_bridge_ready` also requires both agent listeners to be open, so a probe
  answered by an intercepting DNS Proxy cannot stand in for the bridge;
- acquisition ensures the alias, then both listeners, then probes, and writes
  system DNS only if all succeed;
- `dns_bridge_unhealthy` restores system DNS and then rebuilds both listeners
  (`dns_bridge_listeners_rebuilt`), since flipping DNS alone repairs nothing.

The prior TUN address `198.18.0.2:53` remained intermittently unavailable on
m4pro with DNS Proxy extensions, while loopback Mihomo DNS answered normally.
Restoring Global DNS on each missed probe caused a restore/acquire notification
loop. The system resolver no longer depends on that TUN address. App Proxy keeps
its separate, service-scoped DNS configuration and sends captured DNS to the
daemon ([App Proxy DNS](#app-proxy-dns)). Its resolver is never adopted as
Global DNS ownership.
While Global DNS is owned, upgrade restoration recognizes exact unscoped
`198.18.0.1`, `198.18.0.2`, and `127.0.0.53` dictionaries, preserves original
backups and unrelated settings, and excludes ServiceIdentifier-bearing and mixed
resolver dictionaries. Only the loopback address satisfies applied-state checks.
Before downgrading to a release using TUN DNS, stop through the current signed
control entry point to restore its owned loopback resolver first.

The Global DNS + TUN state survives daemon restart. Disabling TUN restores
system DNS and enters controller/DNS standby, so App Proxy keeps using the
core's resolver without a TUN route. Privileged fault-injection acceptance must
use a locally signed release build.

### DNS Proxy providers (MTTA)

A DNS Proxy provider (`NEDNSProxyProvider`) can intercept every port-53 flow,
loopback included. The corporate MTTA provider (`com.sankuai.sec.mtta.dns`)
forwards standard QUERY-opcode UDP queries, rewriting the transaction ID and
mapping it back, but drops STATUS-opcode queries, and TCP DNS to loopback
through it fails. The earlier bridge readiness probe sent a STATUS query to
`127.0.0.53:53`, so under MTTA `dns_bridge_ready` stayed false, Global DNS
validation timed out and the TUN transition rolled back.

The bridge probe is a standard QUERY for type A `mihomobox-health.invalid` with
a random transaction ID. Any well-formed, untruncated response to that question
with the probe's ID and the QUERY opcode counts as ready, whatever its answer
or RCODE. MTTA answers SERVFAIL when nothing listens behind it, so the probe
counts only while the agent's own UDP and TCP bridge listeners are open
([Global DNS bridge](#global-dns-bridge)). The bridge recognizes the health
name without relying on the transaction ID, which an intermediary may rewrite
in transit. The health name bypasses the bridge's readiness gate and is never
sent through the original-DNS fallback to the network's resolvers.

Known limitation: because TCP DNS to loopback through MTTA fails, a truncated
Global DNS answer cannot be retried over TCP while MTTA is active. App Proxy
DNS does not cross port 53 and is not affected.

### Legacy DNS restoration

The SystemConfiguration code below manages `127.0.0.53` and restores historical
TUN DNS addresses during upgrades. Startup restores recorded DNS with
the old configuration before changing ownership. The agent reads `CurrentSet`,
then manages:

```text
<CurrentSet>/Network/Service/<PrimaryService>/DNS
```

It uses `SCPreferencesPathGetValue` and `SCPreferencesPathSetValue`, followed by
`SCPreferencesCommitChanges` and `SCPreferencesApplyChanges`. On current macOS,
the effective resolver is published through the current PrimaryService's
`State:/Network/Service/<id>/DNS` dictionary. A Global dynamic dictionary alone
does not enter `scutil --dns`. Global DNS is used only as a compatibility
fallback when PrimaryService cannot be resolved. Before the first write for
each active set or primary service, the daemon stores the prior dictionary in a
binary plist.

Restoration is compare-before-write: an entry is restored only while its
current `ServerAddresses` still equals the daemon-managed value. An external
administrator change therefore wins and is never overwritten by uninstall.
If the backup is absent after a crash or migration, restoration enumerates the
Global dictionary and every service DNS dictionary in the current set. It
removes only an exact managed `ServerAddresses` value and preserves search
domains and every other DNS key; mixed or externally changed address lists are
left untouched. The same exact-value cleanup covers all live Global/scoped
dynamic DNS dictionaries.
Restore operations are retried three times with bounded delay and are accepted
only after the managed persistent/dynamic DNS state and ownership backup are
gone.

Daemon lifecycle and component-update stops also allow a bounded six-second
quiescence window after the agent exits. During that window they inspect fresh
controller, TUN, Fake-IP route, DNS-listener, and persistent/effective system
DNS state every 250 milliseconds. A timeout remains fail-closed and records
only fixed blocker names; it never logs resolver addresses or profile data.

## App Proxy DNS

When the App Proxy extension (signing identifier
`dev.linsheng.mihomo-app.app-proxy`) captures DNS for a policy-matched app, it
does not open a socket to the core. It sends the raw query to the root daemon
over the privileged Mach service `dev.linsheng.mihomo.daemon.control` as the
control operation `dns.resolve`. The protocol version is unchanged (3); the
query bytes travel in the XPC `payload` field and the answer returns in
`payload`.

```text
extension -> XPC dns.resolve -> mihomo-daemon -> UDP 127.0.0.1:1153 (TCP on truncation) -> Mihomo
```

Extension side:

- one shared connection, replaced after invalidation, with a peer code-signing
  requirement for the release certificate family;
- a 6-second client timeout per query;
- fail closed: an error, timeout or mismatched answer returns no answer, with
  no system-resolver or public fallback;
- the sandbox entitlement adds
  `com.apple.security.temporary-exception.mach-lookup.global-name` =
  [`dev.linsheng.mihomo.daemon.control`].

Daemon side:

- each XPC connection's role is classified once, from its first message, with
  `SecCodeCreateWithXPCMessage` and `SecCodeCheckValidity` against a
  requirement of identifier `dev.linsheng.mihomo-app.app-proxy` plus the
  certificate family. The extension role may call only `dns.resolve`, and
  `dns.resolve` is permitted only for that role (`AppProxyDNSPolicy.permits`).
  A refused call logs the operation and role only;
- only a standard QUERY with exactly one question is accepted
  (`isAcceptableQuery`);
- `AppProxyDNSResolver` (SwiftNIO) resolves asynchronously against
  `mihomoDNS` from `daemon.json` (`127.0.0.1:1153`), over UDP and over TCP when
  the answer is truncated. It runs outside the daemon's lifecycle
  `mutationLock`, allows at most 128 queries in flight (a query over the limit
  fails immediately as busy instead of queueing), and has a 4,000 ms timeout;
- an answer is returned only if it carries the query's transaction ID and
  opcode with the response bit set (`isMatchingResponse`). Negative answers
  are returned unchanged;
- errors return as `dns_invalidQuery`, `dns_busy`, `dns_invalidResponse` or
  `dns_unavailable`;
- nothing is logged per query; `dns.resolve` is excluded from the request
  audit log.

Port 1153 is not port 53, so DNS Proxy providers such as MTTA do not intercept
this path. Answers share the core's DNS policy and cache in both standby and
Enhanced TUN; per-application node selection applies to connections. An older
daemon rejects `dns.resolve`, and the extension then fails closed. The probe
build of the extension (without `MAIN_APP_PROXY`) still sends DNS over TCP to
`127.0.0.1:1153`.

Not yet verified on a device:

- whether per-app DNS from `NEDNSSettings` reaches the App Proxy while MTTA's
  DNS Proxy is active;
- whether the `mach-lookup` temporary exception is honored for the sandboxed
  system extension;
- the truncated-answer TCP retry limitation of the Global DNS bridge under
  MTTA ([DNS Proxy providers](#dns-proxy-providers-mtta)).

## Legacy Local DoH cleanup

Local DoH (LocalHttpDns) is removed. It ran a loopback HTTPS DoH server on
`127.0.0.1:443` in the daemon and installed a split-DNS configuration profile
`dev.linsheng.mihomobox.local-doh` that sent matched domains to
`https://127.0.0.1/dns-query`. Left installed, that profile would keep pointing
those domains at a listener that no longer exists, in either TUN state. There
is no TLS server, no `local-doh.*` or `runtime.set-dns-mode` operation (they no
longer decode), and no DNS-mode setting.

At boot, after restoring recorded DNS with the persisted owner and before
normalizing `daemon.json`, the daemon runs `LegacyLocalDoHCleanup`
(constants in `LegacyLocalDoH`). It is idempotent and uses fixed commands and
paths only:

1. `/usr/bin/profiles show -type configuration -identifier
   dev.linsheng.mihomobox.local-doh -output stdout-xml`; if the profile is
   present, `profiles remove ... -forced`, then the same check again to
   confirm absence;
2. trust anchor removal: `security remove-trusted-cert -d` on a root-owned
   regular `ca.crt` or `server.crt` of at most 64 KB, and
   `security delete-certificate -Z <stored SHA-1>` from the System keychain;
3. deletion of `local-doh/`, `MihomoBox-Local-DoH.mobileconfig` and
   `mihomo-data/.dns-ipc` under `/Library/Application Support/Mihomo App/`;
4. a DNS cache flush when it removed the profile.

When it finds anything, or cannot determine the profile state, it logs one line:

```text
event=legacy_local_doh_cleanup profile=<absent|removed|removal_required|unknown> trust=<absent|removed|partially_removed> files=<absent|removed|failed>
```

Nothing from profile or certificate contents is logged. Status exposes
`legacy_local_doh_profile_removed`, true once a run confirmed the profile
absent. Turning Enhanced TUN on re-runs the cleanup when that is not yet
confirmed. The installer's uninstall (`restore`) still removes the profile and
trust anchor as a fallback.

## Loopback Alias

`127.0.0.53` is added to `lo0` through `SIOCAIFADDR` only when absent. A marker
is written only after this agent creates the alias. Restore removes the alias
only when that marker exists; a pre-existing administrator-owned alias remains.

A rollback while the agent keeps running (DNS apply failure, bridge or runtime
unhealthy) restores system DNS but keeps the alias as long as the agent's
bridge listeners are bound to it: nothing resolves through it once DNS is
restored, and removing it under the listeners closed the UDP listener (see
[Global DNS bridge](#global-dns-bridge)). Agent stop and a resident transition
still remove the marked alias.

## Network Changes

Three independent signals drive network revalidation:

- `SCPreferences` commit/apply callbacks watch persistent `Setup:` changes;
- `SCDynamicStore` watches effective global and per-service IPv4/IPv6/DNS
  state;
- a dedicated non-blocking `PF_ROUTE/SOCK_RAW` socket watches `RTM_ADD`,
  `RTM_DELETE`, `RTM_CHANGE`, address add/delete, and interface up/down
  messages from the kernel.

The route monitor owns a separate descriptor from the route-lookup socket so
broadcasts cannot consume lookup replies. It drains a burst into fixed
route/address/interface bits and never parses or logs destinations, gateways,
interface addresses, or profile data. `RTM_GET`, misses, multicast membership,
and other lookup noise are ignored. A failed descriptor is reopened with a
1-to-30-second bounded backoff while the two-second consistency observer
remains available.

On a System Configuration change the daemon synchronizes the observer session
and then:

1. resolves PrimaryService and PrimaryInterface;
2. reads DHCP option 6 before service DNS state;
3. builds domain-scoped resolver routes from `SupplementalMatchDomains`;
4. excludes loopback, fake-IP, and managed runtime endpoints;
5. binds original-DNS sockets using `IP_BOUND_IF`/`IPV6_BOUND_IF`;
6. restores an old PrimaryService before managing the new service.

Every persistent, effective, or kernel-route signal invalidates the cached
end-to-end egress result and requests an immediate fresh probe. Bursts are
coalesced before evaluation, and notifications caused by the daemon's own
idempotent DNS apply converge without another write. This follows the same
principle as Surge policy availability caching: a result measured on one
interface must not be reused after the active path changes. Remote-node
availability remains a profile policy-group responsibility (`fallback`,
`url-test`, or compatible Mihomo groups); the agent does not reset a manual
selection or restart the whole runtime for a pure egress failure.

An independent two-second consistency observer detects later controller, TUN,
route and Mihomo-DNS drift. In Enhanced mode it immediately disables Fake-IP
answers and requests recovery only after three consecutive failed observations,
filtering short startup and interface-transition gaps. The sole owned Mihomo
supervisor then allows eight seconds for Mihomo to rebuild the complete
auto-route state. In standby mode, the absence of interception routes is intentional and
does not vote for recovery. While the child restarts, the bridge (when bound)
applies its original-DNS fallback policy and App Proxy `dns.resolve` requests
fail closed.

The Fake-IP route is machine-wide evidence, not ownership proof. The agent
records any tunnel already routing the probe range before it starts Mihomo and
accepts a route only when the controller reports TUN enabled and the visible
interface is the daemon-owned utun. Legacy non-inherited fixtures instead
exclude that pre-existing tunnel. Stopped-state inspection likewise
ignores unrelated utun routes. This prevents another VPN or network extension
from making Mihomo look healthy or from blocking verified shutdown.

Legacy restoration removes only the alias marked as MihomoBox-created and uses
compare-before-write for persistent and effective service DNS. This prevents a
pre-existing alias or administrator change from being removed while clearing
stale `127.0.0.53` values from inactive Wi-Fi, Ethernet or VPN services.

The root daemon authenticates XPC clients and classifies the App Proxy
extension, serializes lifecycle/profile transactions, answers App Proxy
`dns.resolve` outside that serialization, runs the legacy Local DoH cleanup,
and supervises the agent. The daemon owns the primary utun descriptor; the
agent owns its inherited duplicate, route switching, the 1054 original-DNS
escape and, only while Enhanced TUN is on, the `127.0.0.53:53` bridge and the
system DNS list.

Each agent launch receives a daemon-generated runtime generation. The
consistency observer includes that generation in its mode-`0600` atomic health
snapshot. Startup validation waits for a fresh snapshot matching the exact
generation and never repeats active DNS probes on its 250 ms transaction poll;
a snapshot from the previous agent or Mihomo child cannot commit startup.

Reloading the already-active root-owned profile uses a narrower transaction.
The daemon writes a one-shot mode-`0600` request containing a new generation
and wakes the existing agent with `SIGUSR1`. The agent keeps its own 1054
original-DNS escape and any bound Global DNS bridge alive, temporarily closes
its Fake-IP safety gate, and restarts only its owned Mihomo child. The
transaction commits after the new generation reports complete health. A
rejected request, child failure, or validation timeout stops the agent through
the verified stop path, which restores any owned system DNS.

No query name, matched domain, resolver address, service identifier, or wire
message is logged. Only interface names and aggregate resolver/route counts are
audited. DNS listener faults add only a fixed category and, for POSIX failures,
the numeric error code; arbitrary error descriptions are never persisted. DNS
forwarding retains ten-second observation windows, but healthy
traffic is aggregated into one-minute summaries. A primary failure/bypass,
fallback failure, or policy block emits the accumulated counters on the next
ten-second tick so degraded behavior is not hidden by the lower healthy-log
rate.

The consistency observer also records a transition-only `resolver_topology`
event. Global DNS, the current PrimaryService resolver, and every live scoped
resolver are classified as `managed`, `external`, `mixed`, or `missing`, with
only aggregate scoped counts retained. Resolver addresses and service IDs are
never written. This makes a historical `scutil --dns` split between Global and
scoped resolution diagnosable without persisting enterprise DNS details.

Lifecycle, configuration commands, child exits/restarts, network transitions,
drift detection, repair attempts, and repair outcomes are structured audit
events. Startup milestones use a monotonic elapsed-millisecond clock: the
daemon records process, control-service, and initial-runtime readiness, while
the agent records process and complete managed-network readiness. Mihomo
stdout/stderr is never persisted verbatim: only line, byte, and
severity counts are emitted. Normal logs are buffered for up to one second or
64 KiB before writing. Each log file is capped at 100 MiB and retains three
numbered rotated generations. Fatal signals are also synchronously appended to
a separate crash log before the operating system receives the signal.
The first sanitized supervisor start removes legacy raw Mihomo log generations
and writes a mode-`0600` migration marker; later starts preserve aggregate logs.

The daemon's agent supervisor and the agent's Mihomo supervisor restart failed
children with exponential delays from one to thirty seconds. Six consecutive
short-lived failures open a circuit instead of creating a restart storm. An
agent circuit runs the verified stop path, which removes its TUN state and
restores any owned system DNS. A process that remains healthy for sixty seconds
resets the failure sequence.

Tray-state health is passive: it consumes only the agent observer's fresh
snapshot, or the exact safely-stopped result already proved by the restore
transaction. A missing or stale running snapshot is reported as unknown and
never causes the UI polling path to issue DNS or route probes. Explicit
diagnostic `status` remains allowed to inspect live state.
