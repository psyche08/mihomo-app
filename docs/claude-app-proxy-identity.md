# Claude CLI App Proxy identity and code access

## Status and evidence boundary

This change is based on `b8f582044d58306315f83d80059e12ce471b8490` (including
Cloud 49's physical-interface bypass fix), not just the investigated
`80c220877856aff4cbbf7da79035494771683d7c`. It does not change Mihomo's Rule,
Global or Direct routing semantics, SafeDNS, or the shared DNS forwarding path.

The evidence directory from the 2026-10-23 DNS-layer run on the test Mac was present
and its report and summarized permission results were read. The historical
report contains framework `SecCodeRef`/EPERM and validation-aborted observations
before the provider callback, and successful host-side code checks. These support
sandbox file access as the failure layer. They do **not** supply a historical
file-read syscall trace, nor do they attribute every observed DNS flow to the
target CLI. SafeDNS requests from other Claude helpers are not evidence that
`com.anthropic.claude-code` fell back to SafeDNS. Raw logs and private application
paths from that investigation are not copied into the repository.

The current design is described in *Identifier and Team policy (owner decision,
2026-11-09)* at the end of this document; the dated sections before it are history.

**Implementation and local evidence are not a production acceptance result.**
The real Developer ID XPC service, Powerbox interaction, root NetworkExtension
consumer inside NE, login/user-switch lifecycle and Claude API recovery remain deployment gates.
A separate ad-hoc sandbox receiver running as root did consume a user-issued
read-only grant successfully; this narrows the uncertainty but does not validate NE.
If the public bookmark mechanism fails those gates, do not ship or weaken the
sandbox. Take the minimal signed reproducer to Apple Developer Technical Support.

On 2026-10-24, the real Claude Desktop CLI code package on the test Mac passed strict
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
| Discovery | Unsandboxed per-user host: LaunchServices lookup of the listed identifiers, `.app` bundles (Info.plist only) up to three levels below a granted folder, and known launch hosts; no executable enumeration | Which top-level applications and launch hosts get an OS rule of their own |
| Static identity | When an application is added: Team ID and signing identifiers of the chosen code (`AIAppTargets.codeIdentity`). Each pass reads only the embedded signature of top-level main executables | The policy names its publishers and identifiers |
| Durable consent | Host confirmation sheet listing Team IDs, identifiers and code folders; per-user `MihomoCodeAccess.xpc` stores the approved folders | Consent for one application's folders, including ones that do not exist yet |
| Ephemeral delegation | Broker mints one read-only implicit bookmark per existing approved folder; policy v5 carries them; host transports opaque data | A candidate process-local capability, not proof the provider can consume it |
| Provider preparation | `AppProxyFolderAccess` resolves each grant at its exact path, starts its scope and opens the folder read-only, without following links | Code in granted folders is readable inside the provider sandbox before rules are published |
| OS rules | One path-less tool entry per identifier (`identifier` + Team requirement); one rule per top-level application or launch host carrying all tool entries; save/reload/readback + rules digest | Persisted rules match the approved policy |
| NE framework | Apple's process/flow code validation, outside our callback | A correlated `handleNewFlow` receipt proves that flow reached the provider; host verification alone does not |
| Provider runtime | Audit token owner UID; `SecCodeCopyGuestWithAttributes` reports the flow's signing identifier; that identifier's route lists the code's Team ID; `SecCodeCheckValidity` with the route's Team requirement | The running source is valid code of a listed publisher under a listed identifier |
| DNS | Bounded `AppProxyDNSRequest` to the root daemon's `dns.resolve` XPC operation (extension-only), which queries shared Mihomo DNS `127.0.0.1:1153`; fails closed | `dnsAnswered` means a response was obtained for this flow, not necessarily a successful DNS answer code or API request |
| Proxy | Existing per-application listener, mode/rules and original-interface bypass | Upstream establishment is a transport stage; application/API success must be observed separately |

The root daemon remains the sole owner of Mihomo. No new daemon filesystem
operation, shell command interface, controller secret, or second core is added.
`127.0.0.53:53`, original-DNS escape `127.0.0.1:1054`, and shared Mihomo DNS
`127.0.0.1:1153` retain their distinct roles.

## Permission design and alternatives

Chosen candidate: a no-network, per-user sandboxed XPC broker. Host and broker
mutually require the same Developer ID leaf and exact peer bundle identifier;
the broker also requires the same non-root effective UID. The host never mints
implicit file grants. The broker stores its own read-only consent per application
folder and mints fresh implicit **folder** grants for the policy. A folder is
refused when it is writable by the user, reached through a link, or a whole home,
Library, Application Support, Documents, Desktop or Downloads folder, `/Users`,
`/opt`, `/opt/homebrew`, `/usr` or `/usr/local`. Since 2026-10-26 only the broker
holds read-only temporary exceptions for the home directory, `/opt/homebrew/` and
`/usr/local/` (see *Scan-and-confirm consent*). The provider holds no file
exception; nothing is writable; no Full Disk Access or network entitlement is
granted to production code. The provider has no arbitrary-path read RPC: it opens
only the folders its policy names, each through its grant.

Folder grants remain necessary under the identifier policy. NetworkExtension
validates a diverted process's code inside the provider's sandbox; code the
provider cannot read fails with `Failed to get a SecCodeRef` before the provider
callback, and the flow is dropped. The provider's sandbox reads `/Applications`,
`/System`, `/Library` and the system `bin`, `sbin` and `libexec` folders without a
grant. Code under the home directory or Homebrew needs a folder grant.

NetworkExtension rejects a saved configuration above 512 KiB. The rules hold one
shared tool entry per signing identifier and one rule per top-level application or
launch host, so they grow with identifiers plus applications, not with their
product. ChatGPT, Claude and JetBrains with the known terminals, editors and SSH
fit in a few tens of KiB. The host measures the provider configuration plus
detached rule copies before saving, refuses above 440 KiB with `capacity`, and logs
`event=app_proxy_configuration_size`.

Updates are event driven. FSEvents watches `/Applications`, `~/Applications` and the
selected applications' existing code folders with a 3 s latency; a change wakes the
maintenance pass at once, and the periodic pass runs every 3 minutes as a fallback.
A pass looks applications up again and compares a metadata stamp of the top-level
executables and granted folders; only a change re-mints grants and republishes.
Before saving a new NetworkExtension configuration the coordinator pushes the Mihomo
process routes, so a new version's TUN and system-proxy traffic is routed while
NetworkExtension prepares.

Apple describes implicit security-scoped bookmarks for cross-process delegation
in [On File System Permissions](https://developer.apple.com/forums/thread/678819).
The public `NSURL.h` documents that implicit security scope is ephemeral and
expires no later than reboot. Durable consent stays in the creating broker as a
list of approved folders; after restart the broker checks each folder again and
mints fresh grants. A stale grant never falls back to an unscoped path or silently
broadens consent. Approvals are not transferred to root.

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

The default Claude entry lists Team `Q6L2SF6YDW`, the identifiers of Claude Desktop,
its helpers and `com.anthropic.claude-code`, and the folders
`~/Library/Application Support/Claude/claude-code`, `~/.claude/remote/ccd-cli` and
`~/.local/share/claude/versions`. A new version in one of them is covered without
new consent: its identifier and publisher are already listed, and its folder is
already granted. ChatGPT and JetBrains entries work the same way.

Trust is the publisher: any valid code that carries a listed identifier and is signed
by the route's Team ID through Apple's Developer ID or Mac App Store chain
(`anchor apple generic and certificate leaf[subject.OU] = "TEAM"`). Ad-hoc and
unsigned code has no Team ID and cannot be routed; `.claude/remote/srv` ad-hoc code
is not captured. Platform binaries (`/usr/bin/curl`) carry no Team ID either.
A (Team ID, identifier) pair belongs to one entry; an identifier several publishers
use (`node`) belongs to each publisher's entry and admits each of them.

Discovery never validates or hashes code; NetworkExtension and the provider validate
the running process. Bundle searches skip links and hidden entries and read at most
4,000 entries per folder. A bundle found in a granted folder but not yet known to
LaunchServices is registered with `LSRegisterURL`, because NetworkExtension resolves
a path-less rule through LaunchServices. Grant paths use lexical validation and
`O_NOFOLLOW_ANY`; Foundation's canonicalization can rewrite `/private/tmp` to
`/tmp`, so links in a folder path are refused rather than resolved.

## Generation, lease and recovery protocol

The v5 provider configuration binds owner UID, generation UUID, the routes (Team IDs
and identifiers per category), folder grants, a code stamp, route ports, bypass
policy and a canonical digest of OS app rules. Both host readback and provider parsing validate the manifest.
There is no claim of a single atomic transaction across macOS preferences and
the provider; explicit staging and verified disable contain ambiguous outcomes.

Initial enable obtains consent, starts the provider with **empty app rules**,
waits for provider-local validation, publishes rules, reads them back and checks
the provider generation again. Empty-rule startup and live rule publication are
mandatory signed-NE acceptance gates. Preferences from earlier versions require
explicit reactivation; they are not silently treated as authorized v5 preferences.

While enabled, the host renews the lease every 20 seconds; renewal checks the
generation and owner only and reads no files. The maintenance pass runs at launch,
on FSEvents changes and every 3 minutes. An unchanged policy and code stamp keep the
current generation. A changed one obtains fresh broker grants and follows:

1. `prepare(expectedCurrent, next)`: validate fresh provider-local grants; keep
   both old and next sets available for flow validation during publication.
2. Save next manifest and OS rules; reload and verify all fields and rule digest.
3. `commit(next)`: compare-and-swap generation, then release superseded grants.
   Prepared state expires after 30 seconds.
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
is checked at new-flow admission. Every version of listed code is covered by
identifier, including an old one that is still running. A grant follows the folder
it was minted for: a vendor that replaces a granted folder (rather than writing into
it) leaves the grant on the old folder, the code stamp changes, and the next pass
mints a fresh grant. Until then, code in the replaced folder uses normal OS routing.
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
| Policy and rules | Swift tests: v5 bounds, unique (team, identifier) pairs, zero owner UID, older routings rejected, extra/missing keys, builtin and custom ports, path-less tool entries, one OR'd rule for copies, rules digest, stale generation/replay/abort/expiry | Real NE preference serialization and live rule mutation |
| Folders and signing | Team/identifier/folder syntax; requirements compile; writable, linked, file and missing folders rejected; forged grant is stale; ad-hoc and platform code have no identity | Vendor-signed hostile fixtures in real NE |
| Read-only capability | Two independent ad-hoc sandbox apps: initial read denied, folder grant reads and validates code, write, create and sibling read denied; fresh receiver process; relabelled and replaced folder stale, fresh grant works; separate UID 0 receiver confirms read-only cross-UID access | Powerbox issuer, Developer ID peer authentication, actual root NE consumer and console-user switch |
| Over-broad grant | Writable implicit grant from unsandboxed issuer rejected | Assert production provider remains read-only on every supported OS |
| Update trust | A new version under a listed identifier and Team ID needs no approval; a forged Team ID gets no rule | Actual Claude automatic upgrade, coexistence and old live session |
| Restart/authorization | Invalid capability rejected; same-boot new receiver accepts a valid capability | Reboot, logout/login, stale/moved grant, app update, XPC interruption and consent loss |
| DNS/transport | Existing shared-DNS and TCP/UDP/interface-binding regression tests | Actual target CLI's DNS callback, response and API recovery |
| Bundle | Generated project/source membership, local compile and structural bundle validation | Cloud Developer ID signing, notarization and embedded service entitlements |

`Tests/test_app_proxy_code_access.sh` uses a temporary directory, test-only
ad-hoc signed sandbox applications and a harmless C fixture in a granted folder. It neither runs
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
shared implementation also passed against the test Mac's real Claude CLI in same-user
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

### Tart consent UI regression (2026-10-24)

Build 52 discovers the unmodified Anthropic-signed Desktop CLI package under
the test user's `Library/Application Support/Claude/claude-code` tree and
starts the production sandboxed XPC broker. On macOS 26.6.2 (25G83), its
modeless Powerbox panel appeared behind the host window and could not complete
the selection. The host reported `needsAuthorization`; no system extension or
interception rules were installed by these attempts. This is an authorization
UI failure, not evidence that NetworkExtension rejected the target process.

The broker's XPC `NSRunLoop` is not an `NSApplication` event loop. The candidate
uses foreground accessory activation and `NSOpenPanel.runModal()` to pump
AppKit events while consent is pending. An independent ad-hoc sandbox fixture
using the same read-only user-selection entitlement completed exact-file
selection and reading with the modal variant; its asynchronous/NSRunLoop
control remained behind another app and did not complete. That experiment
supports the UI fix but does not validate production XPC authentication,
root-provider grants or actual Claude traffic. No production binary was
re-signed or patched for this experiment.

The cached Tart base has SIP disabled and no recovery partition. Gatekeeper
was restored to enabled in the test clone, but `syspolicy_check distribution`
reported an internal XProtect error for Build 52 while deep strict signature
validation passed. These environment limitations must remain explicit; results
from this clone cannot establish acceptance under a normal SIP-enabled system.
The test uses credential-free loopback exit fixtures, with TUN off (and the
since-retired Local DoH also off); no Claude account, chats or real proxy
credentials are copied.

## Mock child-process follow-up (2026-10-24)

Tart Build 52 discovered both executables of an ad-hoc test bundle placed in
`/Applications`: a parent app and a separately signed embedded helper. The
parent launched through LaunchServices, then either forked without exec or
executed its embedded helper. Both child cases received the expected response
from the credential-free loopback `fixture-a` proxy. An external executable not
in the selected snapshot returned `EAI_NONAME` for the synthetic test domain
and received no fixture response. This negative case is not a claim that all
unselected traffic is blocked: it follows ordinary system routing.

The OS rule policy remains explicit `matchTools`, with provider validation of
the actual source audit token and executable identity. An embedded helper is
included by discovery; external tools must be enrolled under their owning app.
Parent/child ancestry by itself never authorizes an unknown executable.

These are short synthetic application-response results. The provider emitted
DNS and upstream counters, but the session stopped before complete per-child
PID receipts were captured. Do not promote those counters to process-correlated
acceptance, stable renewal, user-home code access, or Claude API recovery. The
VM's inherited disabled SIP is another production-acceptance limitation.

`generationMismatch` still reproduces and its exact failing check is unresolved.
The persisted rule fields recomputed to the expected digest; an in-memory
NEAppRule round-trip also matched. Neither establishes what a newly loaded NE
manager exposes while running. Host diagnostics now distinguish rule readback,
configuration readback, provider generation, provider readiness and message
availability, and retain the maintenance phase after verified shutdown. Checks
and fail-closed shutdown remain in place. This diagnostic change requires a new
Cloud-signed installation to identify the failing boundary; it is not a root
cause fix or part of Build 53. Build 53 contains the consent-modal candidate,
which also remains unverified in the installed production broker.

## Build 53 consent installation result (2026-10-24)

After explicit user approval to extract only inside `mihomobox-claude-test`,
Cloud Build 53 (`487c419347899f8cfd3727064d33dcd4430545d6`) was installed and its
version-53 system extension activated. The original ZIP SHA-256 was
`c6e7158e1f8624150655584a1a46be43e61f184a66032985623150729898627f`.
App, broker and extension passed strict/deep signature verification against the
pinned Cloud leaf. The broker retained sandbox, user-selected read-only and
app-scoped bookmark entitlements. Build 52 was retained as a VM-local rollback
bundle. No installation or network changes were made on either Mac.

This supersedes the earlier untested-consent status for this VM/mock case:
production Powerbox stayed open, accepted exact selection of the user-home mock
`.app` package, and enabled a short successful flow. Mock PID 3045 / PID version
7904 was correlated in the UI with `handleNewFlow`, `providerValidated`,
`dnsAnswered` and `upstream_connected` under generation
`A792F4C7-725E-47BA-AFB0-3C13519634A4`; the same process received the expected
synthetic fixture-a response. Restarting both the host and broker reused the
saved authorization without another panel, and new mock PID 3093 also received
the response. This tests same-boot broker restart, not operating-system reboot.

`generationMismatch` and automatic shutdown still reproduce; the new host
boundary diagnostics are not in Build 53. The VM was left with App Proxy off.
Gatekeeper still rejected the bundle while reporting Notarized Developer ID,
and SIP was already disabled in the VM base; neither protection was changed for
this installation. Normal-SIP acceptance, OS reboot, user switching, revocation
and real Claude API recovery remain open gates.

## Preference enumeration false mismatch — Cloud 54, 2026-10-24

Cloud Build 54 (`70b291f504c2045d194ceb3c205f24845809a9af`) was installed
only in the authorized `mihomobox-claude-test` VM, preserving Build 53 for
rollback. The original stapled Cloud ZIP SHA-256 was
`61d950cd3fa10bb6dc73da148b05a22af97c2937e0789bee33ac3b2d1eb9bcb3`.

The signed host directly observed an enabled manager returned by
`NEAppProxyProviderManager.loadAllFromPreferences` with **zero app rules**.
Calling the public `loadFromPreferences` on that same manager returned **two
rules and two tool entries**, whose digest exactly matched the published
expected digest. A newly launched host reproduced the same before/after
observation. This is evidence on macOS 26.6.2 (25G83), not a claim that Apple's
API behaves identically on every supported OS.

The old maintenance path compared the enumeration's empty rule list against
the expected nonempty digest and disabled interception, reporting the generic
`generationMismatch`. The corrected path explicitly reloads before status,
maintenance or enable/disable decisions. It propagates reload failures and
retains exact rule-digest, provider-generation, readiness and authorization
checks; it never treats missing rules as a match. Fixed diagnostics now separate
rule readback, configuration readback, provider generation, provider readiness
and explicit identity failures, with the failing transaction phase.

Unified logging records only a changed tuple of enabled/rule-count/tool-count/
digest-match before and after reload, plus fixed failure codes. It does not log
rules, paths, designated requirements, generation IDs, bookmark capabilities or
identity fingerprints. Real-flow receipts remain in the existing bounded local
UI diagnostic inventory.

The initial mock run completed 16/16 requests over 150.453 seconds with rules
remaining enabled, DNS success and the expected fixture-a response, exceeding
both the 20-second maintenance interval and 90-second provider lease. The UI
correlated mock PID 6420 with callback entry, provider validation, DNS response
and upstream connection in generation D8538740-01D0-4447-867B-D1C50167566A.
This establishes mock application response, not real Claude API recovery.

The VM's inherited SIP-disabled state and Gatekeeper rejection (despite
Notarized Developer ID source and successful strict signature checks) remain
acceptance limitations. No security bypass was applied. Normal-SIP physical
machines, OS reboot/user switching, and actual Claude upgrade/API behavior
remain separate acceptance work.

The follow-up host/broker termination and normal host relaunch preserved the
active provider and passed another 16/16 fixture-a requests over 150.427 seconds.
Changing only the mock entry to fixture-b through the App Proxy page and applying
it passed 16/16 requests over 150.612 seconds; every response identified fixture-b
and not fixture-a. All 48 requests had DNS/connect success with capture rules
still enabled. Captured fixed-field logs contained no policy failure event.
This host restart test does not establish provider-process or OS-reboot recovery.

At completion, fixture-a was restored through the UI, App Proxy was explicitly
disabled and the saved NE enabled flag was verified false. Build 54 remains in
the VM with the Build 53 rollback App. The bounded diagnostic collector was
stopped. No network or application changes were made on either Mac. Local evidence:
`/private/tmp/mihomobox-build54-test/acceptance.json` and the three per-request
JSONL records. The source build had passed `scripts/validate.sh` and the nine
AppProxyCoordinator tests before Cloud submission.


## Per-application consent and activation (implementation; signed acceptance pending)

The host now distinguishes the complete daemon-owned routing list, per-user
requested application selections, broker consent, and the provider's actual
verified subset. A per-row action is the only interactive authorization entry.
The global resume and periodic reconciliation never show consent panels.
Discovery and broker validation run separately per selected application; failed
applications contribute neither target records nor OS matchTools. Shared hosts
are deduplicated and their tool lists are explicitly merged. Provider generations
still use the existing prepare/save/readback/commit transaction and exact digest,
console UID, file stamp, signature, audit token and readiness gates.

The sandbox broker retains successful exact-root bookmarks across requests for
other applications and across partial cancellation. It also keeps bounded
verified identity pins, so a paused application cannot silently accept a changed
publisher or ad-hoc replacement after its old generation disappears. Both stores
are limited to 512 entries; capacity exhaustion is explicit, never an excuse to
widen authorization. No parent-directory grant or root file-reading service is
introduced. The fallback file picker shows hidden code locations and selects packages
as units; the canonical exact-root guard remains mandatory.

Per-application failures withdraw that application's interception; system-wide
failures such as console-owner changes or unverifiable policy publication remain
fail-closed. Waiting at Powerbox renews the previous generation without admitting
new code; that renewal task is joined before rules change. Changing the active
subset may affect flows owned by removed applications. All discovered versions
of one application remain one authorization unit; a newly downloaded version
needing consent currently pauses that entry until reauthorization. Preserving a
partially authorized version set is not claimed by this implementation.

Validation added: independent denial/recovery, disabled-entry exclusion, no rule
leakage, shared-terminal tool bounds, duplicate ownership, malformed broker reply,
missing file, consent-wait lease renewal, failed lease propagation, saved-route
preservation and stale/dirty UI refusal. These tests use system-signed local test
executables and opaque fake grants for assembly; they are not NetworkExtension or
Claude end-to-end evidence. Signed acceptance on the test Mac must still prove exact Claude
process receipts, DNS response and actual API recovery, with the other entries
retained and no new ChatGPT/Codex file consent.

Local validation on 2026-10-26: `scripts/validate.sh` completed with exit 0,
including Swift suites, same-UID real sandbox read-only delegation fixtures,
installer dry-run and the ad-hoc development bundle. No production App was
locally signed or installed for these checks. The exact new row/lease tests
are `AppProxyEnrollmentTests` and the independent-enable `AppProxyStoreTests`.

## Scan-and-confirm consent (owner decision, 2026-10-26)

*Superseded in part by Identifier and Team policy (2026-11-09): executable scans,
exact records, cdhash checks and the launched-CLI tier were removed.*

The owner chose to remove the file picker from normal authorization. **Authorize &
Enable** now rescans the application's signed executables and shows them (path,
signing ID, Team ID, designated requirement) in a confirmation sheet; one click
authorizes. `MihomoCodeAccess.xpc` gained
`temporary-exception.files.home-relative-path.read-only = ["/"]` and
`temporary-exception.files.absolute-path.read-only = ["/opt/homebrew/", "/usr/local/"]`,
so it reads code in the home directory without Powerbox. Powerbox remains only for
code the broker still cannot read, such as external volumes.

