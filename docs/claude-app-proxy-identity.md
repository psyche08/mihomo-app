# Claude CLI App Proxy identity and code access

## Status and evidence boundary

This change is based on `b8f582044d58306315f83d80059e12ce471b8490` (including
Cloud 49's physical-interface bypass fix), not just the investigated
`80c220877856aff4cbbf7da79035494771683d7c`. It does not change Mihomo's Rule,
Global or Direct routing semantics, SafeDNS, or the shared DNS forwarding path.

The evidence directory `m4pro:/private/tmp/claude-dns-layer-20261023/` was present
and its report and summarized permission results were read. The historical
report contains framework `SecCodeRef`/EPERM and validation-aborted observations
before the provider callback, and successful host-side code checks. These support
sandbox file access as the failure layer. They do **not** supply a historical
file-read syscall trace, nor do they attribute every observed DNS flow to the
target CLI. SafeDNS requests from other Claude helpers are not evidence that
`com.anthropic.claude-code` fell back to SafeDNS. Raw logs and private application
paths from that investigation are not copied into the repository.

**Implementation and local evidence are not a production acceptance result.**
The real Developer ID XPC service, Powerbox interaction, root NetworkExtension
consumer inside NE, login/user-switch lifecycle and Claude API recovery remain deployment gates.
A separate ad-hoc sandbox receiver running as root did consume a user-issued
read-only grant successfully; this narrows the uncertainty but does not validate NE.
If the public bookmark mechanism fails those gates, do not ship or weaken the
sandbox. Take the minimal signed reproducer to Apple Developer Technical Support.

On 2026-10-24, the real Claude Desktop CLI code package on m4pro passed strict
signature validation in independent same-user and UID 0 sandbox receivers when
the issuer delegated the exact version's `claude.app` read-only. Executable and
Info.plist write opens and parent-directory listing remained denied. Earlier
exact-executable plus three exact-metadata grants failed with `-67030`
(`errSecCSInfoPlistFailed`); no failing internal syscall was captured. The issuer
used a test-only read exception, not production Powerbox. This establishes a
package-scope candidate, not NE framework acceptance or Claude API recovery.

## Actual pipeline and responsibilities

| Stage | Owner and check | What success establishes |
|---|---|---|
| Discovery | Unsandboxed per-user host; bounded code trees, explicit executable selections | A candidate path exists in a selected application's inventory |
| Static identity | `AppProxyCodeIdentity.inspect`; strict/all-architecture signature, expected ID/team, Apple anchor, designated requirement, cdhash and before/after file stamp | The inspected on-disk executable satisfies the enrollment policy |
| Durable consent | Per-user `MihomoCodeAccess.xpc`, sandbox and user-selected **read-only** entitlement, `NSOpenPanel`, broker-owned app-scoped bookmark | Consent for one version's nearest `.app` package or standalone executable |
| Ephemeral delegation | Broker exports one implicit package/file bookmark per executable; host transports opaque data | A candidate process-local capability, not proof the provider can consume it |
| Provider preparation | `AppProxyAccessLease` resolves/starts scope; reads and verifies every file; rejects writable access | Provider-local code access is established before interception rules are published |
| OS rules | Exact executable paths + OS designated requirements; explicit `matchTools`; save/reload/readback + rules digest | Persisted policy matches the approved identity generation |
| NE framework | Apple's process/flow code validation, outside our callback | A correlated `handleNewFlow` receipt proves that flow reached the provider; host verification alone does not |
| Provider runtime | Audit token including owner UID/PID version; `SecCodeCopyGuestWithAttributes`, runtime DR, canonical path, cdhash and current file stamp | The actual running source matches an authorized executable in the active/prepared generation |
| DNS | Existing bounded `AppProxyDNSRequest` to shared Mihomo TCP `127.0.0.1:1153` | `dnsAnswered` means a response was obtained for this flow, not necessarily a successful DNS answer code or API request |
| Proxy | Existing per-application listener, mode/rules and original-interface bypass | Upstream establishment is a transport stage; application/API success must be observed separately |

The root daemon remains the sole owner of Mihomo. No new daemon filesystem
operation, shell command interface, controller secret, or second core is added.
`127.0.0.53:53`, original-DNS escape `127.0.0.1:1054`, and shared Mihomo DNS
`127.0.0.1:1153` retain their distinct roles.

## Permission design and alternatives

Chosen candidate: a no-network, per-user sandboxed XPC broker. Host and broker
mutually require the same Developer ID leaf and exact peer bundle identifier;
the broker also requires the same non-root effective UID. The host never mints
implicit file grants. The broker stores its own app-scoped read-only consent and
mints fresh **exact-package/file** implicit grants for a bounded snapshot. Only
the nearest enclosing `.app` code package, or an explicit standalone executable,
may be selected. Updater version trees (`Claude/claude-code`,
`.claude/remote/ccd-cli`, `.local/share/claude/versions`) are discovery locations,
never authorization roots. A new version at a new path may require fresh consent.
No home directory, entire Application Support directory, Full Disk Access,
temporary file exception, or network entitlement is granted to production code.
The provider has no arbitrary-path read RPC. Its snapshot v2 accepts a package
bookmark only when its path is the executable's exact nearest `.app`, with the
executable under `Contents/`; standalone code still requires an exact-file grant.
Executable and metadata write access and writable package roots are rejected.
The broker's v2 consent store does not reuse earlier broader code-root grants.

Apple describes implicit security-scoped bookmarks for cross-process delegation
in [On File System Permissions](https://developer.apple.com/forums/thread/678819).
The public `NSURL.h` documents that implicit security scope is ephemeral and
expires no later than reboot. Durable consent stays in the creating broker;
after restart the broker resolves its own app-scoped bookmark and issues fresh
grants. Stale bookmarks never fall back to an unscoped path or silently broaden
consent. A new approval may be needed after moved roots, consent loss, or app
signing changes. Old app-scoped bookmarks are not transferred to root.

Alternatives investigated:

* **Unsandboxed host → implicit bookmark:** rejected. A same-UID sandbox
  receiver could both read and open the fixture for writing, including when the
  host first resolved a read-only app-scoped bookmark. This is not a read-only
  delegation mechanism. Production checks reject writable grants.
* **Document-scoped bookmarks:** rejected for this target layout. Apple's
  [document-scope restrictions](https://developer.apple.com/forums/thread/798402?answerId=855880022)
  exclude directories and Library targets, including user Library. A local
  `/private/tmp` fixture was rejected; a permitted development-tree file worked
  read-only. Neither result establishes access to Claude's Library code tree.
* **Sandboxed read-only issuer → implicit exact-file bookmark:** local
  independent sandbox apps passed read-only/sibling isolation checks. The test
  issuer uses a test-only exact-file read exception, not Powerbox; it proves
  capability attenuation in that fixture, not the production consent path.
  The same exact-file grant also passed in an independent **UID 0** sandbox
  receiver after the user issuer exited: initial read denied, authorized read
  succeeds, write and sibling read denied. No system extension was involved.
* Sandbox removal, broad directory exceptions, general root reads and guessing a
  SafeDNS bypass are not part of this design.

A failed `startAccessingSecurityScopedResource()` is not alone evidence of
failure: static sandbox permissions can make a dynamic grant unnecessary.
Actual file access and signature validation are authoritative. Successful starts
are balanced on rollback, replacement and provider stop. A write-access probe
opens without truncate and writes no bytes; even opening for write can change
file metadata, so the negative fixture issues new snapshots in a controlled
order. Never use a writable grant as a successful production authorization.

## Discovery and update trust

Default Claude code discovery covers:

* `/Applications/Claude.app` and `~/Applications/Claude.app`, including signed
  helpers belonging to Team `Q6L2SF6YDW`;
* `~/Library/Application Support/Claude/claude-code/` and
  `~/.claude/remote/ccd-cli/` under the Claude Desktop application route;
* `~/.local/share/claude/versions/` and conventional `claude` installer entries
  under the standalone CLI route.

Downloaded/standalone Claude CLI must have ID `com.anthropic.claude-code`, Team
`Q6L2SF6YDW` and an Apple-anchored valid signature. All discovered versions retain
separate exact paths; choosing a single "latest" version would lose live older
sessions. `.claude/remote/srv` ad-hoc code is not automatically enrolled. Explicit
user enrollment remains possible and pins its identity; changes to code without
a Team ID require manual reauthorization.

Scans do not follow symbolic links and reject roots reached through links. A
conventional explicitly named installer link is resolved to one canonical file
and then vendor-checked; a scanned tree cannot escape through links. Every
security-sensitive open uses Darwin's public `O_NOFOLLOW_ANY` so all path
components are protected, without requiring sandbox permission to open ancestor
directories. Foundation's filesystem canonicalization can rewrite `/private/tmp`
to `/tmp`; capability paths use lexical validation and exact resolved URLs.
File stamps include device, inode, size, modification and change timestamps.
Before/after static checks, provider-local rechecks and runtime code identity
reduce replacement races; a path string alone is never authorization.

Custom application helpers must match their selected main executable's publisher
when it has a Team ID. Automatic refresh cannot change an existing path's signing
identifier, publisher, designated requirement or ownership category. New custom
helpers require an already approved publisher. Signature/certificate-policy
changes request approval rather than silently widening update trust.

Each scan is bounded (20,000 entries per tree, depth 16, 512 executable records,
8,192 root-rule tool entries). Exclusions have bounded category/reason counts.
The inventory is not proof of OS capture. `matchTools == nil` means all spawned
helpers according to `NEAppRule.h`; every generated root rule explicitly lists
verified tools. Terminal/editor rules likewise select exact verified tools and
never route the entire terminal. Nil and empty tool lists have distinct digests.
Apple's responsible-application matching and nested helper behavior must still
be exercised with real Claude processes.

## Generation, lease and recovery protocol

The v4 provider configuration binds owner UID, generation UUID, paths/DR/hash/file
stamps, snapshot-v2 package/file grants, route ports, bypass policy and a canonical digest of
OS app rules. Both host readback and provider parsing validate the manifest.
There is no claim of a single atomic transaction across macOS preferences and
the provider; explicit staging and verified disable contain ambiguous outcomes.

Initial enable obtains consent, starts the provider with **empty app rules**,
waits for provider-local validation, publishes rules, reads them back and checks
the provider generation again. Empty-rule startup and live rule publication are
mandatory signed-NE acceptance gates. Existing v1–v3 preferences require explicit
reactivation; they are not silently treated as authorized v4 preferences.

While enabled, the host re-discovers every 20 seconds, independent of the open
page or its 30-second display cache. An unchanged set renews only after provider
file validation. A changed set obtains fresh broker grants and follows:

1. `prepare(expectedCurrent, next)`: validate fresh provider-local grants; keep
   both old and next sets available for flow validation during publication.
2. Save next manifest and OS rules; reload and verify all fields and rule digest.
3. `commit(next)`: revalidate files, compare-and-swap generation, then release
   superseded grants. Prepared state expires after 30 seconds.
4. On failure, restore previous persisted manifest/rules before abort. If any
   result is uncertain, disable interception and verify saved disabled state and
   tunnel disconnection. An unverifiable disable is shown as `rollbackUnverified`,
   requiring an operator check rather than a green connection badge.

Provider restart uses fresh broker grants and empty-rule bootstrap before
restoring capture rules. If the host is absent, a lease expires after 90 seconds
(checked every 5 seconds) and the provider cancels the tunnel. Fast user switching
is checked before new flows and on that timer; a grant from another console UID
cannot renew. Ordinary app exit therefore does not promise background App Proxy
operation; Mihomo/TUN daemon lifetime is unchanged. Automatic recovery requires
the authorized user's host/broker. Failed authorization disables the manager and
requires explicit retry, rather than endlessly restarting with stale grants.

Live already-accepted streams survive normal generation replacement; authorization
is checked at new-flow admission. Multiple version files stay enrolled while
present. If an updater **unlinks a still-running old executable**, runtime and
framework validation of a *new* flow may fail; there is no supported claim that
an obsolete pathname can be recreated or substituted safely. Existing streams
can complete, and the UI should direct the user to restart that old Claude
session. This is an explicit pending compatibility test, not a solved guarantee.
New executable versions are not covered until the next successful refresh; during
that interval they use normal OS routing if they do not match an existing rule.
App Proxy is not a system-wide kill switch.

Broker consent persists for selected roots; removed roots are pruned at the next
broker request. Scope leases end with the provider process/stop and the broker
balances its explicit starts, but macOS may retain Powerbox permissions for the
broker process lifetime. Disabling App Proxy is not a claim of permanent consent
revocation. Authorization loss and fresh login/reboot must be tested explicitly.
No private sandbox token revocation API is used.

## Diagnostics and privacy

The page separates OS connection state, verified executable access, discovery
exclusions and application traffic evidence. "Code access verified" does not
mean "Claude API online". Permission, stale consent, signature, path escape,
file replacement/deletion, undiscovered runtime identity, UID and generation
mismatch have distinct fixed failure codes. Framework failures before the
callback require narrowly correlated OS diagnostics; absence of receipts alone
does not identify DNS or permission as the cause.

Provider receipts retain at most 64 entries in memory: flow UUID, PID, PID
version, policy generation, monotonic timestamp and a fixed stage. Stages distinguish callback entry,
provider validation, DNS response/failure and SOCKS/upstream failures. Receipts
contain no arguments, query names, destinations, tokens, packets, subscription
URLs or credentials. Bounded counters are rate-reduced in unified logs. Process
paths/signature metadata are displayed only in the requested local inventory;
bookmark bytes are capabilities, never diagnostic output or release artifacts.
A `dnsAnswered` receipt and successful SOCKS connection do not prove TLS/API
success, and a different Claude Helper PID does not prove the target CLI works.

## Validation matrix

Local tests run on Apple Silicon macOS 27.0.1 / Xcode SDK 27; production minimum
remains macOS 14. Results on older supported OS versions are not inferred.

| Layer / case | Local evidence | Remaining acceptance |
|---|---|---|
| Manifest and rules | Swift tests: bounds, duplicate paths, zero owner UID, legacy/v4 binding, nil-vs-empty rule digest, stale generation/replay/abort/expiry | Real NE preference serialization and live rule mutation |
| Files and signing | Real system signature inspection; wrong expected publisher/ID; unsigned file; leaf/ancestor symlink; atomic inode replacement; deletion | Vendor-signed hostile fixtures and process-replacement races in real NE |
| Read-only capability | Two independent ad-hoc sandbox apps: initial read denied, grant read succeeds, write and sibling read denied; fresh receiver process; multiple versions; forged ID and replaced file denied; separate UID 0 receiver confirms read-only cross-UID access | Powerbox issuer, Developer ID peer authentication, actual root NE consumer and console-user switch |
| Over-broad grant | Writable implicit grant from unsandboxed issuer rejected | Assert production provider remains read-only on every supported OS |
| Update trust | Existing identity/publisher changes rejected; ad-hoc hash change requires approval | Actual Claude automatic upgrade, coexistence and old live session |
| Restart/authorization | Invalid capability rejected; same-boot new receiver accepts a valid capability | Reboot, logout/login, stale/moved grant, app update, XPC interruption and consent loss |
| DNS/transport | Existing shared-DNS and TCP/UDP/interface-binding regression tests | Actual target CLI's DNS callback, response and API recovery |
| Bundle | Generated project/source membership, local compile and structural bundle validation | Cloud Developer ID signing, notarization and embedded service entitlements |

`Tests/test_app_proxy_code_access.sh` uses a temporary directory, test-only
ad-hoc signed sandbox applications and a harmless C fixture. It neither runs
Claude nor installs/starts a system extension. Optional `APP_PROXY_TEST_ROOT=1`
adds the root receiver using `sudo -n`; it never prompts for a password. The full `scripts/validate.sh`
also covers Swift, pinned Sparkle/MetaCubeXD, existing shell/transport tests,
local development bundle assembly and installer **dry-run**; it does not grant
permission to install, publish, or modify network settings.

## Initial exact-file validation record — 2026-10-24

Final `scripts/validate.sh` completed with exit status 0 on the working-tree
implementation. Four Swift test products reported 372 cases: 365 passed,
7 intentionally skipped, 0 failures. The skips are existing privileged
SystemConfiguration/loopback and optional pinned-validator/GeoSite integration
cases; they are not counted as validated. App Proxy configuration, ten shared
DNS cases, interface-bound TCP/UDP transport, read-only sandbox integration,
bundle construction/inspection and installer dry-run passed. `git diff --check`
was clean. The project generator/check used local `xcodeproj` 1.27.0.

The separate `APP_PROXY_TEST_ROOT=1 Tests/test_app_proxy_code_access.sh` run also
completed with exit status 0. Its UID 0 receiver reported `initiallyDenied`,
`readValidated`, `writeDenied` and `siblingDenied` all true. This was a same-boot
exact-file fixture issued by a sandbox with a test-only read exception, **not**
a Powerbox-issued production grant or a live NetworkExtension flow. No reboot,
user switch, extension installation/activation, Cloud build, Claude action or
network configuration mutation was performed. No production artifact was signed
or published.

## Package-scope follow-up — 2026-10-24

Full `scripts/validate.sh` passed again after snapshot-v2 package/file grants:
373 Swift cases, 366 passed, the same 7 skips, no failures; shell/transport,
pinned artifacts, development bundle and installer dry-run checks passed.
The root-enabled sandbox suite additionally covered signed bundle metadata
replacement and rejection of writable package grants. The production candidate
shared implementation also passed against m4pro's real Claude CLI in same-user
and root sandbox receivers, including denial of an existing outside file.
Cloud Build 50 (the earlier exact-file candidate) was signed/notarized but never
installed because its real bundled-CLI sandbox test failed. A new Cloud build
is required for this follow-up. NE/Powerbox/actual Claude API acceptance remains
pending; no production acceptance is inferred from these tests.

## Authorized deployment experiment (not executed)

Use a dedicated test Mac/account only after explicit deployment authorization.
Do not infer that prior build installations or earlier permissions authorize
this experiment. Production signing/build/notarization must use Xcode Cloud;
never unlock a keychain, re-sign or repackage a production App locally.

1. Record test OS/build, current signed MihomoBox baseline/hash and current
   App Proxy state. Keep a rollback copy using the approved installation
   procedure. Save only necessary configuration locally with restrictive access;
   do not print subscriptions, tokens or proxy credentials. Record existing
   TUN/system proxy/SafeDNS/Claude state; preserve it throughout the experiment.
2. Build this exact source through Cloud and verify the original artifact,
   nested XPC service and extension use the expected leaf, sandbox and exact
   production entitlements. Installation/ZIP extraction, where needed, requires
   the explicit repository-policy exception. Do not substitute an ad-hoc build.
3. With App Proxy initially off, enumerate the actual Desktop CLI, standalone
   CLI and remote CLI paths/signing identities. Record PID **and PID version**
   of the target started by Claude Desktop without recording command arguments.
   Confirm the code ID/team; do not use a helper name or parent PID as identity.
4. Enable only the test selection. Exercise broker Powerbox consent and its
   cancellation. Confirm the real root provider can read each exact file, cannot
   write it or read an unselected sibling, and does not publish rules on denial.
   Verify empty-rule startup and `matchTools` behavior on this OS before normal
   routing tests. No broad permissions or sandbox-disable workaround is allowed.
5. Trigger a real, operator-approved Claude Desktop operation using its built-in
   CLI. Correlate time window, PID/PID version, policy generation and flow UUID:
   framework validation reaches `handleNewFlow`; `providerValidated` follows;
   the same process produces `dnsAnswered`; transport reaches the configured
   route; the operation visibly completes against the real API. DNS and API may
   use separate flow UUIDs, so correlate by audited process and generation, not
   by adjacent log lines. A framework error must refer to this target before
   assigning root cause. If there is no actual API operation, mark E2E untested.
6. Repeat with new/old version coexistence and a live old session, a controlled
   vendor update, extension restart, host exit/relaunch, reboot, logout/login,
   fast user switch and grant loss. Use signed test fixtures for wrong team/ID,
   symlink escape and same-path replacement; **do not tamper with Claude's
   signed installation**. Prove failed prepare/publish/commit/ack leaves the old
   valid generation or verified disabled interception. Test after lease expiry.
7. The acceptance record must list observed, inferred and untested results
   separately. A curl/dig check can be a control, never the target E2E proof.

Rollback: disable only MihomoBox App Proxy through its UI; verify saved disabled
state and tunnel disconnect. If `rollbackUnverified`, inspect its specific VPN
and network-extension status with the operator before proceeding. Restore the
approved baseline signed app/configuration through the existing installer
procedure, preserving other VPNs, TUN, Claude and SafeDNS settings. Do not restore
an old v4 ephemeral bookmark as durable authorization; leave App Proxy off until
a fresh approved enrollment succeeds. Remove only experiment-owned fixtures and
bounded diagnostics. Report any residual enabled extension or unresolved network
state rather than declaring rollback complete.
