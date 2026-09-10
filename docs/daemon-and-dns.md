# Daemon and DNS

## Responsibilities

`mihomo-agent` combines the Mihomo runtime responsibilities so ownership never
splits while moving between standby and Enhanced TUN:

- supervise exactly one bundled Mihomo process and restart it after failure;
- keep the original-DNS escape bound to the current physical/scoped resolver;
- observe controller, DNS and route health without owning macOS DNS settings.

The agent records the Mihomo child PID. A later agent instance validates the PID's
executable path with `proc_pidpath` before terminating a stale owned process;
it never kills an unrelated process merely because a PID file exists.

## DNS Flow

LocalHttpDns is the default and only macOS DNS integration. Installing the root
helper creates a valid Mihomo standby runtime with TUN disabled. The user then
prepares and approves one macOS DNS Settings profile before Enhanced TUN can be
enabled:

```text
matching macOS queries -> https://127.0.0.1:9443/dns-query (root daemon)
                              |-- healthy controller + TUN + route -> Mihomo DNS
                              +-- otherwise/failure -> current physical/scoped DNS
all other queries      -> current macOS default/scoped resolver

Mihomo -> 127.0.0.1:1054 -> scoped or PrimaryService DHCP DNS
```

The root daemon owns `/dns-query` independently of Mihomo and TUN. It validates
RFC 8484 GET/POST wire messages and uses non-blocking DNS forwarders. The typed
`local-doh.install` operation generates a local root CA plus a host-only server
certificate with the `127.0.0.1` IP SAN, keeps the server private key root-only,
and discards the CA private key after signing. The CA certificate is embedded in
the generated profile; neither the installer nor the headless daemon writes
Keychain trust directly. It never unlocks a keychain. The profile uses a fixed
identifier so regeneration updates the existing settings. Only full helper
uninstall removes the profile, legacy trust residue and server identity. Mihomo
neither binds 9443 nor reads that identity, and its child never inherits
`SAFE_PATHS`.

The root daemon builds `SupplementalMatchDomains` from enabled `DOMAIN`,
`DOMAIN-SUFFIX`, and `GEOSITE` rules whose current selector chain resolves to a
concrete remote proxy. It accepts both YAML's `DOMAIN-SUFFIX` and the controller
API's `DomainSuffix` spelling. `GEOSITE` selectors are resolved against the
validated root-owned `GeoSite.dat` from the managed Mihomo configuration
directory. Tag lookup is case-insensitive, `@attribute` filters are intersected,
and a tag containing `!` (for example `category-ai-!cn`) remains a literal tag.
Only GeoSite root-domain and full-domain entries can become Apple suffix
matches. Plain keywords, regular expressions, unknown entry kinds, invalid
names, and unsupported controller rules are omitted and counted. Full-domain
and controller `DOMAIN` matches are explicitly widened to suffix semantics and
counted as approximations.

The complete deduplicated result is emitted without a silent domain-count cap.
A whole-selector inversion such as `!cn` cannot be represented by a finite
Apple suffix list, so it is omitted and counted rather than widened to global
DNS. A selector ending in DIRECT, an unknown target, or a selector cycle is
also omitted. An empty result fails closed instead of generating a global
encrypted-DNS profile. Global and Direct outbound modes are rejected because
their effective domain scope cannot be represented as bounded split DNS.
Regenerate the profile after changing rules, GeoSite data, or proxy selections.
macOS requires the user to review and install the generated profile in
**General > Device Management**.

The separate `1054` listener is mandatory. Pointing Mihomo at macOS `system`
DNS could recurse back through the installed LocalHttpDns resolver. The configurator forces
`dns.respect-rules: false`, so Mihomo never routes its loopback `1054` upstream
through a proxy rule and accidentally breaks this recursion boundary. Mihomo
uses the agent's TCP `1054` listener for its upstream requests so Enhanced TUN
cannot recapture a UDP loopback flow emitted by Mihomo itself.

Both bridge hops use non-blocking SwiftNIO UDP/TCP clients. Every query keeps
its own timeout and remains eligible for the Mihomo response regardless of how
many other queries are in flight. The original-DNS path is used only after that
query's primary attempt actually fails or times out; queue pressure never
changes DNS routing semantics. Truncated UDP replies continue asynchronously
over TCP on the same selected endpoint and interface.

The legacy port-53 bridge still retains its Fake-IP fail-closed policy for
one-time migration and rollback compatibility, but it is not bound in normal
LocalHttpDns operation. LocalHttpDns deliberately prioritizes availability: a
proxy-matched domain uses Mihomo DNS only while the Enhanced path is healthy,
then falls back to physical/scoped DNS if that attempt is unavailable.

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

MihomoBox does not replace the system DNS server list. The independent daemon
endpoint remains live before, during and after agent/TUN transitions. It uses
Mihomo DNS only while the complete controller/TUN/Fake-IP route is healthy and
otherwise immediately uses the current physical/scoped resolver. The
original-DNS `1054` listener, physical-interface binding, route observer, wake
recovery, egress probes, and generation-bound health snapshots remain active.
A five-second daemon supervisor retries `9443` after a transient bind conflict
or listener failure for as long as the fixed root-owned identity remains
installed.

The Config page asks the daemon to prepare the fixed root-owned profile,
identity and independent resolver through the typed `local-doh.install`
transaction, then queries `local-doh.status`. The daemon and standby agent stay
online throughout. It reduces preparation, the fixed system
profile identifier, root-owned server identity, and daemon-listener health to
booleans plus numeric counts. Profile contents, expanded domain names, and
GeoSite entries never cross XPC or enter logs. The UI distinguishes setup,
waiting for macOS profile approval, active LocalHttpDns, and a profile/server
mismatch, and refreshes while Config is visible. The profile carries both the
root certificate and split-DNS payload so macOS applies their trust and DNS
authorization together only after the user approves installation.

`runtime.set-tun` is a persistent transition between two valid agent states.
Standby retains the controller and Mihomo DNS with TUN and the Fake-IP route
absent; Enhanced mode adds TUN only after the installed profile, identity and
9443 listener are verified. Disabling Enhanced TUN returns to standby and
never stops LocalHttpDns.

### Legacy DNS restoration

The SystemConfiguration code below is retained only to restore installations
from releases that wrote `127.0.0.53`. Protocol-3 startup migrates the runtime
to LocalHttpDns/TUN-off, restores that recorded state once, and never reapplies
the managed server. The legacy agent used to read `CurrentSet`, then manage:

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
does not vote for recovery. LocalHttpDns continues on the daemon and falls back
to physical DNS throughout either recovery path.

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
split-DNS profile from managed controller/GeoSite state, keeps the TLS endpoint
alive with a physical-DNS fallback, and supervises the agent. TUN and the 1054
original-DNS escape remain agent-owned; no component owns the system DNS list.

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
LocalHttpDns endpoint remains bound and falls back to physical DNS. The
transaction commits after the new generation reports complete health. A
rejected request, child failure, or validation timeout stops the agent but
still leaves LocalHttpDns serving through physical DNS.

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