When rule readback fails, `event=app_proxy_rules_diff` logs count-only field
differences (rules, tools, missing/extra, requirement text vs canonical form,
moved/case-only/resolved paths); it never logs paths, identifiers or requirements.
User enable actions wait for the 20-second maintenance pass instead of failing as
unavailable.

This deliberately reverses the earlier "no home directory, no temporary file
exception" rule for the broker. Cost: a compromised broker could read any user file.
Retained limits: the broker has no network entitlement, accepts only the same-leaf
host at the same non-root UID, writes nothing, and still exports only exact
`.app`-package or exact-file read-only grants with identity pins and writable-grant
rejection. The NetworkExtension provider gains no exception
(`check-app-proxy-bundle.sh --signed` enforces both). Applications are added by
dragging bundles or executables onto the list, typing or pasting a path, or the
optional picker; the CLI executable editor also accepts drops and `file://` lines.

## Team, directory and exact-CLI scopes (owner decision, 2026-10-26)

*Superseded in part by Identifier and Team policy (2026-11-09): executable scans,
exact records, cdhash checks and the launched-CLI tier were removed.*

**Cause.** On the test Mac, `event=app_proxy_rules_diff` reported `rules=27/21 missing=6`
with every other field matching. The 27 generated targets held six signing
identifiers twice, each a copy bundled in `ChatGPT.app` plus a copy installed under
the home directory (`node`, `com.openai.sky.CUAService` and its helpers), with
identical requirements. NetworkExtension keeps one app rule per signing identifier,
so six rules vanished on save and readback failed closed.

