# Daemon and DNS

## Responsibilities

`mihomo-daemon` combines two root-only responsibilities so ownership never
splits during Enhanced TUN:

- supervise exactly one bundled Mihomo process and restart it after failure;
- own the system DNS bridge and physical-interface upstream selection.

The daemon records the child PID. A later daemon instance validates the PID's
executable path with `proc_pidpath` before terminating a stale owned process;
it never kills an unrelated process merely because a PID file exists.

## DNS Flow

```text
macOS -> 127.0.0.53:53 -> 127.0.0.1:1153 (Mihomo)
                              |
                              +-- unavailable/timeout/invalid response
                                  -> DHCP DNS on PrimaryInterface

Mihomo -> 127.0.0.1:1054 -> DHCP DNS on PrimaryInterface
```

The separate `1054` listener is mandatory. Pointing Mihomo at macOS `system`
DNS would recurse back through `127.0.0.53`. The installer also forces
`dns.respect-rules: false`, so Mihomo never routes its loopback `1054` upstream
through a proxy rule and accidentally breaks this recursion boundary. Mihomo
uses the daemon's TCP `1054` listener for its upstream requests so Enhanced TUN
cannot recapture a UDP loopback flow emitted by Mihomo itself.

## Global DNS

The daemon reads `CurrentSet`, then manages:

```text
<CurrentSet>/Network/Global/DNS
```

It uses `SCPreferencesPathGetValue` and `SCPreferencesPathSetValue`, followed by
`SCPreferencesCommitChanges` and `SCPreferencesApplyChanges`. On current macOS,
the effective resolver is published through the current PrimaryService's
`State:/Network/Service/<id>/DNS` dictionary; a Global dynamic dictionary alone
does not enter `scutil --dns`. Before the first write for each active set or
primary service, the daemon stores the prior dictionary in a binary plist.

Restoration is compare-before-write: an entry is restored only while its
current `ServerAddresses` still equals the daemon-managed value. An external
administrator change therefore wins and is never overwritten by uninstall.

## Loopback Alias

`127.0.0.53` is added to `lo0` through `SIOCAIFADDR` only when absent. A marker
is written only after this daemon creates the alias. Restore removes the alias
only when that marker exists; a pre-existing administrator-owned alias remains.

## Network Changes

`SCDynamicStore` watches global IPv4/IPv6/DNS and per-service IPv4/DNS keys.
On change it:

1. resolves PrimaryService and PrimaryInterface;
2. reads DHCP option 6 before service DNS state;
3. excludes loopback, fake-IP, and daemon endpoints;
4. binds original-DNS sockets using `IP_BOUND_IF`/`IPV6_BOUND_IF`;
5. idempotently reapplies Global DNS for the new active set.

When the persistent Global DNS value already matches but the PrimaryService's
dynamic DNS value is absent, the daemon reapplies preferences and republishes
the service value. Each service value is restored or removed with the same
compare-before-write rule. This repairs resolver state lost during a TUN,
primary-service change, or LaunchDaemon handoff without creating a notification
loop.

No query name or wire message is logged.
