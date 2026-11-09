# Architectural Decisions

## Pure Swift/AppKit application shell

MihomoBox 0.8 replaces the remaining Tauri/Rust user-process shell with one
Swift executable. `NSApplicationDelegate` owns the accessory lifecycle,
`NSStatusItem` owns the tray, and `NSHostingController` owns the SwiftUI
dashboard. The user process talks directly to the existing authenticated XPC
client library; there is no WebView, Rust FFI, loopback bridge, or CLI child in
the general desktop controller path. The App Proxy master activation exception
introduced in 1.1.1 is described in [architecture](architecture.md).

The executable remains named `mihomo-app`, the bundle identifier remains
`dev.linsheng.mihomo-app`, and the installed bundle remains `MihomoBox.app`.
Those stable identities let existing login items, installers, root-component
synchronization, and 0.7-to-0.8 replacement target the same product.

## Native SwiftUI dashboard instead of a bundled WebView

The original build embedded pinned MetaCubeXD static assets. The dashboard is
now reimplemented with SwiftUI while retaining MetaCubeXD's
seven-page information architecture and Sunset visual reference. This removes
the loopback HTTP/token bridge and browser-to-CLI transport, integrates with
macOS accessibility, and keeps all controller access behind a typed signed XPC
gateway. The MetaCubeXD tag and license remain pinned for reproducible design
provenance; no upstream JavaScript executes in the App.

## Sparkle instead of an application-specific updater

The native shell uses pinned Sparkle 2.9.4 for EdDSA verification, Apple code
signature validation, atomic replacement, authorization when necessary, and
relaunch. MihomoBox does not implement its own archive extractor or updater.
The appcast is served over HTTPS and is signed; system profiling is disabled.

The first native releases published two update contracts. Existing 0.7 clients
received the legacy `latest.json` and minisign-compatible archive signature,
while 0.8 and later clients use Sparkle's signed `appcast.xml`. Starting with
0.9.3, the legacy bridge is no longer regenerated: the Sparkle enclosure is the
exact ticket-attached Xcode Cloud App ZIP, renamed without changing its bytes.
Only the signed appcast metadata is generated locally. Historical legacy
assets remain available on their original releases.

## Root agent owns Mihomo continuously

Switching between a GUI-owned unprivileged process and a root TUN process creates
duplicate-owner and handoff races. One agent owner keeps the PID, controller,
DNS, and Enhanced TUN state coherent. The GUI never starts a second kernel.

## Privileged daemon is an authenticated XPC broker

Putting XPC policy, DNS, network observation, and Mihomo supervision in one
process makes the privileged attack surface unnecessarily broad. The daemon is
therefore limited to mutual code-signing authentication, typed command
authorization, serialized profile/lifecycle transactions, and agent
supervision. The agent owns the network data plane and has no client-facing
service. Since 2026-11-09 the daemon also relays App Proxy `dns.resolve`
queries to the core's DNS listener; it binds no DNS listener itself.

## Exact signing-certificate family instead of Team ID only

The App and CLI use different signing identifiers, so requiring one identifier
would reject a legitimate peer. Team ID alone accepts any other product signed
by that team. Both XPC sides instead derive a peer code-signing requirement from
their leaf certificate. During normal operation this is one leaf. The bounded
0.9.1 Xcode Cloud transition adds only the explicitly pinned published and
Cloud leaves so an old-signed bridge and a new-signed release can replace each
other's privileged components. This permits the signed MihomoBox family while
rejecting another certificate, invalid signature, ad-hoc build, or unsigned
binary. The Cloud leaf must be learned from an audited Developer ID archive and
committed before publishing the bridge; Team ID is never a migration shortcut.

## Copy bundle payloads to stable system paths

A LaunchDaemon that executes inside `/Applications/MihomoBox.app` breaks when
the user moves, replaces, or deletes the App. The signed bundle is the install
source; root-owned copies are the runtime.

## Login startup follows a healthy Enhanced TUN activation