**OS rules.** The host now publishes one `NEAppRule` per signing identifier. A
unique identifier keeps its exact `matchPath`; a shared one omits the path and
matches every approved requirement joined with `or`. `init(combining:)` merges
across applications the same way. The provider still receives every exact record.

**Scopes.** Each application may add Team IDs (at most 8), directories (at most 16)
and exact executables. A Team ID or directory belongs to one application. Team
discovery covers `.app` bundles in `/Applications` and `~/Applications` whose main
executable carries the team, and CLIs in the conventional bin directories; code
elsewhere needs a directory scope. Directory discovery takes every signed Mach-O
below the folder within the existing scan bounds, except Apple's own code
(`anchor apple`). A copy of an Apple binary has the same identifier, requirement and
Mach-O UUID as the system original: with its rule installed, `/usr/bin/curl`
launched over SSH failed with `EPERM` on the test Mac. Such copies are also killed by launch
constraints.

**Launch context (test Mac, 2026-10-26).** macOS attributes a CLI to the responsible
process of its session: the terminal, editor or SSH login (`sshd-session`). Two kernel
steps use it before the provider. NECP evaluates the socket as the responsible
application when that application's Mach-O UUID appears in an installed rule, and
otherwise as the CLI itself (xnu `necp_socket_fillout_info_locked`). Flow divert then
checks the responsible process's signing identifier against the rules' identifiers
and fails `connect()` with `EPERM` when it is absent (`flow_divert_add_all_proc_info`).
`NEFlowMetaData` still describes the real process: the test Mac's receipts carried the PIDs of
ChatGPT's bundled `codex` helpers, whose responsible process is ChatGPT. A tool is
therefore captured when it is its own responsible process or its host has a rule that
lists it in `matchTools`. Under a host without a rule, a tool whose rule has a
`matchPath` gets `EPERM`; a tool with a shared identifier connects directly, because
NetworkExtension resolves a path-less rule only through LaunchServices. Verified in
one SSH session: `packer` (Team scope) failed with `EPERM`, the same binary started
with responsibility disclaimed reached `upstream_connected`, and ChatGPT's bundled
`node` connected directly both ways. Earlier: directory-scoped and Team-scoped tools
run as launchd jobs reached `mihomobox-app-chatgpt`; `/usr/bin/curl` stayed direct.

