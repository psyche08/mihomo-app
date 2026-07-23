# Daemon and DNS

## Responsibilities

`mihomo-agent` combines the runtime responsibilities so ownership never splits
during Enhanced TUN:

- supervise exactly one bundled Mihomo process and restart it after failure;
- own the system DNS bridge and physical-interface upstream selection.

The agent records the Mihomo child PID. A later agent instance validates the PID's
executable path with `proc_pidpath` before terminating a stale owned process;
it never kills an unrelated process merely because a PID file exists.

## DNS Flow

```text
macOS -> 127.0.0.53:53 -> 127.0.0.1:1153 (Mihomo)
                              |
                              +-- unavailable/timeout/invalid response
                                  -> scoped or PrimaryService DHCP DNS

Mihomo -> 127.0.0.1:1054 -> scoped or PrimaryService DHCP DNS
```

The separate `1054` listener is mandatory. Pointing Mihomo at macOS `system`
DNS would recurse back through `127.0.0.53`. The installer also forces
`dns.respect-rules: false`, so Mihomo never routes its loopback `1054` upstream
through a proxy rule and accidentally breaks this recursion boundary. Mihomo
uses the agent's TCP `1054` listener for its upstream requests so Enhanced TUN
cannot recapture a UDP loopback flow emitted by Mihomo itself.

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

## System DNS ownership

The agent reads `CurrentSet`, then manages:

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

## Loopback Alias

`127.0.0.53` is added to `lo0` through `SIOCAIFADDR` only when absent. A marker
is written only after this agent creates the alias. Restore removes the alias
only when that marker exists; a pre-existing administrator-owned alias remains.

## Network Changes

`SCDynamicStore` watches global IPv4/IPv6/DNS and per-service IPv4/IPv6/DNS
keys. On change it:

1. resolves PrimaryService and PrimaryInterface;
2. reads DHCP option 6 before service DNS state;
3. builds domain-scoped resolver routes from `SupplementalMatchDomains`;
4. excludes loopback, fake-IP, and managed runtime endpoints;
5. binds original-DNS sockets using `IP_BOUND_IF`/`IPV6_BOUND_IF`;
6. restores an old PrimaryService before managing the new service.

An independent two-second consistency observer also detects later drift. A DNS
preference or effective-state change is reapplied while the managed runtime is
healthy. If the TUN/Fake-IP route, controller, or Mihomo DNS disappears, the
agent immediately disables Fake-IP answers. It requests recovery only after
three consecutive failed observations, filtering short startup and interface
transition gaps. The sole owned Mihomo supervisor then allows eight seconds for
Mihomo to rebuild the complete auto-route state. During that window the
loopback DNS bridge serves real upstream answers. Only a failed recovery rolls
back system DNS and stops the child.

When the persistent service DNS value already matches but the PrimaryService's
dynamic DNS value is absent, the agent reapplies preferences and republishes
the service value. Persistent and dynamic dictionaries for the previous service
are restored first with the same compare-before-write rule. This prevents an
inactive Wi-Fi, Ethernet, or VPN service from retaining `127.0.0.53` when it is
reactivated.

The root daemon does not participate in this data plane. It authenticates XPC
clients, serializes lifecycle/profile transactions, and supervises the agent.

No query name, matched domain, resolver address, service identifier, or wire
message is logged. Only interface names and aggregate resolver/route counts are
audited.

Lifecycle, configuration commands, child exits/restarts, network transitions,
drift detection, repair attempts, and repair outcomes are structured audit
events. Mihomo stdout/stderr is never persisted verbatim: only line, byte, and
severity counts are emitted. Normal logs are buffered for up to one second or
64 KiB before writing. Each log file is capped at 100 MiB and retains three
numbered rotated generations. Fatal signals are also synchronously appended to
a separate crash log before the operating system receives the signal.
The first sanitized supervisor start removes legacy raw Mihomo log generations
and writes a mode-`0600` migration marker; later starts preserve aggregate logs.

The daemon's agent supervisor and the agent's Mihomo supervisor restart failed
children with exponential delays from one to thirty seconds. Six consecutive
short-lived failures open a circuit instead of creating a restart storm; an
agent circuit also restores safe system DNS. A process that remains healthy for
sixty seconds resets the failure sequence.