First launch alone does not add a login item or prompt for administrator
access. After the native App observes Enhanced TUN and the managed network both
healthy, it applies a one-time current-user login-start default. This also
migrates an already-healthy installation. A later user override is retained;
the App does not repeatedly re-register the item. The unprivileged login item
only restores the hidden tray App, while the root LaunchDaemon independently
restores the persisted standby or Global DNS + TUN state at system startup.

## LocalHttpDns as the base service, Enhanced TUN as an optional layer (superseded)

Superseded on 2026-11-09 by
[Remove Local DoH; Global DNS is owned with TUN; App Proxy DNS goes through daemon XPC](#2026-11-09-remove-local-doh-global-dns-is-owned-with-tun-app-proxy-dns-goes-through-daemon-xpc).
Retained as history; it does not describe current behavior.

MihomoBox normally left the PrimaryService and Global DNS server list alone.
Installing the root helper established a valid controller/DNS standby
with TUN off. The daemon then prepared a manual DNS Settings profile with
`SupplementalMatchDomains` and an embedded local root certificate. Enhanced
TUN was unavailable until macOS reported that fixed profile installed and the
daemon-owned `127.0.0.1:443` endpoint was live.

The endpoint remained available when Mihomo restarted or TUN was disabled. It
preferred Mihomo DNS only for a completely healthy Enhanced runtime and otherwise
resolved through the current physical/scoped DNS. Manual profile confirmation
was retained because macOS does not permit the `profiles` CLI to install a
configuration profile interactively on the user's behalf. A failed LocalHttpDns
startup or preparation fell back to Global DNS at `198.18.0.1:53` with TUN
required. The daemon removed its fixed DoH profile so it could not override Global
DNS, retaining the identity for retry. Failed removal remained visible in Config.
Port 9443 was released. A wildcard 443 listener cannot be evaded by binding a
different local IPv4 address; the TUN address also could not support an
independent always-on HTTPS resolver.

## Separate port 53 and port 1054

DNS messages do not carry source-process identity. A single listener cannot
reliably distinguish macOS from Mihomo and would permit recursive forwarding.

## 2026-10-20: per-app routing, mixed ports, and Surge comparison

The per-app UI compiles explicit bundle selections into Mihomo process rules in
the source profile. This reuses the existing validated profile activation and
rollback path instead of adding a second policy store or a generic privileged
controller patch. The original rules remain intact below a replaceable marked
block. HTTP and SOCKS5 share `mixed-port`; dashboard endpoints come from actual
controller readback rather than example port numbers.

Research sources: [Surge Mac release notes](https://nssurge.com/support/mac/release-notes/)
and the [official stable appcast](https://www.nssurge.com/mac/latest/appcast-signed.xml)
used by that JavaScript page. At review time the feed begins with 6.10.0; this is
not a claim about beta releases. The following are recommendations, not shipped
features:

| Candidate | Surge reference | Fit for MihomoBox |
|---|---|---|
| Effective-profile diff | 6.9 CLI `profile diff` | High: compare source and daemon-normalized settings, redact credentials before returning anything over XPC. |
| Rule explanation | 6.9 CLI `rule match` / `rule explain` | High: first explain the already-reported connection rule and chain. Offline simulation needs a core API to avoid approximating rule semantics. |
| Persistent event timeline | 6.6 Logbook | High: bounded lifecycle events for profile apply/rollback, DNS ownership and wake recovery. Keep DNS names, subscription URLs and credentials out. |
| UDP diagnostics | 6.10 test diagnostics | High: distinguish unsupported UDP, no egress and timeout; the existing HTTP latency probe cannot establish UDP capability. |
| Aggregated metrics | 6.9 `/metrics` | Medium: expose counters through authenticated XPC first; a new HTTP endpoint would require a separate access-control design. |
| Rich profile diagnostics | 6.10 language support | Medium: retain the pinned-core validator; add policy-reference diagnostics and line locations without logging profile contents. |

### UDP Fast Path boundary

[Surge's VM UDP Fast Path](https://kb.nssurge.com/surge-knowledge-base/technotes/udp-fast-path)
is a Gateway VM mechanism, not a macOS Enhanced-mode switch. It changes a
high-connection client's UDP from per-flow L4 proxying to direct L3 forwarding.
It protects destination ports below 1024 and Fake-IP destinations and supports a
per-device opt-out. It bypasses proxy rules; a `NETWORK,udp,DIRECT` rule is not an
equivalent implementation and does not eliminate Mihomo's flow-management cost.

MihomoBox currently supervises an upstream checksummed binary and has no Gateway
VM data plane. A genuine equivalent needs a separately designed and benchmarked
core/gateway path, including source-client isolation, Fake-IP and IPv6 handling,
flow lifecycle, network changes, and explicit rule-bypass behavior. This change
adds no automatic UDP bypass and makes no Fast Path throughput claim. A narrower
opt-in per-app UDP DIRECT policy is feasible, but should be presented as direct
routing and selected explicitly rather than labelled as L3 acceleration.

Mihomo implementation references: [process routing rules](https://wiki.metacubex.one/config/rules/)
and [TUN stacks](https://wiki.metacubex.one/config/inbound/tun/). The shipped
`v1.19.30` binary, rather than newer online documentation alone, validates the
generated profile syntax.


## Strict per-application DNS: feasibility checkpoint (2026-10-20)

**Decision: the signed DNS-only prototype does not satisfy strict per-app DNS
isolation on the tested Mac.** See the runtime counterexample below.
The Local DoH HTTP/AF_UNIX path in use at the time (removed on 2026-11-09)
transported DNS wire messages without original-application identity. Setting `dns.respect-rules` cannot recover that
identity and must not break the original-DNS escape through TCP `1054`.

A macOS `NEDNSProxyProvider` system extension is a candidate identity-aware
entry point. Apple's SDK exposes `NEAppProxyFlow.metaData` with a signing
identifier and optional source-application audit token. The token can be
resolved with `SecCodeCopyGuestWithAttributes` and checked against the dynamic
code signature. A signing identifier alone is insufficient; selected identities
need a validated code requirement/team and a defined helper relationship.
Apple explicitly permits missing metadata for system processes. Unknown or
unverifiable origins therefore cannot silently become DIRECT in a strict mode.

The read-only prototype at `tools/per-app-dns-feasibility/run.sh` compiles the
real flow-metadata adapter and performs 11 identity/policy/partition checks.
The M4 mini verified a real audit token for the probe's own process, including
rejection of an inconsistent claimed signing identifier. Synthetic checks cover
unknown-origin rejection, a selected identifier from the wrong team, and
separation of application, policy and policy-generation cache partitions.
These checks are not a DNS provider runtime test: no provider is installed or
activated, no preferences are saved, and the cache model is not a resolver.
No packets, domains, raw tokens or credentials are logged.

Initial deployment observations, before the signed runtime experiment:

- The installed Cloud Build 22 App has no Network Extension entitlements.
- A read-only Apple API query found only `IN_APP_PURCHASE` on the existing
  `dev.linsheng.mihomo-app` App ID. No Apple account settings were changed.
- No MihomoBox DNS Proxy system extension is installed.
- macOS DNS Proxy providers support Developer ID deployment as system
  extensions from macOS 10.15; Apple's deployment table does not impose the
  iOS supervised/managed-device restriction on macOS.
- A native DNS Proxy provider returning `false` from `handleNewFlow` terminates
  that flow. It is **not** a safe observation-only pass-through mechanism.
  A live prototype must implement forwarding and rollback before activation.

The runtime acceptance checklist for any proposed strict implementation is:

1. Use a separate probe host/extension identity, valid Network Extension
   entitlements and provisioning, and the project's Xcode Cloud-only signing
   path. Obtain the macOS system-extension/network authorization through the
   ordinary OS UI. Do not alter the production bundle to bypass signing.
2. Forward accepted DNS flows with bounded concurrency and preserve TCP framing,
   UDP responses and RCODEs. Route selected, verified identities through the
   chosen policy; do not silently retry those requests on direct DNS. Keep the
   existing daemon as the only owner of Mihomo and the `1054` escape.
3. Exercise two signed apps requesting the same controlled names, first with
   cold caches, then warm caches and simultaneous requests. Include
   `getaddrinfo`, DNSService APIs, URLSession, browser subprocesses, embedded
   helpers and external responsible processes. Observe identity coverage using
   counters/test-case labels only. Do not assume system/shared caches are
   partitioned merely because the prototype's own cache key is partitioned.
4. Test both selected and unselected apps, A/AAAA/HTTPS records, UDP/TCP DNS,
   missing identity, app exit/PID reuse, selector changes, proxy failure and
   sleep/wake. Different DNS policies must not share cache or coalesced queries.
   A selector/policy change needs generation-scoped state and cancellation rules.
5. Verify precedence and rollback with the managed Global DNS bridge and
   Enhanced TUN (the global Local DoH profile at the time of this checkpoint;
   removed on 2026-11-09). DNS Proxy configuration is system-wide; do not assume it
   can coexist without changing which component receives requests. App-owned
   encrypted DNS is ordinary application traffic and requires separate coverage;
   observing a DNS Proxy flow does not prove coverage of every name resolution.

Passing the metadata compile/self-token probe is a go-ahead for that isolated
experiment, not approval to advertise leak-free per-app DNS. Missing identities
or shared resolver/cache behavior may require an `NEAppProxyProvider` design
that handles selected applications' connections as well as DNS, rather than a
DNS-only extension. Apple documents that app-proxy DNS flow handling differs
between low-level DNS APIs and high-level URLSession connections; neither API
surface alone proves complete coverage on the installed OS.

Sources: [Apple DNS Proxy deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment),
[flow metadata](https://developer.apple.com/documentation/networkextension/neflowmetadata),
[App Proxy DNS handling](https://developer.apple.com/documentation/networkextension/neappproxyprovider),
and the independent [DNSMonitor source](https://github.com/objective-see/DNSMonitor/blob/main/Extension/DNSProxyProvider.m)
(the latter was inspected as a reference, not copied or installed).

### Signed runtime counterexample

Cloud Build 28 (`1947b1d3`) was Developer ID signed, notarized, ticket-verified
and activated on the test Mac. Build 26 had established that the saved provider
configuration was absent from the top-level startup options. Build 28 accepted
the single dictionary envelope while preserving the validated deadline and
strict-mode flag, and reached `startProxy` successfully.

With Enhanced TUN and the existing Local DoH profile enabled:

- Selected, signature-verified test clients received real DNS answers through
  proxied DoH for both UDP and TCP. Mihomo's connection readback identified the
  extension process, its explicit Proxy rule and Proxy chain without DIRECT.
- `getaddrinfo` did not preserve the per-app answer separation. For case A,
  selected-first resolution returned public answers and the subsequent control
  query also returned public answers. For case B, control-first resolution
  returned Fake IP and the subsequent selected query also returned Fake IP.
  Simultaneous case-A queries likewise returned the same public answer category.
  These are counterexamples to the promised separation, consistent with shared
  macOS resolver caching; a provider-local cache partition cannot fix them.
- The warm-cache helper call succeeded without a corresponding helper flow
  counter. This does not establish helper DNS identity coverage.
- Three control UDP/TCP cases failed, and other-app forwarding had numerous
  failures. The Local DoH forwarding path also needs further diagnosis before
  another system-wide experiment; no bypass or fallback is silently added.

The probe was disabled, the original `sheng.yaml` restored, and Local DoH health
verified after the run. No strict DNS switch is shipped in the main App. Its
per-app switch controls Mihomo process rules only and states the DNS limitation.
Further strict-DNS work needs a separate connection-level design and runtime
test (for example, assessing App Proxy coverage of high-level resolution), not
promotion of this DNS-only probe or a claim that these tests passed.

### Unified Fake-IP connection checkpoint

The bounded mixed-mode experiment uses the existing managed core and typed
profile transactions. It prepends Fake-IP rules for two fixed public test
suffixes, leaves the original profile untouched, and never flushes macOS caches.
Native DoH returns a Fake IP; a controlled client then opens TLS to that address
while retaining the original hostname for SNI and certificate verification.

All twelve such TLS cases behaved as expected across selected Proxy/control
DIRECT, selected REJECT, and swapped policies. Typed connection snapshots
confirmed process-rule matching and the expected Proxy/DIRECT chains. Rejected
selected connections failed at TLS, while the control continued to return HTTP
200. This establishes the tested Fake-IP **connection routing** path, including
policy changes and rejection, not per-application system DNS isolation.

System `getaddrinfo` queries in both orders and concurrently still returned
public addresses. Fresh random labels returned no address even though the
temporary suffix policy required Fake IP. Direct native Local DoH queries
returned Fake IP. The installed DNS Settings payload has the correct local DoH
URL and omits `SupplementalMatchDomains`, so its configured scope is global.
The reason those system calls did not follow that path is not yet established;
cache flushing cannot be accepted as the fix. Initial curl-based DoH failures
were not reproduced with native TLS and must not be treated as server failures.

The experiment restores `sheng.yaml`, verifies network consistency and native
Local DoH health, and leaves the DNS-only extension disabled. Its scripts and
client live under `experiments/DNSIdentityProbe`; no strict-DNS switch or daemon
change is shipped. Repeating the matrix with Cloud-signed clients installed as
independent `/Applications` apps and launched through Launch Services reproduced
both the successful Fake-IP connection path and the unresolved system-resolver
integration result.

### App Proxy: controlled standalone-client success

Cloud Build 32 (`4face3bd`) adds a bounded `NEAppProxyProvider` to the independent
probe. Its App Rules use the selected client's and helper's actual designated
requirements after validating their expected signing identifiers and team.
The manager requires source-application routing before saving and after
preference readback. Both ordinary `NEAppProxyProviderManager()` and
`forPerAppVPN()` reported source-application routing in a read-only check on this
Mac; a factory difference is **not** an established explanation for prior failure.

Nested signed client apps did not reach the provider, whether launched directly
or through Launch Services. The provider started, but had no selected flow
counters and rejecting its upstream did not block the selected client. These
are failed tests, not successful per-app operation.

Installing the **same signed client bytes** as separate applications under
`/Applications` and launching them through Launch Services changed the result:

- All 25 basic cases passed. The 14 system/UDP/TCP DNS cases retained selected
  public/control Fake-IP answers in both query orders and concurrent system
  lookups, without an explicit cache flush.
- The provider recorded 13 selected flows, 7 selected DNS queries/answers,
  7 selected hostname TCP flows, and 7 SOCKS connections. Typed Mihomo
  snapshots confirmed the extension's explicit Proxy rule and no DIRECT chain.
- With only the extension's route changed to REJECT, selected HTTPS failed and
  control HTTPS still returned 200. The App Proxy session remained connected
  before and after this test, so provider expiration cannot explain the block.
- The original profile and healthy network were restored; both experimental
  configurations were disabled.

This is a positive feasibility result for the tested application installation
and traffic cases. It does not establish a universal strict-DNS guarantee.
The helper's successful calls had no independent `helper` identity counter.
The control's system answers changed from public before activation to Fake IP
while the session was active; DNS-setting scope and coexistence must be resolved
before claiming unaffected unselected applications. IPv6/AAAA/HTTPS records,
browser helpers, application-owned encrypted DNS, network changes and sleep/wake
also remain outside this checkpoint.

### Real AI applications: signed rule set and connection forwarding

Cloud Build 34 (`e8574479`) extends the independent App Proxy host to discover
installed ChatGPT/Codex and Claude applications, native CLIs, signed bundled
helpers, Codex auxiliary runtimes, and code-hash-pinned Claude remote servers.
The tested Mac has 74 validated executable identities, consolidated into 53
NE rules. Terminal/editor rules retain `matchTools` restrictions; the provider
checks the source audit token, designated requirement and exact executable path.
All 13 distinct related executable paths running at the inventory checkpoint
were present. Updates that change helper/CLI paths or ad-hoc code hashes require
re-discovery; this is not a universal promise about arbitrary future children.

Cloud Build 33's initial per-executable rule configuration failed readback and
was disabled automatically. The original two controlled rules still started
successfully. In Build 34, both the two-real-application subset and the full
consolidated set passed disabled-state preference readback. Cross-vendor app
matching is therefore not itself a demonstrated barrier. The correction removes
NE-level per-executable paths, consolidates repeated signing identities, and
compares rule sets without relying on order; executable paths remain enforced
inside the provider. These changes were tested together, so the individual cause
of the original empty-rule result has not been isolated.

Real-mode TCP supports hostnames, IPv4/IPv6 and general ports. UDP uses a bounded
SOCKS5 association to the existing core; DNS uses proxied DoH. Explicit loopback
bridges preserve local callbacks. TCP's setup timeout no longer cuts off an
established stream. The root daemon remains the only managed core owner.

A signed ChatGPT helper completed HTTPS, a public STUN UDP binding check and a
local HTTP callback. Connection snapshots showed the extension's explicit
ProcessName Proxy rule, with no DIRECT chain. Codex CLI completed a read-only
cloud request. Claude CLI's authentication-status command exited nonzero and
cannot establish its network behavior; no chat prompts or account contents were
sent or retained. The observed flow counters were attributed to ChatGPT, so
independent runtime coverage of every Claude/CLI identity is still pending.

The first failure/recovery run used a new helper for each request and failed to
establish immediate recovery; its coarse timeout/invalid-output diagnostic does
not prove a DNS-cache cause. A subsequent test kept the helper alive and retained
one DNS answer only in memory. With the extension route changed to REJECT, the
same helper's HTTPS connection failed with ECONNRESET; restoring Proxy let it
connect again. A fresh DNS/HTTPS request also succeeded, and the session was
connected throughout. No DNS cache was flushed. This establishes tested
connection failure/recovery, not strict per-application DNS isolation.

After the bounded session restored the original profile, an explicit persistent
session was enabled with a separate `ai-app-proxy.yaml` copy containing the
extension's Proxy rule first. Readback, HTTPS, TUN, Local DoH, original source
integrity and network consistency passed. The main App and daemon were not
replaced and no release was published. The experiment has no main-App UI,
login-start integration or guaranteed reconnect after an extension crash.

### App Proxy DNS scope with Local DoH disabled

On the test Mac with Cloud Build 37, Local DoH unprepared and Enhanced TUN enabled,
ChatGPT's selected flows used its configured listener and returned data, but
Claude reported `ERR_NAME_NOT_RESOLVED`. Independent system resolver calls for
`claude.ai`, `api.anthropic.com` and `example.com` also failed. Direct UDP DNS to
the managed Global DNS endpoint `198.18.0.1` succeeded. The system resolver list
contained an additional default supplemental resolver at `1.1.1.1`, published
by App Proxy; direct DNS to that address timed out. The existing runtime health
probe of the managed endpoint still reported healthy, so it does not establish
that application/system resolver selection works.
After the user disabled App Proxy while leaving TUN enabled, Claude recovered,
the supplemental `1.1.1.1` resolver disappeared, and fresh system resolver calls
for all three domains succeeded without flushing the DNS cache.

The provider now leaves `NEDNSSettings.matchDomains` unset. Apple's
[matchDomains documentation](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)
describes the empty-string entry as a default-domain override, and its
[App Proxy sample](https://developer.apple.com/library/archive/samplecode/SimpleTunnel/Listings/AppProxy_AppProxyProvider_swift.html)
sets resolver servers without that override. At the user's request, App Proxy
also replaces its independent Cloudflare DoH path with TCP requests to the
same daemon-owned Mihomo resolver that serves TUN, `127.0.0.1:1153`. There is no
public or system-resolver fallback. This shares the core's DNS policy and
cache; per-application node selection applies to connections, not separate DNS
upstreams. The extension retains bounded requests, cancellation, timeouts and
response framing/transaction checks, and leaves Local DoH unprepared.
This source correction needs signed runtime
validation: verify unselected system DNS with App Proxy both enabled and
disabled, and separately prove Claude and both CLIs reach their own listeners.
Successful ChatGPT traffic or explicit listener probes cannot substitute for
those checks. No DNS cache flush was used for this diagnosis.

Superseded on 2026-11-09 for the transport: the main extension now sends
captured DNS to the root daemon as `dns.resolve` over XPC, and the daemon
queries the same `127.0.0.1:1153` resolver. Only the probe build (without
`MAIN_APP_PROXY`) keeps the TCP path. The resolver sharing and the absence of
public or system-resolver fallback are unchanged.

### App Proxy launch hosts (2026-10-26)

A CLI is attributed to its session's responsible process, and flow divert refuses a
diverted flow with `EPERM` when that process's signing identifier has no rule
(`claude-app-proxy-identity.md`, Launch context). Decision: capture through
launch-host rules for SSH logins and known terminals and editors, each restricted
to the verified tools and carrying `matchPath`. Applications also select other
selected applications' CLIs unless their `capturesLaunchedCLIs` switch is off.
Rejected: removing the tools' own rules (unlisted hosts would connect directly, but
self-responsible tools and Claude Desktop's own Claude Code would lose capture);
a transparent proxy that sees every flow (system-wide interception for a per-app
feature); a wrapper that disclaims responsibility (private SPI, opt-in per command,
kept as a possible addition for unlisted launchers); hosts as authorized records
(sealed-resource validation of IDEs and Xcode every 20 seconds, and a host failure
would fail its application).

## 2026-11-09: Remove Local DoH; Global DNS is owned with TUN; App Proxy DNS goes through daemon XPC

Decision: remove Local DoH (LocalHttpDns) and the DNS integration mode that
chose between it and Global DNS. macOS Global DNS is now owned together with
Enhanced TUN: TUN on sets the PrimaryService DNS to the `127.0.0.53:53` bridge
in front of Mihomo DNS (`127.0.0.1:1153`); TUN off leaves system DNS untouched
while the core keeps serving App Proxy. The App Proxy extension sends captured
DNS to the root daemon as the `dns.resolve` control operation over the existing
Mach service, and the daemon answers from Mihomo DNS. Behavior is specified in
[daemon-and-dns](daemon-and-dns.md).

Reasons:

- A corporate DNS Proxy provider (MTTA, `com.sankuai.sec.mtta.dns`) intercepts
  every port-53 flow, loopback included. It forwards standard QUERY-opcode UDP
  queries, drops STATUS-opcode queries, and breaks TCP DNS to loopback. The
  STATUS-based bridge probe therefore never passed, Global DNS validation timed
  out and TUN rolled back. The bridge probe is now a standard A query for
  `mihomobox-health.invalid`, and App Proxy DNS no longer crosses port 53.
- A split-DNS configuration profile plus a local CA trust anchor in the System
  keychain is a heavy footprint for a DNS path: manual profile approval,
  separate SSL trust, root-held identity files and a TLS server (the SwiftNIO
  SSL dependency and its bundled licenses are removed with it).
- The profile pointed matched domains at a listener that could disappear while
  macOS kept the profile installed.

Rejected: keeping Local DoH alongside the TUN-owned Global DNS. Two DNS owners
retain the mode switch, the profile and trust lifecycle and the 443 listener
supervision, and an installed profile still wins over Global DNS for matched
domains.

Consequences:

- At boot the daemon removes the legacy profile, trust anchor, identity files,
  prepared `.mobileconfig` and DNS IPC directory with fixed commands, and
  re-runs that cleanup when TUN is enabled before absence is confirmed. The
  installer's uninstall keeps the same removal as a fallback. `daemon.json`
  drops `localDoH`, and DNS ownership follows the last saved TUN choice.
- The daemon classifies the extension by signing identifier plus certificate
  family; that role may call only `dns.resolve`, and no other peer may call it.
  Queries are bounded, resolved outside the lifecycle lock and not logged.
- Known limitation: a truncated Global DNS answer cannot be retried over TCP
  while MTTA is active.
- Not yet verified on a device: whether per-app DNS from `NEDNSSettings`
  reaches the App Proxy while MTTA's DNS Proxy is active; whether the
  `mach-lookup` temporary exception is honored for the sandboxed system
  extension; the TCP-retry limitation above.

## 2026-11-09: App Proxy `matchTools` only on responsible code

ChatGPT, Claude and the JetBrains Team ID default (122 executables) produced a
781915-byte configuration; NetworkExtension refuses above 512 KiB. Every rule
listed its whole category, 4642 entries in 94 rules. Sharing tool objects did not
help: the configuration crosses XPC before it is measured.

Decision: a rule lists its category (and, for launchers, the verified CLIs) only
when one of its executables can be a responsible process: code outside any bundle,
or the main executable of a top-level application or a login item. Other bundled
code matches only itself (580 entries). The host's size check measures detached
rule copies and refuses above 440 KiB.

Trade-off: a helper that LaunchServices or launchd starts as its own responsible
process keeps its own flows, but code it starts connects directly instead of
through its application's route. None of the current targets ships an embedded
login item or launchd agent. Rejected: shortening tool requirements (weaker
identity), and moving the duplicated `targets` list out of the provider
configuration (a provider protocol change for about 60 KB).

## 2026-11-09: App Proxy rules scale per application; updates are event driven

Each Team ID policy multiplied the configuration: every responsible rule of a
category listed every executable of that category, and launchers added every CLI.
Locally ChatGPT and Claude produced 62 rules with 513 tool entries; ChatGPT alone
had six responsible rules of 55 entries each. Vendors update their applications and
CLIs in place, which left new versions unrouted until the next 20 s pass.

Decision:
- A responsible rule lists its own top-level application's code, code outside any
  bundle, and, for launchers, the verified CLIs. Applications of the same category
  start each other through LaunchServices, which makes the started one responsible.
- Over the 440 KiB budget the host drops the launched-CLI tier
  (`reducedCoverage=launchedCLIs`) instead of failing. Launch hosts keep their CLIs.
- FSEvents on the selected applications' discovery roots wakes maintenance.
- Mihomo process routes are pushed before the NetworkExtension configuration is
  saved, so TUN and the system proxy route a new version first.
- Path-less tool entries per vendor identifier are an experiment behind
  `appProxy.toolsByIdentifier.experiment`, off by default.

Trade-off: an application that execs another application's bundled code directly
(not through LaunchServices) leaves that code unmatched; it connects directly, or
through Mihomo with TUN on. In the reduced tier, CLIs that another selected
application starts have the same fallback. Rejected for now: moving CLIs to Mihomo
over TUN only (reverses the 2026-10-26 launch-host decision), and a transparent
proxy (captures all traffic and coexists poorly with the MTTA DNS proxy and content
filter).

## 2026-11-09: Supervise the Global DNS bridge listeners; keep the alias on rollback

On m4pro, during `pmset sleepnow` churn, a failed DNS apply rolled back and
removed `127.0.0.53` while queries were in flight. The pending replies failed
with `EADDRNOTAVAIL`; SwiftNIO closes a datagram channel on that error without
calling `errorCaught`, so the UDP listener vanished with no log line. The TCP
listener and the kernel socket binding both survive alias removal. MTTA's DNS
Proxy answered the bridge probe with SERVFAIL, the probe accepts any RCODE, and
the observer re-pointed system DNS at the dead bridge every 40–60 s until the
agent was restarted.

Decision: the agent owns the bridge listeners as one supervised unit. An
unexpected close is logged and triggers an immediate evaluation; every
evaluation rebinds a closed listener; bridge readiness and DNS acquisition
require both listeners open; a bridge-unhealthy rollback rebuilds them; and a
runtime rollback no longer removes the alias while the listeners are bound to
it. Stop and resident transitions remove it as before. The `1054` original-DNS
escape has the same exposure to any other unrecoverable send error, so its
listeners are supervised the same way but rebind themselves with backoff: its
address never disappears, and a plain forwarder has no observer to ask.

Rejected: tightening the probe to NOERROR/NXDOMAIN. A profile's Fake-IP filter
can send the health name to upstream resolvers, which answer SERVFAIL while
offline, and the agent's own listener state is the direct evidence. Also
rejected: patching SwiftNIO's recoverable datagram errors, which would put a
fork of a pinned dependency on the DNS path.