**Launch hosts.** Host rules cover `/usr/libexec/sshd-session`, `/usr/sbin/sshd` and
apps in `/System/Applications/Utilities`, `/Applications` and `~/Applications` whose
bundle identifier names a known terminal or editor: Terminal, iTerm2, Warp, Ghostty,
kitty, Alacritty, WezTerm, Hyper, Tabby, VS Code and Insiders, VSCodium, Cursor,
Windsurf, Zed, Xcode, Android Studio and `com.jetbrains.*`. Each rule carries the
host's `matchPath`, since a path-less rule never matches `sshd-session`, and lists only
the verified tools. tmux, screen and shells inherit the process that started them.
Hosts are never routed, so they are not authorized records: discovery reads their
identifier and requirement from a signature check without sealed resources, which
took 1–11 s per JetBrains IDE or Xcode on every 20-second scan. Other launchers, such
as cron, a launchd job running a script or an unlisted app, still get `EPERM`.

**Launched CLIs.** With `capturesLaunchedCLIs` (default on), an application's rules
also list the other selected applications' verified CLIs, so `codex` started by Claude
Code keeps the codex CLI's route; the provider routes by the real process. Off, such a
CLI connects directly: the launching application's rule claims the responsible UUID,
so the CLI's own rule no longer applies. The option is stored like a scope, without
restarting Mihomo.

