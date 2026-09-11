# Daemon and DNS

## Responsibilities

`mihomo-agent` combines the Mihomo runtime responsibilities so ownership never
splits while moving between standby and Enhanced TUN:

- supervise exactly one bundled Mihomo process and restart it after failure;
- keep the original-DNS escape bound to the current physical/scoped resolver;
- observe controller, DNS and route health; own macOS DNS only in fallback.

The agent records the Mihomo child PID. A later agent instance validates the PID's
executable path with `proc_pidpath` before terminating a stale owned process;
it never kills an unrelated process merely because a PID file exists.

## DNS Flow

LocalHttpDns is the default macOS DNS integration. Installing the root
helper creates a valid Mihomo standby runtime with TUN disabled. The user then
prepares and approves one macOS DNS Settings profile before Enhanced TUN can be
enabled:

```text
macOS default DNS -> https://127.0.0.1/dns-query (root daemon, port 443)
                 |-> root-private AF_UNIX /dns-query -> Mihomo DNS packet resolver
                 +-> Mihomo absent/unresponsive -> current physical/scoped DNS

Mihomo -> 127.0.0.1:1054 -> scoped or PrimaryService DHCP DNS
```

The root daemon owns `/dns-query` independently of Mihomo and TUN. It validates
RFC 8484 GET/POST wire messages and uses non-blocking DNS forwarders. The typed
`local-doh.install` operation generates a local root CA plus a host-only server
certificate with the `127.0.0.1` IP SAN, keeps the server private key root-only,
and discards the CA private key after signing. The CA certificate is embedded in
the generated profile; neither the installer nor the headless daemon writes
Keychain trust directly. It never unlocks a keychain. The profile uses a fixed
identifier so regeneration updates the existing settings. Global DNS fallback
removes only that profile; full helper uninstall additionally removes legacy
trust residue and server identity. Mihomo neither binds 443 nor reads that
identity, and its child never inherits
`SAFE_PATHS`.

New profiles omit `SupplementalMatchDomains`, Apple's global/default DNS scope,
and do not depend on controller mode, selector chains, or expanded GeoSite lists.
All domains selected by macOS for this default resolver reach Mihomo. Other VPNs
and explicitly scoped system resolvers still follow macOS resolver precedence.
Existing split-DNS profiles remain valid until the user regenerates and installs
the replacement in **General > Device Management**. Changing proxy rules no
longer requires profile regeneration. Legacy rule/GeoSite planners remain for
compatibility, not as the default profile-generation path.

The IPC endpoint is fixed at
`/Library/Application Support/Mihomo App/mihomo-data/.dns-ipc/mihomo.sock`.
Mihomo v1.19.30 already supports raw DoH on its Unix controller. The parent must
be root-owned mode `0700`: upstream makes the socket `0666` and disables HTTP
authentication on Unix sockets. The daemon checks directory and socket ownership
before each connection. It sends RFC 8484 bytes, not the diagnostic `/dns/query`
JSON endpoint, and returns the response unchanged (including RCODE and Fake-IP).
Requests have a bounded deadline, a 65,535-byte response limit, and at most 128
concurrent IPC connections. No query payload or domain is logged.

