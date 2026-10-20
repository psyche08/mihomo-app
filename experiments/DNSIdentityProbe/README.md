# Independent DNS identity probe

Experimental macOS system extension. This is not a shipping per-app DNS feature.
Build the shared `MihomoDNSProbe` scheme in `DNSIdentityProbe.xcodeproj` through
Xcode Cloud for Developer ID signing and provisioning. Local unsigned builds
check compilation only and must not be installed as an activation workaround.
Regenerate the project with `ruby generate-project.rb` (requires `xcodeproj`).

The host ID is `dev.linsheng.mihomo-dns-probe`; the extension appends `.extension`.
Two signed client apps and a nested helper provide controlled source identities.
The provider validates the flow audit token against its claimed signing ID and,
for test identities, team `89LGY6BD53`. It logs category counters only, never DNS
wire data, domains, addresses, credentials or raw tokens.

Selected and helper flows use Cloudflare's IP-address DoH URL through the existing
Mihomo HTTP proxy on port 7897. Control/other flows use native TLS to the existing
Local DoH endpoint. A selected upstream error never retries using direct DNS.
**A mixed listener alone does not guarantee a proxy exit:** a live test must also
verify the extension's Mihomo rule/chain and exercise an explicit proxy failure.
The original-DNS escape and daemon ownership remain unchanged. The provider has
no shared DNS cache; this does not establish that macOS caches are partitioned.

## Activation and rollback

After validating the complete Cloud-signed bundle and installing it under
`/Applications/MihomoDNSProbe.app`, use its `Contents/MacOS/MihomoDNSProbe`:

- `--activate`: request ordinary macOS system-extension approval.
- `--status`: read this app's DNS manager status.
- `--session`: enable for four minutes; unknown identities forward to Local DoH
  and are counted. This observation mode is intentionally not strict.
- `--strict-session`: same time limit, but unknown/mismatched origins get REFUSED.
- `--disable`: immediately disable this probe's DNS configuration.
- `--deactivate`: request removal of this system extension.

The host auto-disables after 240 seconds. The provider independently stops at the
saved 300-second deadline and refuses to start with an expired deadline. If the
host is killed, the provider deadline does not remove the saved enabled preference;
run `--disable` to restore preferences. Do not start with another DNS proxy active:
enabling a DNS proxy may disable another provider. Preserve the current Local DoH
profile and test precedence before considering any configuration change.

Clients are under `Contents/Resources/Clients`. Run their executables with
`system`, `udp`, `tcp`, or `https`, followed by case `a`, `b`, or `fresh`. These use
fixed public example names (fresh adds a random label), print only result metadata,
and support cache/coalescing comparisons. The selected client's `helper` mode
launches its embedded signed helper for a system resolver query.

## Required runtime evidence

Record signed bundle/profile validation, active provider state, identity counters,
per-case client results, selected proxy connection chain/failure behavior, and
post-test rollback. Compare selected/control queries in both cache orders and
concurrently with Local DoH and TUN enabled. A successful UDP test alone is not
proof of strict DNS routing: high-level resolution, shared caches, delegated
processes and application-owned encrypted DNS may behave differently. Broader
coverage (DNSService, A/AAAA/HTTPS, browser helpers, selector changes and sleep/wake)
is required before any production claim.

## First Cloud checkpoint (2026-10-20)