**Scope edits do not restart Mihomo.** Scopes are not part of the generated Mihomo
configuration (`AppProxySettings.runtimeRouting`), so the daemon stores a scope-only
change without re-activating the profile. Re-activation in Global mode under heavy
load (load average ~40) missed the agent readiness window twice and failed closed.

**Provider enforcement.** A flow whose executable is an exact record keeps the
cdhash and file-stamp checks. Otherwise the provider admits it only through the
most specific approved scope (deepest directory, then team) and only after
`SecCodeCheckValidity` against that scope: `anchor apple generic` plus the leaf
OU for a team, any valid signature for a directory. Anything else is
`undiscoveredTarget` and the flow is closed, not bypassed.

**Consent and grants.** The confirmation sheet approves the application's scopes;
the broker stores them and maintenance reuses them, so code covered by an approved
scope refreshes without new approval. Each directory scope carries one read-only
grant minted by the broker; the provider must open it. This reverses the earlier
"no parent-directory grant" rule for directory scopes only.

**Limits.** A new signing identifier reaches the OS rules only after the next scan.
Directories below the `/tmp`, `/var` and `/etc` symlinks are rejected by the
no-follow checks.

**Command line.** `mihomoboxctl app-proxy policy` edits scopes through the daemon.
Authorization and enabling stay in the host: the CLI runs the signed host executable
headlessly after checking it carries the CLI's own Developer ID leaf, so the broker
still accepts only the host. `enable --approve` is the operator's consent; any process
running as the user can invoke it, which is weaker than a UI click and was accepted
by the owner for headless operation.

