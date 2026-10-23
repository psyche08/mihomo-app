# App Proxy interface preservation: physical validation

Date: 2026-10-23

## Source and package

Implementation: `f258bdfaf1418abff55e60d25e5a782fb99baf71`.
The complete `scripts/validate.sh` run passed, including 361 Swift tests with
one existing skip, configuration and installer simulations, ten core DNS
transport cases, native interface identity checks, fragmented TCP and half-close,
UDP echo, pinned UI build, application bundle checks and agent end-to-end tests.

Xcode Cloud build 49 archived, Developer ID signed and notarized this exact
source. The downloaded original `MihomoBox.app.zip` has SHA-256
`36e02b25bc7b632893736466fe3c7a592d36584b2da9f5df173213bc838064ed`.
Its manifest reported a clean source tree. Strict nested signature and existing
stapled-ticket validation passed. The Cloud app was installed without modifying
or re-signing its contents; macOS activated App Proxy extension version 1.0.0/49.
The previous app was retained for rollback. No public release was published.

## Physical network acceptance

On the acceptance Mac, App Proxy remained enabled in Rule mode with the existing
four application routes and the six default private/link-local bypass CIDRs.
The temporary bridge-bound Mihomo direct adapter and its seven inserted rules
were removed through the authenticated profile import path. Both the stored
profile and generated configuration were checked for their removal.

From the actual Codex process context, with NetworkExtension identifying the
captured flows as `com.openai.codex`:

- SSH to the physical Mac peer over `bridge0` succeeded. Five new connections
  each transferred 256 KiB and verified SHA-256 on the peer, with complete
  process round trips of 261–292 ms (including SSH authentication and Python).
- SSH to the same peer over the Muster virtual interface succeeded. Another
  five new connections verified 256 KiB each, with round trips of 234–463 ms.
- Connected and unconnected UDP both returned the exact random nonce from a
  short-lived echo socket on the physical peer, in 21.2 ms and 16.4 ms respectively.
- Network.framework logs showed required interface `bridge0` for bypassed TCP
  and UDP, and required interface `utun9` for the virtual-network TCP connection.
  Local TCP/UDP success counters advanced. The former default-Ethernet route
  selection was no longer present in these connections.
- Public HTTPS returned HTTP 200 while SOCKS connection counters advanced.
- The daemon reported runtime ready, network consistent, TUN ready and relay
  services available; existing DNS settings were preserved.

Muster's remote status RPC also succeeded. A read-only query for an absent send
receipt returned Unknown while the target Mac remained locked; it neither sent
a message nor obtained a console lease.

## Remaining boundaries

A separate disable/re-enable regression was not performed after this initial
activation: approval review stopped the Disable App Proxy action pending explicit
confirmation of its brief connection interruption. Profile-reload and TUN/mode
transition regressions are not claimed by the results above.

Muster's successful locked native send still requires the user's system Presence
authentication. Device Hub and `devicectl` reported the physical iPhone unavailable,
and the third Mac remained offline. Phone-driven sends and successful locked
delivery are therefore not established by this network fix or by the local tests.
