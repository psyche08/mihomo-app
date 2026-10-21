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

Selected DNS flows now use the existing Mihomo resolver on loopback TCP 1153,
sharing TUN DNS policy without a public fallback or global DNS override. Selected TCP
connections to the two fixed public HTTPS test names use SOCKS domain-address
requests through the existing managed Mihomo mixed listener. A missing or
unexpected hostname is rejected; numeric cached answers are not assumed to
prove DNS isolation. Non-DNS UDP is unsupported and rejected. TCP establishment and DNS flows have a
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
  experiments/DNSIdentityProbe/Extension/SOCKSDatagram.swift \
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

## Installed ChatGPT / Codex / Claude routing

The separate `--app-ai-inventory` command discovers installed ChatGPT/Codex and
Claude applications, their signed Mach-O helpers, native Codex/Claude CLI
installations, Codex computer-use helpers, and Claude local remote servers.
It prints only executable identities and paths. OpenAI and Anthropic bundles
must validate against their observed vendor teams and Apple signing anchor.
Rules consolidate repeated signing identities and designated requirements.
The provider separately pins each executable path and designated requirement. Ad-hoc
Claude remote servers are pinned to their current code hash. Re-run discovery
and enable after applications, Homebrew CLI versions or remote servers update.
Unsigned scripts and arbitrary external MCP tools are not inferred from a
process-name prefix. Helpers attributed by macOS to their selected parent app
are covered by that app's rule; independent processes require their own identity.

Terminal and installed supported editor rules use `matchTools` restricted to the
verified Codex/Claude native CLI executables. They do not select all terminal or
editor traffic. Current hosts are Terminal, iTerm, Warp, Ghostty, kitty,
Alacritty and Visual Studio Code. CLI attribution from other launchers still
requires runtime verification. The extension validates each delivered source
audit token, designated requirement and executable path before accepting it.

`--app-ai-session` enables this set for a 240-second test (provider deadline
300 seconds); `--app-ai-enable` explicitly saves a persistent configuration and
returns only after it is connected. `--app-disable` stops and disables either
mode. Only the latter command intentionally has no session deadline. This is
still the independent experiment, not a main-App UI or login-start integration.

AI mode forwards general TCP names, IPv4/IPv6 destinations and ports through the
managed core's mixed SOCKS listener at `127.0.0.1:7897`. The 30-second TCP limit
covers establishment only, allowing streaming and WebSockets after connection.
Explicit TCP/UDP loopback forwarding stays local for authentication callbacks and local MCP services.
DNS now goes through the shared Mihomo resolver on TCP 1153. Other UDP uses SOCKS5 UDP
ASSOCIATE with a loopback relay, rejects fragmented SOCKS datagrams, and expires
after 180 seconds idle. Upstream UDP support remains dependent on the selected
node. The provider caps AI mode at 1024 flows. Failure closes the affected flow;
there is no automatic direct fallback for remote destinations.

Before enabling, use the signed typed profile interface to place
`PROCESS-NAME,MihomoDNSProbeExtension,Proxy` ahead of other rules in a separate
profile copied from the user's active profile. Verify Rule mode, port 7897 and
the expected Proxy selector. The extension no longer exposes each original app
identity to Mihomo, so this explicit extension rule is required. Preserve the
original profile for rollback. Do not enable alongside the DNS-only probe.
General forwarding, especially cached numeric addresses, is not proof of strict
per-app DNS isolation. System resolver scope, arbitrary helper attribution and
sleep/wake remain runtime acceptance items.

`--app-ai-check-rules` saves and verifies rules while leaving the VPN disabled.
`--rules apps|cli|all|all-paths` supports bounded diagnosis of rule persistence;
`all` is the default consolidated identity set, and `all-paths` retains the
initial per-executable NE rule form for comparison. Rule readback compares
unordered identities and nested tool restrictions without relaxing any fields.
The local-flow bridge explicitly opens a loopback connection: returning false
from an App Proxy handler fails the flow, as documented in
[Apple DTS's explanation](https://developer.apple.com/forums/thread/842052).

Cloud Build 34 passed disabled-state rule readback for the two main real apps
and for all 53 consolidated rules on the test Mac. Its 74 executable identities
covered all 13 related running executable paths at the inventory checkpoint.
`run-ai-app-checks.py RESULT.json [--rules SET]` performs the bounded real-helper
HTTPS, UDP, local-callback and connection-rejection checks, then restores the
original profile. It retains a resolved test address only in the helper's memory
for the rejection/recovery pair and tests fresh DNS separately. It never sends
chat messages. The successful run is documented in `docs/decisions.md`; a
successful Codex read-only request and a Claude auth-status command do not by
themselves prove separate flow attribution for every CLI/helper.

The explicitly enabled persistent configuration on the test Mac uses the
separate `ai-app-proxy.yaml` profile; `sheng.yaml` is preserved byte-for-byte.
To stop it and restore that original profile:

```sh
/Applications/MihomoDNSProbe.app/Contents/MacOS/MihomoDNSProbe --app-disable
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl profile switch sheng.yaml
```

To re-enable after updating application/helper paths, first select the dedicated
profile through the main App or the typed CLI, then run `--app-ai-enable`; that
command re-discovers signatures and paths before saving. Do not use the original
profile without its explicit extension Proxy rule. The full `--rules` choices
also include `primary` (main apps, native CLIs and restricted terminal hosts).

### Main application integration

The main App now builds these provider sources as a separate system-extension
identity (`dev.linsheng.mihomo-app.app-proxy`) with `MAIN_APP_PROXY`. That variant
requires `routing: per-application-v1`, assigning ChatGPT, Codex CLI, Claude,
and Claude CLI to loopback ports 17971, 17972, 17973 and 17974 respectively.
TCP, UDP and DoH all use that assignment; host-only CLI attribution is rejected.
The standalone experiment retains its 7897 legacy behavior for existing tests.
Signature discovery is shared from `Sources/MihomoBoxApp/AIAppTargets.swift`.
See `docs/tray-and-controller.md` for the Config UI, root transaction and
migration/validation limitations. Historical Cloud34 live results do not count
as live acceptance of the new main-App extension.