**Traffic attribution.** Mihomo identifies a connection's process by the socket owner,
which for every App Proxy flow is the provider's connection to a `mihomobox-app-*`
listener. The provider therefore keeps, for each such connection, the verified
executable path and PID by the connection's local port (TCP, or the SOCKS UDP relay).
The app requests this table (`flowOwners`, at most 512 flows and 128 paths per reply,
replacing receipts and counters in that reply) only while App Proxy connections lack
an owner, at most once a second, and the dashboard replaces `MihomoAppProxy` with the
real process for Connections and Usage; an exact match stays with the connection after
the flow ends. Without a match it shows the App Proxy application title. The table is
display-only: it is never logged and does not affect routing.

**System proxy.** Apps that honor the macOS system proxy (Chromium-based helpers such
as ChatGPT's `Codex (Service)` network process, and `codex` when given proxy settings)
connect to it on loopback. NetworkExtension does not divert loopback connections to an
app proxy provider: on the test Mac (system proxy `127.0.0.1:7897`, Mihomo's mixed port) a
verified `codex` process reached Mihomo through `DEFAULT-MIXED` with itself as the socket
owner, and a provider that relayed such connections to the app's listener never saw one.
App Proxy cannot intercept it, so Mihomo routes it by process instead: the generated
configuration has one file rule provider per application (`mihomobox-app-<id>-processes`,
`mihomo-data/mihomobox/app-<id>-processes.yaml`) and, ahead of the profile's rules,
`SUB-RULE,(AND,((RULE-SET,mihomobox-app-<id>-processes))),mihomobox-app-<id>`. After each
successful authorization or disable, the app sends the verified executable paths of the
active applications (`app-proxy.set-processes`); the daemon rewrites only the changed
provider files and asks the running core to reload them, without a restart. These rules
match by path alone: Mihomo does not check signatures, so they route, but do not
authenticate, code at a verified path. Paths containing a comma are left out (a classical
rule is comma-separated), process lookup must not be disabled in the profile
(`find-process-mode: off`). A configuration rendered before this overlay gains the
providers on the next **Reload Profiles** (`mihomoboxctl profile reload`), which now renders
the active profile again and applies a changed result as a transactional activation.

**Framework links.** The signed-code scan once called `skipDescendants()` on symbolic
links. The enumerator never follows a link, so that call skipped the directory holding
it instead; because a framework's `Versions/Current` links can come first on disk, every
helper in ChatGPT's `Codex Framework.framework` (including `Codex (Service)`) was missing
from the targets. Links are now passed over, and only a link that resolves outside the
scanned tree is reported as `escapedPath`.

**Extension updates.** The App activates its bundled provider only on a non-live install,
so after an update the old provider kept running until the user next enabled App Proxy;
on the test Mac under load that replacement then took about three minutes and looked like a
failed start. The provider now reports its bundle version in every status reply. The
App's maintenance pass (at launch, then every 3 minutes) compares it with
the bundled extension and, when App Proxy is enabled and connected and the versions
differ (a provider without the field counts as older), disables the session and
republishes, which activates the bundled extension and its rules in the background. It
tries this once per bundled version per App launch.

## Identifier and Team policy (owner decision, 2026-11-09)

**Why.** Each new application multiplied the rules: exact executable records, one
`matchTools` list per responsible process, a size budget with a reduced tier, cdhash
and file-stamp checks on every renewal, and a scan of every signed Mach-O every
20 seconds. The owner asked for a policy without binary scanning.

**Policy.** An entry is Team IDs, signing identifiers and code folders. Adding an
application reads its Team ID and identifiers once (its own, its nested helper
apps', and its same-team executables in `MacOS` and `Helpers`); code outside the
provider-readable locations also records its folder, a Homebrew formula or cask
folder as a whole. Policy v5 (`per-application-v5`) carries only routes, folder
grants and a code stamp. The provider admits a flow when its owner UID matches, its
running code's identifier is listed, that identifier's route lists the code's Team ID,
and `SecCodeCheckValidity` passes with the route's Team requirement. It never reads
files on renewal.

**OS rules.** Each identifier becomes one path-less tool entry with an
`identifier` + Team requirement, which NetworkExtension matches wherever the code
lives (verified on the test Mac in build 1123 for CLIs outside LaunchServices).
Each installed top-level application and each launch host (SSH, terminals, editors)
gets one rule carrying all tool entries, so a CLI keeps its own route whichever
selected application or launcher starts it. Copies of one identifier share a
path-less rule that ORs their requirements. This reverses the 2026-10-26 decision
not to route all children: the tool list is now every listed identifier, but never
`nil`, so unlisted children of a terminal still connect directly.

**Consent.** The confirmation sheet approves the entry's folders, including ones
that do not exist yet. A partly approved entry is still routed for the code the
provider can read, and reports `needsAuthorization` for the rest. Unsigned and
ad-hoc code is unsupported.

**Updates.** FSEvents on `/Applications`, `~/Applications` and the granted folders
triggers a pass within seconds; the periodic pass runs every 3 minutes. A pass looks
applications up through LaunchServices, registers bundles found in granted folders,
and compares a metadata stamp of top-level executables and granted folders (device,
inode, size, modification time). New versions under listed identifiers need no new
rule. Lease renewal stays at 20 seconds and reads no files.

**Mihomo process routes.** The App sends each application's folders (except folders
named `Applications` or `bin`) and found bundles as path prefixes, rendered as anchored
`PROCESS-PATH-REGEX` rules; standalone executables stay `PROCESS-PATH`. They route,
but do not authenticate, code at those paths.

**Limits.** 8 Team IDs, 64 identifiers and 16 folders per entry; 256 identifiers in
all; a Team ID or folder belongs to one entry. A CLI started by an unlisted launcher
(cron, a launchd job) connects without App Proxy.