Independent App IDs and host/extension capabilities are registered. Cloud Build
23 (`6c799d7e`) compiled and created an archive, but its default App Store and
Development exports failed: their provisioning profiles do not permit the
`dns-proxy-systemextension` entitlement. Keep Archive's **Distribution
Preparation** set to **None** and add a **Notarize** post-action to the
`DNS Identity Probe` workflow before rebuilding. Developer ID is not an option
in that Cloud dropdown (it is a local Xcode export option). Apple's Cloud
workflow supports notarization through the post-action; the public workflow
API used here does not expose that post-action configuration. The next build
must still verify the exported entitlements and provisioning profiles; adding
Notarize alone is not evidence that the signing mismatch is resolved.
See [Apple's Cloud notarization demonstration](https://developer.apple.com/videos/play/wwdc2023/10224/?time=807).
No probe was installed or activated, and no real-flow identity claim follows
from this build. The existing Local DoH profile remained healthy; both unsigned
baseline clients resolved the same fixed test name to Fake IP.

After the signed bundle is verified and ordinary macOS activation is approved,
`./run-live-checks.py RESULT.json` exercises the basic selected/control/helper
matrix and disables the probe in `finally`. It intentionally always records
`strict_dns_verified: false`: the aggregate observations still require analysis
and the remaining coverage/failure tests above. Stop if rollback is not confirmed.

## Archive and export entitlement variants

Source entitlements use `dns-proxy`, as required for development/App Store
archives. Cloud uses Xcode 27, whose Developer ID exporter supports conversion
to `dns-proxy-systemextension`. The export audit still requires the suffixed
value in both signed binaries and their embedded profiles; it never accepts the
source/development variant as a distributable system extension. Builds 23/24
exposed the mistake of using the Developer ID variant in source entitlements.
See [Apple DTS: Exporting a Developer ID Network Extension](https://developer.apple.com/forums/thread/737894).

## Runtime startup diagnosis (2026-10-20)

Cloud Builds 25 and 26 were signed, notarized, verified and installed as the
independent probe; macOS approved the extension. Build 25 reached `startProxy`
but returned `DNSProbe` error 1 before accepting DNS traffic. Build 26 verified
the host's saved configuration by reloading preferences, then reported
`missing_deadline`, with one top-level option. This distinguishes a provider
configuration-delivery problem from missing activation or missing log output.
Both attempts disabled the probe, restored the original profile, and verified
Local DoH health. Neither attempt established per-app DNS behavior.

The configuration adapter accepts the documented direct dictionary or one
dictionary envelope containing exactly the two typed test fields. It still
rejects missing, ambiguous, expired or excessively future deadlines and invalid
strict-mode flags. No default deadline or direct fallback is introduced.
Cloud Build 28 confirmed the single dictionary envelope at runtime.
Run its isolated checks without activating any extension:

```sh
swiftc experiments/DNSIdentityProbe/Extension/ProbeSessionConfiguration.swift \
  experiments/DNSIdentityProbe/Tests/main.swift -o /private/tmp/mihomo-probe-config-tests
/private/tmp/mihomo-probe-config-tests
```

The live runner has a 180-second case budget, reports failures as a nonzero exit,
and always attempts to disable the configuration. A passing basic matrix still
does not imply strict isolation or satisfy the broader runtime checklist above.

## Build 28 result: not eligible for production

The provider started and authenticated selected/control application identities.
Selected UDP/TCP requests returned public answers, and Mihomo connection
readback confirmed the extension's explicit Proxy rule and chain without DIRECT.
However, three control UDP/TCP cases failed. System resolver queries reused the
other policy's answer category in both query orders: control reused selected
public answers, and selected reused control Fake IP. A warm-cache helper query
had no matching helper flow counter. Thus the matrix does **not** establish
strict DNS isolation, even for the cases whose resolver call succeeded.

The probe configuration is disabled after testing; the original profile and
healthy Local DoH are restored. Keep this extension separate from the shipping
App. Before any further live experiment, investigate Local DoH forwarding
failures and require a new design for system resolver/cache separation.
See [the architecture decision](../../docs/decisions.md#signed-runtime-counterexample).

## Connection-level App Proxy experiment

The same independent host now also embeds an App Proxy provider. Source
entitlements include `app-proxy-provider`; the Cloud export audit requires its
`app-proxy-provider-systemextension` counterpart in both signed code and profiles.
The old DNS-only experiment stays disabled. This is not a production feature.

`--app-session` saves a separate `NEAppProxyProviderManager` configuration with
signed app rules for the selected test client and its helper only. It requests
the normal macOS VPN authorization. `--app-status` reads its state and
`--app-disable` stops and disables it, with preference readback. The host disables
after 240 seconds; the provider independently expires after 300 seconds.
Never run the DNS-only and App Proxy sessions together.

Selected DNS flows go to proxied DoH without direct fallback. Selected TCP
connections to the two fixed public HTTPS test names use SOCKS domain-address
requests through the existing managed Mihomo mixed listener. A missing or
unexpected hostname is rejected; numeric cached answers are not assumed to
prove DNS isolation. Non-DNS UDP is unsupported and rejected. Each flow has a
30-second bound, the session allows at most 128 flows, and only counters are
logged. No second Mihomo process or production daemon change is introduced.

Client `connect` resolves through `getaddrinfo`, opens TCP, and holds for three
seconds for route observation; `helper-connect` and `helper-https` exercise
the signed helper. Existing `system`, `udp`, `tcp`, and `https` modes remain.
The provider deliberately handles only two test names for TCP. Successful
compilation or connection forwarding is not proof of arbitrary-app DNS isolation.

Additional offline framing checks:

```sh
swiftc experiments/DNSIdentityProbe/Extension/SOCKSConnect.swift \
  experiments/DNSIdentityProbe/SOCKSTests/main.swift -o /private/tmp/mihomo-app-proxy-socks-tests
/private/tmp/mihomo-app-proxy-socks-tests
```

`doh` queries the installed Local DoH endpoint with native TLS verification.
`doh-connect` uses that answer only if it is a Fake IP, opens TLS to it with the
original fixed test hostname for certificate verification/SNI, and verifies an
HTTP 200 response. It deliberately bypasses system name resolution to distinguish
the Fake-IP connection path from system DNS integration; it is not evidence that
macOS resolver caches are isolated.

`run-mixed-cache-checks.py RESULT.json [CLIENTS_DIRECTORY]` checks selected
Proxy/control DIRECT, selected REJECT, and swapped policies. It retains existing
filters, prepends Fake-IP rules for the fixed test suffixes, verifies process
rules and connection chains, and restores the original profile in `finally`.
A separate 230-second watchdog restores only while this test's profile remains
active. No DNS cache is flushed. Native DoH and fresh system queries are recorded
separately, so a working connection path cannot mask a failed DNS integration.

The clients must be independent applications for the positive App Proxy test:
copy the Cloud-signed `MihomoDNSSelected.app` and `MihomoDNSControl.app` unchanged
from the probe's `Contents/Resources/Clients` into `/Applications`, checking
that those paths are unused first. The runner verifies signatures and identical
executable bytes. The nested copies are retained as a negative comparison:
even Launch Services launches of those copies did not reach App Proxy on the
test Mac. Moving the same signed bytes to top-level application paths did.

`run-app-proxy-checks.py RESULT.json --launch-services --top-level-clients` starts the signed App
Proxy session, warms caches, exercises both query orders, raw UDP/TCP, system
resolution, HTTPS and the helper, then rejects the extension's proxy route.
It fails if the selected HTTPS request still succeeds during rejection or if
the provider never observes selected hostname flows. It restores the original
profile and disables the experiment. Omit `--launch-services` for the separate
direct-executable launch comparison.

Cloud Build 32 passed the controlled standalone-client matrix (25 cases plus
the positive/negative proxy-failure pair), with actual selected DNS and hostname
flow counters and a Proxy chain without DIRECT. Both cache orders and concurrent
system lookups retained selected public/control Fake-IP separation. Broad strict
DNS support remains unverified: helper requests were observed under the selected
category rather than independently as `helper`, and the control's answer category
changed when the session enabled. Resolver scope/coexistence, IPv6, browser
helpers, application-owned DoH and sleep/wake still require acceptance tests.
