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