Sources: [Apple DNS Settings schema](https://raw.githubusercontent.com/apple/device-management/release/mdm/profiles/com.apple.dnsSettings.managed.yaml),
[Mihomo Unix controller](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/hub/route/server.go),
[Mihomo raw DoH resolver](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/hub/route/doh.go).

The separate `1054` listener is mandatory. Pointing Mihomo at macOS `system`
DNS could recurse back through the installed LocalHttpDns resolver. The configurator forces
`dns.respect-rules: false`, so Mihomo never routes its loopback `1054` upstream
through a proxy rule and accidentally breaks this recursion boundary. Mihomo
uses the agent's TCP `1054` listener for its upstream requests so Enhanced TUN
cannot recapture a UDP loopback flow emitted by Mihomo itself.

The DoH IPC hop and original-DNS escape use non-blocking SwiftNIO clients.
Truncated UDP replies on the original-DNS escape continue asynchronously over
TCP on the same selected endpoint and interface.

The legacy port-53 bridge still retains its Fake-IP fail-closed policy for
one-time migration and rollback compatibility, but it is not bound in normal
LocalHttpDns operation. LocalHttpDns prefers Mihomo IPC. Missing/refused Unix
connections, channel closure, and an IPC response deadline (at most one second)
fall back directly to the current network's DNS. The daemon owns a separate
`NetworkDNSState` observer, so this branch survives an agent stop and follows
DHCP/service DNS changes. It never uses the stopped agent's `1054`, the macOS
default resolver API, or invented public DNS servers. Loopback and Fake-IP
resolver addresses are excluded; outgoing requests bind to the selected network
interface. Every new request tries IPC again, automatically recovering when
Mihomo returns. Valid DNS responses, including NXDOMAIN and SERVFAIL, are never
replaced by fallback. Unsafe socket metadata, malformed IPC responses, HTTP
errors and overload still fail closed. If neither backend answers, HTTP 502 is
returned; keeping the listener alive cannot guarantee an offline upstream. In TUN-off
standby, the managed configuration uses `fake-ip-filter-mode: rule` with
`MATCH,real-ip` (not the single-label `*` wildcard) so Mihomo
returns real addresses. Enabling TUN rebuilds the runtime from the protected
source profile, restoring its Fake-IP policy.

The internal health probe is an exact wire message sent directly to Mihomo DNS;
it never uses original DNS. This lets startup distinguish controller/DNS
standby from Enhanced readiness without depending on the macOS DNS profile.

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

## LocalHttpDns ownership

In LocalHttpDns mode MihomoBox does not replace the system DNS server list. The independent daemon
endpoint remains bound before, during and after agent/TUN transitions. It uses
Mihomo IPC in both standby and Enhanced mode. During a backend stop/restart,
the daemon forwards to current network DNS without fabricating answers. It
starts supervising the prepared listener before agent restoration/boot health
checks, so a failed agent start does not prevent the base DNS service. The
original-DNS `1054` listener, physical-interface binding, route observer, wake
recovery, egress probes, and generation-bound health snapshots remain active.
A five-second daemon supervisor retries `443` after a listener failure. Three
failed recovery attempts trigger Global DNS fallback. Startup bind failure with
a prepared identity and failed preparation transactions also trigger fallback.
An unprepared fresh installation stays in setup/standby. Port 9443 is no longer
bound; only its former fixed configuration is accepted for upgrade migration.

The Config page asks the daemon to prepare the fixed root-owned profile,
identity and independent resolver through the typed `local-doh.install`
transaction, then queries `local-doh.status`. The daemon and standby agent stay
online throughout. It reduces preparation, the fixed system
profile identifier, root-owned server identity, and daemon-listener health to
booleans plus numeric counts. Profile contents, expanded domain names, and
GeoSite entries never cross XPC or enter logs. The UI distinguishes setup,
waiting for macOS profile approval, active LocalHttpDns, and a profile/server
mismatch, and refreshes while Config is visible. The profile carries both the
root certificate and global-DNS payload so macOS applies their trust and DNS
authorization together only after the user approves installation.

Profile installation is not proof of SSL trust: macOS may import the CA with
an SSL-specific `Unspecified` trust setting. The daemon evaluates its current
loopback leaf and CA using native system SSL policy, with network fetching
disabled and without overriding anchors. `certificate_trusted` is separate
from profile matching; an open listener alone no longer means healthy.
The `profiles show` report uses `ProfileIdentifier`/`ProfileItems` and redacts
certificate bytes. Its fixed payload identities and complete DNS settings
must match the validated root-prepared document; raw mobileconfig validation
still requires the exact CA bytes. Every 15 seconds a serialized daemon check
observes installed-profile and trust readiness. A continuous one-minute failure
switches to the existing Global DNS fallback, releases 443, and removes only
the fixed DoH profile after TUN DNS is healthy. No profile/unknown inspection
does not trigger this transition. Config reports SSL trust failure explicitly;
the operator, not the daemon, approves SSL trust in Keychain Access.

`runtime.set-tun` is a persistent transition between two valid agent states.
Standby retains the controller and Mihomo DNS with TUN and the Fake-IP route
absent; Enhanced mode adds TUN only after the installed profile, identity and
443 listener are verified. Disabling Enhanced TUN returns to standby and
never stops LocalHttpDns.

`enhancedTUNPreviouslyEnabled` separately remembers a successful enable. Turning
TUN off changes the current session but preserves that preference. A subsequent
daemon boot or App launch resumes Enhanced mode through the same validated
transaction; missing profile/trust uses the existing verified Global DNS fallback.
Never-enabled installations stay in standby. Migration remembers the old current
TUN value; versions that already recorded it as off have no recoverable history.

### Global DNS fallback

Fallback persists `globalDNSFallbackEnabled: true`, `manageSystemDNS: true`,
`enhancedTUNEnabled: true`, and no `localDoH`. It uses this shorter path:

```text
macOS Global DNS -> 198.18.0.1:53 -> Mihomo TUN DNS
Mihomo upstream -> 127.0.0.1:1054 -> physical/scoped DNS
```

No loopback port-53 bridge or alias is created. The managed profile forces the
matching Fake-IP range, auto-route, and UDP/TCP hijack for `198.18.0.1:53`.
The current controller, owned TUN route and DNS response must be healthy before
the agent applies Global DNS. The compatibility `dns_bridge_ready` health field
reports the TUN DNS probe in this mode. Reload and shutdown restore the original
DNS before replacing/stopping Mihomo; a TUN DNS outage restores it on the first
failed observation while restart recovery retains its existing debounce.

An installed DoH profile can still win over Global DNS for matched domains.
After the new runtime validates, the daemon removes only
`dev.linsheng.mihomobox.local-doh` and verifies absence independently of its
certificate/URL validity. A stale profile must not be mistaken for absence.
If removal fails or cannot be confirmed, Config explicitly requests removal in
Device Management; network health alone does not prove fallback completion.
The identity and prepared profile remain available for a later Prepare retry.

Fallback survives daemon restart and does not repeatedly contend for 443.
Disabling TUN in fallback stops the worker and restores system DNS. Prepare
restores Global DNS before switching to LocalHttpDns standby; another failure
re-enters fallback. LocalHttpDns remains on loopback: binding it to the TUN
address would couple its lifetime to TUN and would not evade a wildcard 443
listener. Privileged fault-injection acceptance must use a signed Cloud build.

### Legacy DNS restoration

The SystemConfiguration code below restores legacy `127.0.0.53` installations
and manages `198.18.0.1` in explicit fallback. Startup restores recorded DNS with
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

## Loopback Alias

`127.0.0.53` is added to `lo0` through `SIOCAIFADDR` only when absent. A marker
is written only after this agent creates the alias. Restore removes the alias
only when that marker exists; a pre-existing administrator-owned alias remains.

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
auto-route state. In standby mode, the absence of TUN/route is intentional and
does not vote for recovery. LocalHttpDns remains bound on the daemon; Mihomo IPC
temporarily falls back to current network DNS while the child restarts.

The Fake-IP route is machine-wide evidence, not ownership proof. The agent
records any tunnel already routing the probe range before it starts Mihomo and
accepts a route only when the controller reports TUN enabled and the visible
interface is not that pre-existing tunnel. Stopped-state inspection likewise
ignores unrelated utun routes. This prevents another VPN or network extension
from making Mihomo look healthy or from blocking verified shutdown.

Legacy restoration removes only the alias marked as MihomoBox-created and uses
compare-before-write for persistent and effective service DNS. This prevents a
pre-existing alias or administrator change from being removed while clearing
stale `127.0.0.53` values from inactive Wi-Fi, Ethernet or VPN services.

The root daemon owns the LocalHttpDns data plane. It authenticates
XPC clients, serializes lifecycle/profile transactions, prepares the fixed
global DNS profile, keeps the TLS endpoint alive with Mihomo IPC plus a
daemon-owned original-network DNS fallback,
and supervises the agent. TUN and the 1054
original-DNS escape remain agent-owned. Only explicit fallback owns the system
DNS list.

Each agent launch receives a daemon-generated runtime generation. The
consistency observer includes that generation in its mode-`0600` atomic health
snapshot. Startup validation waits for a fresh snapshot matching the exact
generation and never repeats active DNS probes on its 250 ms transaction poll;
a snapshot from the previous agent or Mihomo child cannot commit startup.

Reloading the already-active root-owned profile uses a narrower transaction.
The daemon writes a one-shot mode-`0600` request containing a new generation
and wakes the existing agent with `SIGUSR1`. The agent keeps its own 1054
original-DNS escape alive, temporarily closes its Fake-IP safety gate, and
restarts only its owned Mihomo child. The independently daemon-owned
LocalHttpDns endpoint remains bound and falls back to current network DNS. The
transaction commits after the new generation reports complete health. A
rejected request, child failure, or validation timeout stops the agent but
still leaves LocalHttpDns resolving through its independent network-DNS branch.

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
agent circuit removes its TUN state and restores only legacy DNS ownership, if
an upgrade backup still exists; LocalHttpDns remains daemon-owned. A process
that remains healthy for sixty seconds resets the failure sequence.

Tray-state health is passive: it consumes only the agent observer's fresh
snapshot, or the exact safely-stopped result already proved by the restore
transaction. A missing or stale running snapshot is reported as unknown and
never causes the UI polling path to issue DNS or route probes. Explicit
diagnostic `status` remains allowed to inspect live state.
