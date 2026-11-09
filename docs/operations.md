# Operations

## Migrating the old four App Proxy presets

1.1.0 introduced OpenAI and Anthropic Team ID defaults for fresh settings. Existing
four-entry settings were preserved. In the next App, the App Proxy page offers
**Use Team ID Defaults** for untouched legacy presets. Turn interception off,
select that action, then Apply. **Restore Team ID Defaults** performs the same
migration when eligible. Re-enable through the normal code-scope review.

For a signed operator CLI:

```bash
mihomoboxctl app-proxy policy migrate-defaults
mihomoboxctl app-proxy policy show
```

The command disables interception through the signed host, writes through the
authenticated typed daemon action with revision checking, and verifies readback.
OpenAI uses `2DC432GLL2`, Anthropic uses `Q6L2SF6YDW`. Desktop node selections,
network bypasses and unrelated custom applications are kept. Different desktop
and CLI nodes or customized preset scopes block migration instead of discarding
settings; reconcile those choices explicitly first. No root settings file is
edited directly, and code-access consent is never inferred from old presets.

## Adding the JetBrains Team ID default

Fresh settings also route JetBrains (`2ZEFAR8TH3`, IntelliJ IDEA, other
JetBrains IDEs and Toolbox) on the fixed listener 17970. Migration replaces
legacy presets with the OpenAI and Anthropic entries only. Configured settings
never gain an entry implicitly, because a configured route set must name every
application. Add the missing built-in entries explicitly:

```bash
mihomoboxctl app-proxy policy add-defaults PROXY
mihomoboxctl app-proxy targets jetbrains
```

The command routes each added entry to the named proxy, disables interception
through the signed host, writes with revision checking and verifies readback.
In the App, **Restore Team ID Defaults** adds the same entries; choose a node,
Apply, then re-enable through the normal code-scope review.

## Menu-bar proxy switches

Starting with 1.1.1, **System Proxy** controls the managed HTTP/HTTPS/SOCKS
settings for enabled Ethernet/Wi-Fi services. It reads back actual owned
settings and restores their previous values when disabled. **App Proxy**
pauses/resumes previously authorized scopes. A fresh installation must select
and authorize its scopes on the App Proxy page before using that switch.
The equivalent signed CLI controls are:

```bash
mihomoboxctl rpc set-system-proxy true
mihomoboxctl rpc set-system-proxy false
mihomoboxctl app-proxy on
mihomoboxctl app-proxy off
```

The menu and App Proxy page share one host coordinator. In 1.1.2, diagnostics
reuse the last loaded manager until NetworkExtension reports a configuration
change. Policy mutations still require fresh preference readback. Existing
provider authorization renews independently of preference reads and their lock;
every renewal revalidates the same generation and approved code. A timed-out OS
request retains its single-flight slot until its actual callback arrives, so
background retries cannot build an unbounded nehelper request queue. Cold start
still requires a successful OS preference read.

Provider signature renewal runs on a separate validation queue; socket relay,
status and the unchanged 90-second expiry remain responsive. A late validation
cannot revive a stopped, expired or replaced generation. Concurrent requests for
the same renewal are coalesced. Diagnostic counters `lease_renewed` and
`lease_validation_ms_max` expose progress and duration without identifying code.
A transient empty provider reply can be retried twice for status, flow-owner
reads or renewal. Prepare/commit/abort and validation errors are never replayed.

For sustained combined-mode acceptance, keep App Proxy and TUN on and System
Proxy off for longer than the previous failure interval (at least 75 minutes on
m4pro). Record bounded samples of health, switch state, lease counters, app
inbound byte progress and client reconnect errors. Require successful UDP/TCP
loopback DNS probes (UDP only on a Mac running MTTA's DNS Proxy, where loopback
TCP DNS fails; see [MTTA DNS Proxy](#mtta-dns-proxy)), no repeated DNS ownership transitions, no preference or
lease-expiry errors, and separately attributed Claude/Codex traffic on their
App Proxy inbounds. An idle client or a working TUN connection alone cannot
establish stream stability. Publish only after this acceptance passes.

All three switches persist their requested state independently. TUN and System
Proxy choices live in root-owned `daemon.json`; App Proxy uses the existing
per-user preference and retains its authorized scope selection. Menu checkmarks
show these saved choices, while runtime health and connection status report
actual operation. A failed transition does not erase the choice. Legacy TUN
configurations preserve their last state; absent System Proxy intent defaults
to off and does not adopt another application's proxy settings.

Daemon startup and signed `start` restore the saved TUN/System Proxy choices.
App startup reconciles mismatches and immediately restores App Proxy using the
signed host's bounded on/off action. Temporary shutdown restores owned system
proxy settings without clearing the saved choice; a later startup reapplies it.
Turning a switch off saves off before attempting the runtime transition.

These switches are independent of **Enhanced TUN**. When checking combined
App Proxy + TUN operation, keep System Proxy off and distinguish the two
application-specific inbounds from `DEFAULT-TUN`. A Team ID application's
working TUN connection is not evidence that App Proxy captured it.

## App Proxy configuration size and updates

The rules hold one shared, path-less tool entry per signing identifier and one rule
per installed top-level application or launch host, so the configuration stays small.
Each install logs its measured size and rule and tool counts:

```bash
/usr/bin/log show --last 10m --info --predicate 'eventMessage CONTAINS "app_proxy_configuration_size"'
```

An update that replaces a top-level application or a code folder logs
`event=app_proxy_refresh reason=update` within a few seconds (FSEvents); the periodic
pass runs every 3 minutes as a fallback. Helpers and CLIs match by identifier and
Team ID, so their updates need no new rules.

## Verify App Proxy without system proxy or TUN

An active row proves enrollment, not that macOS diverted that application's
sockets. For acceptance, disable HTTP/HTTPS/SOCKS and automatic system proxy
settings, verify `scutil --proxy`, then use the signed operator CLI:

```bash
mihomoboxctl rpc set-tun false
mihomoboxctl status --json
mihomoboxctl app-proxy runtime
mihomoboxctl app-proxy flows
mihomoboxctl rpc connections
```

Require `health.tun_enabled=false`, `health.network_consistent=true`, both rows
active and `identityReady=true`. Join each connection's metadata source port
with the provider's `flows` table, verify the actual executable/PID, and require
inbound `mihomobox-app-chatgpt` or `mihomobox-app-claude` with a remote proxy in
its chain. Observe upload/download progress across multiple maintenance passes.
`DEFAULT-MIXED`, `DEFAULT-TUN`, DNS receipts alone, or a selected proxy node do
not satisfy this test. Do not turn TUN back on to hide a capture failure.

On m4pro, Claude's already-running Electron Network Service continued opening
uncaptured sockets even though its Team ID, signing identity and Mach-O UUID
matched the enrolled on-disk code. Re-enabling the provider alone did not fix
that state. After the network service was restarted and enrollment was restored,
its replacement PID produced `providerValidated`/`upstream_connected` receipts
and connections through `mihomobox-app-claude`, with system proxy and TUN both
off. If reproducing this condition, finish or pause ongoing Claude operations
before restarting the application or its verified Network Service; do not kill
unrelated same-name helpers or automatically terminate user applications.

The provider checks each flow's running code against its route's Team ID; it reads no
files on renewal. Prepare and commit have a 30-second deadline, status, flow reads and
renewals 10 seconds, and broker grants 20 seconds. The provider's 90-second
authorization lease and fail-closed behavior are unchanged. `codeAccessTimeout` and `providerTimeout`
distinguish expiration from transport failure. A successful enable must remain
healthy through subsequent renewals before being accepted.

## Per-application proxy settings

App Proxy uses the same **Running Mode** as the tray and Config page. Its mode
picker reads the current core configuration when the page opens or refreshes,
and changes it through the existing authenticated controller action. **Global**
uses the core's `GLOBAL` selection; **Direct** connects directly; **Rule** matches
the profile's rules in order. Explicit direct, reject and pass actions are
preserved; proxy targets, including policy-group targets, use the app's selected
node/group. Rule-set references and matching parameters are retained, and
referenced sub-rules get the same treatment. With no matching rule the core
still defaults to direct. A rule's policy-group target is replaced as a whole,
not evaluated for its selected leaf first; use an explicit direct/reject rule
to exempt a destination. App node choices are
retained while Global or Direct is active. Mode changes affect new connections;
established connections keep their current outbound until they reconnect.
Explicit local-network bypasses and shared DNS handling still precede these
core routing decisions.

**Local networks and VPNs → Edit Bypass…** controls destination CIDRs that use
macOS routing before an application's node. Defaults include RFC1918, IPv4
link-local, IPv6 ULA and link-local. Other VPN ranges (including CGNAT or public
addresses) require explicit entries. An empty list disables these exemptions;
loopback callbacks still remain local. DNS port 53 always uses Mihomo's shared
DNS service. Names are not independently resolved by the bypass matcher: it
matches the actual numeric flow endpoint. Fake-IP endpoints remain with Mihomo;
private names requiring real addresses must use the profile's DNS/Fake-IP filter.

Turn App Proxy off before editing, save the draft, apply changes, then enable it.
After upgrading from an older provider configuration, an orange notice asks for
this off/on cycle to install the policy. The policy is stored in root settings
and the NetworkExtension preferences, so YAML regeneration, TUN changes and
Rule/Global/Direct changes cannot remove it. No route table changes are made.
If a VPN disappears, macOS chooses the remaining route; this is not a VPN kill
switch. No proxy failure automatically falls back to direct access.

For the private VPN regression, check the system route to a host on the private
VPN, then run `ssh -o BatchMode=yes -o ConnectTimeout=10 HOST /usr/bin/true` from the actual
Codex context. Confirm successful SSH handshake/authentication and absence of
that target on the app's remote-proxy listener. Also verify public HTTPS still
appears on that listener and follows the current mode: original direct/reject
rules or the app node for proxy rules in Rule,
the global node in Global, and DIRECT in Direct. Repeat after a provider
restart, profile reload, and TUN/mode changes. A syntax check or a successful
direct connection from an unrelated process alone does not satisfy this test.

Rule lists must be block-style with a single plain, single-quoted or
JSON-compatible double-quoted rule per line. Empty `[]` lists are supported.
Rule aliases, multiline scalars, nonempty inline lists and rematch adapters
are rejected before activation rather than silently losing rule behavior.
Named proxy definitions must use block mappings with explicit names and types;
named direct/reject/DNS adapters are preserved. Original profile rules remain
unchanged for traffic outside App Proxy.

Open **App Proxy** in the sidebar (Command-8). Drag a signed application bundle or
executable onto the list, or use **Add App or CLI…** to paste its path (Choose…
still opens a picker). Adding reads the code's Team ID and signing identifiers once:
the app's, its nested helper apps' and its same-team executables'. Code outside
`/Applications`, `/System`, `/Library` and the system `bin` folders also records its
folder (a Homebrew formula or cask folder, so it survives upgrades). Unsigned and
ad-hoc code has no Team ID and is rejected. The details panel lists the installed
top-level applications that get OS rules of their own; helpers and CLIs are not
listed, because they match by identifier and Team ID. Refresh Nodes reads routing,
available targets and extension status concurrently without replacing an edited
draft; **Refresh Installed Applications** looks the applications up again.

Search applications or search inside each node picker. The fixed bottom bar
shows unsaved edits and keeps Apply, Discard and the extension switch visible.
An external settings change preserves the draft but blocks Apply until Discard
loads the latest saved settings, preventing accidental overwrites.
Choose a node or proxy group for every entry, then **Apply Changes**. Each row
has **Authorize & Enable**, **Retry Authorization** and **Disable** actions.
Authorize shows the installed applications found for that row and the policy being
approved: Team IDs, signing identifiers and the code folders granted read-only to the
App Proxy extension. Approval covers later versions and folders that do not exist yet.
No file picker is needed. Other rows and their node choices remain saved; declining
one application's consent does not discard or block other authorized applications.
An application whose folders are only partly approved is still routed for the code
the extension can read, and its row asks for the rest (`needsAuthorization`).
Unselected or pending applications follow the remaining macOS network configuration,
including TUN when applicable. No direct fallback is added by App Proxy.

**Turn Off** pauses the shared service while preserving row selections;
**Resume Selected Apps** rechecks selected applications without opening consent
panels. A fresh installation starts with no selected applications; a saved policy
from an earlier version seeds the selections, and folders approved then stay approved.
Preferences belong to the logged-in user; root profile settings still retain the
complete application/node list. An open consent panel continues renewing only the
previous verified generation; new rules are committed together after provider
validation, with verified rollback or complete shutdown on an ambiguous system-wide
failure. Terminal, editor and SSH rules list the selected applications' identifiers,
never all child processes. A CLI launched elsewhere (cron, a launchd job running a
script, an unlisted app) connects without App Proxy; with TUN on, Mihomo's process
rules for the application's folders still route it.

A LoadBalance group is accepted only when every candidate
resolves to a remote proxy. macOS may require Network Extension and VPN approval.
Disable App Proxy before adding or removing entries. Removing an entry only
removes its proxy routing, never the installed application. Apply saves these
changes; Restore Team ID Defaults restores the OpenAI, Anthropic and JetBrains
presets.

Each entry's **Policy** editor holds what routes code to that entry's node, one entry
per line (type, paste or drag in):

- **Team IDs**: the developers who sign the application. Dropping an app fills in its
  Team ID. A Team ID belongs to one entry.
- **Signing identifiers**: the app, its helpers and its CLIs (`com.openai.codex`,
  `codex`). Dropping an app adds its bundle identifier.
- **Code folders**: folders outside `/Applications` that hold the code, such as
  `~/.local/share/claude/versions` or a Homebrew Caskroom folder (**Choose Folder…**).
  They are granted read-only to the App Proxy extension so macOS can validate the
  code there. A writable or linked folder, a whole home, Library, Application Support,
  Documents, Desktop or Downloads folder, and a system or Homebrew prefix are refused.

Below them, **Where CLIs are captured** lists the terminals, editors and SSH logins
detected on this Mac. A listed CLI is captured when its own application, another
selected application or one of these launchers starts it.

Then **Update Draft**, **Apply Changes**, and authorize the app. Turn App Proxy off
before editing a policy. A new version of listed code is captured without a new
approval; a new identifier needs a policy edit.

The same operations are available from a shell, run as the logged-in user:

```bash
mihomoboxctl app-proxy policy show chatgpt
mihomoboxctl app-proxy policy set chatgpt --team 2DC432GLL2 --identifier com.openai.codex --identifier codex --directory ~/.codex/computer-use
mihomoboxctl app-proxy targets chatgpt
mihomoboxctl app-proxy enable chatgpt --approve
mihomoboxctl app-proxy runtime
```

`policy set` replaces the Team IDs, identifiers and folders of one application in
the daemon-owned settings. `targets`, `runtime`, `enable`, `disable`, `on` and `off`
run the signed MihomoBox host headlessly (`mihomo-app --app-proxy …`); the CLI first
verifies that host against its own Developer ID leaf. `--approve` approves the
application's code folders exactly as the confirmation sheet does; without it only
earlier approvals apply. A headless run and the menu-bar app serialize their App Proxy
changes with a per-user lock. `runtime` also prints the provider's recent
process-validation stages and counters (PIDs only, no paths or traffic), the same
receipts the app shows. `flows` lists the verified process behind each App Proxy
connection to Mihomo, keyed by the connection's source port. Connections an app makes
to the macOS system proxy on loopback never reach App Proxy; Mihomo routes them through
the app's rules by path instead (its code folders and installed bundles as anchored
`PROCESS-PATH-REGEX` rules), once the profile has been rendered by this version: after
an upgrade, use **Reload Profiles** (or `mihomoboxctl profile reload`) once.
For scripts, list the signed interpreter's identifier, which also covers its other uses.
Limits are 8 Team IDs, 64 identifiers and 16 folders per entry, 256 identifiers in all.

For authenticated remote diagnosis, `mihomoboxctl app-proxy status` reads the
saved list and `mihomoboxctl app-proxy set-all Proxy` transactionally assigns
the existing entries to a group through the same typed XPC validation. Neither
command changes macOS extension approval or adds application identities.

This page does not change macOS DNS ownership. App Proxy resolves the DNS it
captures for policy-matched applications through the root daemon: the
extension sends each query over the privileged Mach service
`dev.linsheng.mihomo.daemon.control` as control operation `dns.resolve`, and the
daemon answers it from the existing Mihomo DNS listener at `127.0.0.1:1153`,
sharing the TUN resolver and its Fake-IP policy. The extension opens no DNS
socket itself, so a DNS Proxy that intercepts port-53 flows (such as MTTA) does
not see these queries. An older daemon rejects `dns.resolve` and App Proxy DNS
then fails closed; upgrade the daemon together with the App.
App Proxy's per-app resolver advertises the managed TUN DNS address `198.18.0.2`,
not `127.0.0.1:53` where no DNS service is bound. Low-level resolver calls
must be tested with App Proxy enabled: successful hostname/SOCKS forwarding
alone does not establish that system name resolution works.
It does not publish a supplemental default DNS resolver or use a separate
public DoH service. DNS follows the core's shared configuration; each app's
selected node still controls its proxied connections. With TUN off, the core's
standby DNS returns real addresses. A failed, rejected or timed-out query fails
closed: the application gets no answer, and there is no system-resolver or
public fallback. Disabling Enhanced TUN releases Global DNS and keeps that
standby core and DNS available. `mihomoboxctl rpc set-tun false`
performs this same transition; `mihomoboxctl stop` stops the entire runtime.
DNS UDP flows do not open a SOCKS association or expire with its idle timer.
macOS reuses these resolver flows across core restarts; a failed DNS request
is dropped without closing the flow, so later requests can recover through
the shared resolver. Non-DNS remote UDP still uses the application's SOCKS route.
Global DNS cleanup and stopped-runtime checks exclude service-specific DNS
dictionaries carrying `ServiceIdentifier`. These belong to Network Extension;
matching the TUN DNS address alone does not make them stale Global DNS state.

## Uninstalling the Privileged Helper

Use **Tools › Uninstall Helper…** in the menu-bar App. The action is separate
from quitting the App and requires administrator confirmation. It executes only
the installer copied from an exact-code-requirement-verified App snapshot. A
successful restore stops both current and renamed LaunchDaemon labels, waits
for managed processes to disappear, restores system DNS, restores any recorded
legacy installation, and removes MihomoBox's root-owned support directory,
logs, plists, and managed CLI link.

The App and `~/Library/Application Support/MihomoBox/profiles` are not removed,
so a later helper installation can reuse the user's selected profile.

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.
If no previously authenticated active profile exists, installation stages a
REJECT-only provisioning profile and starts only the authenticated XPC daemon;
the agent and TUN remain stopped. The selected user profile is then activated
over typed XPC into a controller/DNS standby state with TUN off. No
certificate, trust setting or configuration profile is prepared; a failed
activation leaves the macOS system DNS list untouched.

For a remote Mac, first transfer a release App through an authenticated channel
and verify the complete bundle, then invoke the detached entry point **without**
`sudo` from the authenticated SSH session:

```bash
APP=/Applications/MihomoBox.app
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
/usr/sbin/spctl --assess --type execute "$APP"
"$APP/Contents/Resources/scripts/install-daemon-remote.sh"
```

The wrapper itself is deliberately unprivileged and refuses root execution. It
hands control to the signed `mihomoboxctl install --detached` entry point, which
requests `sudo` and constructs the fixed snapshot-verification bootstrap. After
root has copied and verified the App, the verified installer runs under `nohup`
and the CLI prints a root-only log path. Migration therefore continues if the
TUN handoff interrupts SSH. A checkout, an App from an unauthenticated transfer,
or a standalone copy of the wrapper is not a trusted remote installation source.
Launchd never executes from the movable App bundle.

The protocol-v2 to v3 upgrade requires this verified installer and a valid
root-owned component version floor. It does not send v2 runtime mutations;
missing or unsafe version state and newer daemon protocols remain rejected.

The app name in user-facing copy, system extension metadata and VPN
configuration names is **MihomoBox**. Feature labels such as App Proxy and
Enhanced TUN describe functionality; Mihomo names the bundled upstream core.

To install/activate just the bundled App Proxy system extension during an
authorized remote upgrade, run the installed, Cloud-signed host as the logged-in
user (never root):

```bash
/Applications/MihomoBox.app/Contents/MacOS/mihomo-app --activate-app-proxy-extension
```

This fixed command submits Apple's activation request only for MihomoBox's own
extension, independently of code-access enrollment. It does not start normal
host services, alter VPN preferences, grant code access, change DNS or start
application interception. The command emits one JSON result: `activated` (exit
0), `approvalRequired` (2), `rebootRequired` (3), `timedOut` (4), or
`failed`/`unavailable` (1). Errors expose only a numeric system code. Confirm the
actual version with `systemextensionsctl list`; activation alone is not proof
that App Proxy is connected or Claude works. macOS approval remains an operator
step when requested. Re-run after approval/reboot; a timeout must not be treated
as a confirmed cancellation or success. Enabling App Proxy and granting package
access remain separate operations in the application.
An existing VPN configuration name updates when App Proxy is re-enabled.
The visible bundle is `MihomoBox.app`. Existing
`/Library/Application Support/Mihomo App` and `/Library/Logs/Mihomo App` paths
remain stable so upgrades preserve configuration, DNS backups, and structured
diagnostic logs. Upgrade installation removes legacy raw `mihomo.log`
generations because older Mihomo output may contain DNS names or endpoints.
The upgraded supervisor performs the same one-time cleanup after component-only
automatic updates, so this does not depend on rerunning the installer.

The installer:

1. copies `mihomo`, `mihomo-daemon`, `mihomo-agent`, from the App to
   `/Library/Application Support/Mihomo App/`;
2. migrates `/opt/homebrew/etc/mihomo/` when present, otherwise installs the
   minimal default profile;
3. forces only the loopback controller and DNS recursion-boundary keys;
4. validates the copied Mihomo configuration;
5. stops a running Homebrew Mihomo service to prevent duplicate owners;
6. installs the XPC Mach service and starts the root daemon, which launches the
   agent with the saved Enhanced TUN choice (TUN-off standby on a fresh
   installation);
7. waits for `Global DNS with TUN or standby runtime`: when `daemon.json` has
   `enhancedTUNEnabled` or `globalDNSFallbackEnabled` set, the full network
   runtime (controller, Mihomo DNS, TUN, Fake-IP route, an answering
   `127.0.0.53` bridge and managed system DNS); otherwise the standby runtime
   (controller and Mihomo DNS, no TUN/Fake-IP route, and no MihomoBox address
   in persistent or effective system DNS).

The installer no longer prepares a DNS profile or certificate and no longer
checks a loopback `443` listener. Earlier releases' Local DoH artifacts are
removed by the daemon after the upgrade; see
[Legacy Local DoH cleanup](#legacy-local-doh-cleanup).

There are two intentionally separate startup mechanisms. The root LaunchDaemon
starts the managed Mihomo runtime at system startup. The
`enhancedTUNResumeEnabled` preference restores the last explicit TUN choice,
and Global DNS with it; turning TUN off survives restarts and component
updates. Upgrades use the old current state instead of the legacy "ever
enabled" flag. On launch, the App
also applies a one-time current-user login-item default, without requiring TUN
or a healthy network, so the hidden tray App returns after login.
Only an installed copy under `/Applications` or `~/Applications` applies this
default. That login item is not privileged and never owns a Mihomo process.
Turning it off later in macOS System Settings is respected.

It copies the signed CLI out of the verified snapshot into root-owned
Application Support, then makes `/usr/local/bin/mihomoboxctl` a user-executed
symlink to that stable copy. The link never points into the movable App, and
root never executes through it. A mode-`0600`, root-owned target record lets
repair or uninstall distinguish its exact link; an unrelated existing file or
symlink at the global CLI path is preserved. The standalone global CLI handles
typed XPC operations only. Install or uninstall must be launched from the tray
or the CLI inside the signed App so the running Mach-O can bind the exact App
snapshot before elevation.

Upgrades migrate the former `dev.linsheng.mihomo-app.daemon` label to
`dev.linsheng.mihomo.daemon`. The old job is stopped and its plist removed
before the new job starts; rollback restores the prior running label. Before
stopping any previously loaded job, the installer validates and saves its
root-owned launchd plist in the root-private rollback directory. A running
Homebrew Mihomo job is restarted by bootstrapping that saved plist, not by
assuming that `kickstart` can recreate a job removed by `bootout`; a trusted
copy is also retained for a later uninstall.

Rollback and preflight recovery are successful only after every previously
loaded launchd job is present again. If the prior MihomoBox managed runtime was
active, controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, persisted DNS,
and effective DNS must all return to the fully managed health state. A failed
bootstrap, restart, or health readback is reported as `recovery_required`, and
the root-private rollback directory is printed and retained for manual
recovery. The installer deletes that snapshot only after restoration has been
verified; it never reports a failed or unverified restart as restored.

Rollback handlers run only in the main installer process, never in inherited
Bash command-substitution error traps. Optional DNS flags may be absent. Before
stopping or moving a replacement, recovery requires a complete root-owned
snapshot; replacement files are moved into that snapshot rather than deleted
before restoration. A missing snapshot leaves the current files intact.

After this bootstrap has installed a protocol-compatible update-capable daemon,
normal App updates do not require another administrator dialog. On launch, the
App first compares the daemon's authenticated component status with the signed
bundle's version-matched `BuildManifest.plist`. An exact match avoids reading
and hashing three unchanged executables. A missing, malformed, or mismatched
manifest falls back to bounded executable reads and runtime SHA-256 comparison;
it never declares an update current. Changed binaries cross the authenticated
XPC channel, are independently validated against the same leaf certificate,
atomically replaced with rollback, and restarted by the daemon or launchd.
Daemon replacement remains
`update_pending` across launchd restart until the new set passes full network
health; App and CLI report success only after that commit. Plist, path-layout,
signing-certificate, or control-protocol migrations still require **Install /
Repair Daemon**.

### Migrating an older control protocol

The App recognizes an authenticated response from any older control protocol.
It does not reinterpret a connection failure, malformed
reply, missing marker file, or error string as proof of a legacy daemon. In the
confirmed legacy state the tray shows `Daemon upgrade required` and disables
all incompatible XPC actions. Select the emphasized `Upgrade Daemon…` item (or
`Tools > Install / Repair Daemon… (Required)`) and authorize the existing
verified installer. Repair preserves the root-owned active profile and does
not import user profile bytes again.

The repair briefly restarts Mihomo and migrates legacy DNS state so that
Global DNS is owned only together with Enhanced TUN. It succeeds only after a version-3 tray-state response is
received; cancellation, timeout, rollback, or another older response leaves the repair-required state
visible. An installation with a root-owned active profile must also pass the
full controller/TUN/Fake-IP/DNS health gate. Without one, repair safely remains
in REJECT-only provisioning with the agent and TUN stopped until
the user activates a profile. Verify that `component-version` reports the
current App version and the root daemon/agent/Mihomo and root-owned CLI came
from the verified App snapshot. The root installer rejects a version below its
existing root-owned floor; a legacy installation without that marker proceeds
only after the exact snapshot CLI authenticates protocol 1. Do not use the old
version-1 component-update operation as a migration shortcut.

All privileged installer modes share one root-owned BSD file lock. A concurrent
install, restore, profile transaction, start, or restart is rejected before it
changes state. The persistent lock file is not itself evidence of a running
operation and must not be deleted as stale; the kernel lock is released
automatically when its process exits. Repair also refuses to replace files while
`component-update-pending.plist` exists. It first stops the old daemon, confirms
the pending transaction is absent, and only then snapshots the stable rollback
source.

The in-daemon component updater publishes `component-update-pending.plist`
only after the old runtime has reached its verified stopped state. Once the
marker is published, its root-owned transaction directory is retained until
commit or rollback clears both. A failed preflight therefore cannot leave a
pending marker whose rollback directory has already been removed.

Stopping the old runtime allows the agent 6 seconds after SIGTERM and 4 more after
SIGKILL, and the stopped-state verification keeps checking for a late exit for its
whole 6-second window. A long-running agent under load once needed more than the
earlier 3 + 2 seconds; the update then failed closed and left the proxy stopped
until `mihomoboxctl start`, although no component had been replaced. The first
start of replaced components may take up to 60 seconds before the update rolls
back (other runtime starts keep 20 seconds): macOS assesses new binaries on first
launch, and under load that alone exceeded 20 seconds.

The 0.8.1 and 0.8.2 installers incorrectly inspected the opened lock through
the `/dev/fd` pathname, whose macOS device number differs from the underlying
file. They can therefore report `privileged mutation lock changed while
opening` before taking the kernel lock or changing installed components or
networking. Do not delete the persistent lock file or modify the signed App
bundle. Use a signed 0.8.3-or-later App to retry Install / Repair.

Sparkle performs automatic signed update checks from the Swift user process.
It verifies the signed appcast, the enclosure's EdDSA signature, Apple code
signature, and notarization chain before atomically replacing the App and
relaunching. System profiling is disabled. The updater never changes the root
LaunchDaemon directly; the relaunched App performs the existing authenticated
three-component synchronization. Updater diagnostics must not include proxy or
subscription configuration.

Production installs default to automatic background checks and downloads.
Users can disable or re-enable both through Config > Automatic Updates; Sparkle
persists that choice in its native settings. Because a menu-bar App may run for
weeks without quitting, MihomoBox accepts Sparkle's automatic-download callback
and immediately performs its no-UI install/relaunch; the independent root
runtime stays active during the App replacement. Sparkle's impatient interval
is also bounded to 12 hours as a fallback if immediate installation cannot
complete. Platform permission, authorization, or relaunch constraints may
still require user interaction; the application does not bypass those macOS
gates.

Inspect without changes:

```bash
scripts/install-daemon.sh --app-bundle /Applications/MihomoBox.app --dry-run
```

Dry-run is intentionally unprivileged and is not signature or release proof.
Real root execution of `install-daemon.sh` accepts only the private snapshot
created and verified by the signed Swift bootstrap.

## Restore

Stop the service and restore normal networking while preserving profiles and
installation files:

```bash
mihomoboxctl stop
```

The tray no longer uses this as the Enhanced TUN switch: disabling Enhanced TUN
releases Global DNS and returns to standby, keeping the core available for App
Proxy. The explicit CLI stop remains
a recovery operation for Mihomo; it also restores any legacy DNS backup,
removes a daemon-created alias, flushes caches, stops TUN, and removes its routes.

To remove the installed service and files entirely, invoke the CLI inside the
signed App (the standalone root-owned CLI deliberately cannot authorize an App
snapshot):

```bash
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl uninstall
```

Restore stops the daemon, agent, and Mihomo child, restores the backed-up service/global DNS,
removes only a daemon-created alias, restarts a previously active Homebrew
Mihomo service, removes the managed CLI symlink, and removes installed system
files. As a fallback for an installation whose daemon never completed the
[legacy cleanup](#legacy-local-doh-cleanup), restore also removes the retired
Local DoH profile and trust anchor.

## CLI

```bash
mihomoboxctl status [--json]
mihomoboxctl profile list [--json]
mihomoboxctl profile import /path/to/profile.yaml [--activate]
mihomoboxctl profile import-url URL [--name profile.yaml] [--activate]
  [--auth none|basic|digest|bearer|header]
  [--username USER] [--header NAME] [--secret-stdin]
mihomoboxctl profile switch profile.yaml
mihomoboxctl profile reload
mihomoboxctl install [--detached]
mihomoboxctl start
mihomoboxctl restart
mihomoboxctl stop
mihomoboxctl components update
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl uninstall
```

Only `install` and `uninstall` invoke the administrator-authorized installer.
Status, profile, lifecycle, Enhanced TUN, outbound-mode, proxy-selection, and
latency operations use the fixed, versioned XPC allowlist. `components update`
uses the same boundary for the fixed signed binary set and never accepts a path
or arbitrary filename. The daemon accepts only a CLI signed with its exact leaf
certificate. `stop` terminates the agent; the agent restores DNS while the
daemon and Mach service remain available.

For automation, `status` exits with `0` for a running or safely stopped
consistent network, `1` when MihomoBox is not installed, `2` for an inconsistent
network, and `3` when launchd has the job loaded but its runtime is unavailable.
Invalid CLI usage exits with `64`.

HTTP authentication examples:

```bash
# Basic and Digest prompt for the password without echoing it.
mihomoboxctl profile import-url https://example.invalid/basic \
  --name work.yaml --auth basic --username example-user --activate
mihomoboxctl profile import-url https://example.invalid/digest \
  --name digest.yaml --auth digest --username example-user

# Bearer token from stdin for SSH/automation; avoid putting it in shell history.
printf '%s\n' "$MIHOMOBOX_SUBSCRIPTION_TOKEN" | \
  mihomoboxctl profile import-url https://example.invalid/bearer \
    --name remote.yaml --auth bearer --secret-stdin --activate

# API key or another provider-specific header.
printf '%s\n' "$MIHOMOBOX_SUBSCRIPTION_KEY" | \
  mihomoboxctl profile import-url https://example.invalid/header \
    --name api-key.yaml --auth header --header X-API-Key --secret-stdin
```

The URL is never printed or sent to root. The downloaded profile is limited to
16 MiB and only its bytes and safe filename cross XPC for validation and an
atomic profile transaction. Credentials are intentionally not persisted;
importing or refreshing requires supplying them again.

## Runtime Paths

```text
~/Library/Application Support/MihomoBox/profiles/
~/Library/Application Support/MihomoBox/active-profile
/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist
/Library/Application Support/Mihomo App/daemon.json
/Library/Application Support/Mihomo App/controller.json
/Library/Application Support/Mihomo App/controller-secret
/Library/Application Support/Mihomo App/component-version
/Library/Application Support/Mihomo App/component-update-pending.plist
/Library/Application Support/Mihomo App/provisioning
/Library/Application Support/Mihomo App/homebrew-mihomo-was-running
/Library/Application Support/Mihomo App/homebrew-mihomo-launchd.plist
/Library/Application Support/.mihomobox-install.lock
/Library/Application Support/Mihomo App/mihomo
/Library/Application Support/Mihomo App/mihomo-daemon
/Library/Application Support/Mihomo App/mihomo-agent
/Library/Application Support/Mihomo App/mihomoboxctl
/Library/Application Support/Mihomo App/mihomo-data/config.yaml
/Library/Application Support/Mihomo App/profiles/
/Library/Application Support/Mihomo App/active-profile
/Library/Logs/Mihomo App/mihomo.log
/Library/Logs/Mihomo App/mihomo-daemon.log
/Library/Logs/Mihomo App/mihomo-daemon-crash.log
/Library/Logs/Mihomo App/mihomo-agent.log
/Library/Logs/Mihomo App/mihomo-agent-crash.log
/Library/Logs/Mihomo App/mihomo-agent-command.log
/Library/Logs/Mihomo App/mihomo-agent-command-crash.log
```

Each root-service file is limited to 100 MiB and keeps three numbered
generations (`.1` through `.3`). Normal logs are batch-written at most once per
second or when 64 KiB is ready. `mihomo.log` contains aggregate output counts
rather than raw Mihomo lines. The crash logs are independent of normal rotation
so a panic or fatal-signal record survives even when the main log rolls. The
native App writes its bounded diagnostics to the macOS unified log under
subsystem `dev.linsheng.mihomo-app`; old files under
`~/Library/Logs/MihomoBox` are legacy artifacts and are not current 0.8 logs.
The tray's `Tools > Open Diagnostic Logs…` command opens Console and the daemon
log folder. Healthy tray-state reads do not produce per-request success lines,
and healthy DNS forwarding is summarized once per minute; errors, degraded DNS
windows, mutations, and lifecycle transitions retain prompt audit records.

The user paths stage local tray imports before daemon installation. When a
profile accompanies first installation, the unprivileged App freezes its
bounded bytes before authorization; root never reopens that user-writable path.
After the verified installer brings up the daemon, the App sends those bytes
through the typed XPC profile transaction for validation and activation. If
that first-install activation fails, it stops the agent and confirms TUN and
system DNS restoration before returning the error, rather than leaving the
minimal direct profile active.

## DNS ownership

There is no separate DNS mode. Enhanced TUN owns macOS Global DNS together with
TUN, so `daemon.json` keeps `manageSystemDNS`, `globalDNSFallbackEnabled` and
`enhancedTUNEnabled` equal; the tray switch and `mihomoboxctl rpc set-tun`
change all three together. Config shows the result read-only as
**Global DNS** or **System DNS**.

- TUN on: macOS PrimaryService DNS → `127.0.0.53:53` agent bridge → Mihomo DNS
  `127.0.0.1:1153` with Fake-IP answers. `scutil --dns` shows `198.18.0.1`.
- TUN off: standby. System DNS is left untouched, and Mihomo stays up for App
  Proxy, whose captured DNS the daemon resolves over XPC.

See [Daemon and DNS](daemon-and-dns.md) for the bridge, original-DNS escape and
restoration details.

## Legacy Local DoH cleanup

Earlier releases offered Local DoH (LocalHttpDns): a loopback HTTPS DNS server
on `127.0.0.1:443`, the split-DNS configuration profile
`dev.linsheng.mihomobox.local-doh`, a System-keychain trust anchor, identity
files under `/Library/Application Support/Mihomo App/local-doh/`, a prepared
`MihomoBox-Local-DoH.mobileconfig`, and a DNS IPC directory
`mihomo-data/.dns-ipc`. The feature and its `local-doh` CLI commands are
removed. A leftover profile would keep sending its domains to a listener that
no longer exists, so the daemon removes these artifacts itself.

At every daemon start the daemon runs an idempotent cleanup with fixed commands
only: it checks for the profile with `profiles show`, removes it with
`profiles remove ... -forced` and checks again; removes the trust anchor with
`security remove-trusted-cert -d` and `security delete-certificate -Z`
(reading only root-owned regular files of at most 64 KB); deletes the `local-doh/`
directory, the prepared `.mobileconfig` and `.dns-ipc`; and flushes DNS caches
when it removed the profile. When it finds anything to clean, it logs one line
to `mihomo-daemon.log`, without profile or certificate contents:

```text
event=legacy_local_doh_cleanup profile=<absent|removed|removal_required|unknown> trust=<absent|removed|partially_removed> files=<absent|removed|failed>
```

`mihomoboxctl status --json` reports `health.legacy_local_doh_profile_removed`.
While it is `false`, turning Enhanced TUN on runs the cleanup again first.
`profile=removal_required` means macOS did not confirm removal (`unknown`: the
profile database could not be read). Remove the profile in
**System Settings > Privacy & Security > Profiles**, or:

```bash
sudo profiles remove -type configuration -identifier dev.linsheng.mihomobox.local-doh
```

`trust=partially_removed` means a `security` command failed. The identity files
are deleted afterwards, so later runs cannot retry it; review the System
keychain in Keychain Access and delete only the exact retired MihomoBox
certificate, not every certificate sharing its name. Uninstall repeats the
profile and trust removal as a fallback. An installer failure that mentions
Local DoH is logged by the App as
`event=privileged_installer ... reason=legacy_local_doh_cleanup`.

## Diagnosis

Acceptance must include normal system DNS and an HTTPS request without a
custom CA, `--insecure`, or an explicit HTTP proxy; a proxy-only success is not
proof that the system resolver works.

```bash
sudo launchctl print system/dev.linsheng.mihomo.daemon
sudo '/Library/Application Support/Mihomo App/mihomo-agent' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --check-system-dns
sudo '/Library/Application Support/Mihomo App/mihomo-agent' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --check-system-dns-restored
sudo '/Library/Application Support/Mihomo App/mihomo-agent' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --health
tail -f '/Library/Logs/Mihomo App/mihomo-daemon.log'
tail -f '/Library/Logs/Mihomo App/mihomo-agent.log'
tail -f '/Library/Logs/Mihomo App/mihomo.log'
tail -f '/Library/Logs/Mihomo App/mihomo-daemon-crash.log'
tail -f '/Library/Logs/Mihomo App/mihomo-agent-crash.log'
log stream --style compact --predicate 'subsystem == "dev.linsheng.mihomo-app"'
log show --last 10m --style compact \
  --predicate 'subsystem == "dev.linsheng.mihomo-app" AND eventMessage CONTAINS "event=app_startup"'
grep 'event=daemon_startup' '/Library/Logs/Mihomo App/mihomo-daemon.log'
grep 'event=agent_startup' '/Library/Logs/Mihomo App/mihomo-agent.log'
grep 'event=legacy_local_doh_cleanup' '/Library/Logs/Mihomo App/mihomo-daemon.log'
dig @127.0.0.53 mihomobox-health.invalid
dig @127.0.0.53 example.com
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```

With Enhanced TUN on, the `127.0.0.53` probes exercise the same Global DNS
bridge path as the system resolver, and `scutil --dns` shows `198.18.0.1`. Any
well-formed answer to `mihomobox-health.invalid`, including a negative one,
proves the bridge answers. With TUN off the bridge is not used and system DNS
is the original one. MihomoBox no longer listens on `127.0.0.1:443`; a remaining
`dev.linsheng.mihomobox.local-doh` profile in `profiles show` is a
[legacy cleanup](#legacy-local-doh-cleanup) problem, not a DNS mode.

The `--check-system-dns` command verifies the persisted CurrentSet
PrimaryService DNS value (or the Global DNS dictionary when no primary service
is available). `scutil --dns` verifies the effective dynamic resolver state; the
installer requires both checks to pass.

The inverse `--check-system-dns-restored` command succeeds only when the
managed address is absent from Global DNS and every service DNS entry in the
persistent CurrentSet, and from every current dynamic Global/service DNS state.
Provisioning installation also requires no managed
agent or Mihomo process, no TUN or Fake-IP route, and no managed DNS listener
before it reports a safely stopped runtime.

`--health` reports controller, TUN, Fake-IP route, Mihomo DNS, the Global DNS
bridge (`dns_bridge_ready`), system DNS ownership (`system_dns_managed`), and
overall consistency. The first failed Enhanced-mode
observation immediately disables Fake-IP answers. Domains still owned by
Fake-IP fail closed instead of leaking to original DNS; only domains explicitly
excluded by the active Fake-IP policy may receive real upstream answers.
Recovery starts after three consecutive failures. TUN-off standby does not
accrue those failures. Health is not proof of Internet reachability;
acceptance must still exercise actual DNS and HTTPS.

### MTTA DNS Proxy

A corporate DNS Proxy provider (`NEDNSProxyProvider`) such as MTTA
(`com.sankuai.sec.mtta.dns`) intercepts every port-53 flow, loopback included.
It forwards standard QUERY-opcode UDP (rewriting the transaction ID), drops
STATUS-opcode queries, and loopback TCP DNS through it fails. Older releases
probed the bridge with a STATUS query, so on such a Mac `dns_bridge_ready`
stayed `false` and turning TUN on rolled back. The bridge probe is now a
standard A query for `mihomobox-health.invalid` with a random ID, and any
well-formed answer counts.

```bash
systemextensionsctl list
scutil --nc list
dig @127.0.0.53 mihomobox-health.invalid
```

The first two show whether a DNS proxy is installed and active. With TUN on,
the `dig` should get an answer. Known limitation: while MTTA is active, a
truncated Global DNS answer cannot be retried over TCP. The daemon's App Proxy
resolver queries Mihomo on port 1153, not port 53, so MTTA does not see those
queries. Unverified on a device: whether per-app DNS (the App Proxy's
`NEDNSSettings`) reaches the App Proxy at all while MTTA's DNS Proxy is active.

### App Proxy DNS failures

The extension resolves captured DNS through `dns.resolve` on
`dev.linsheng.mihomo.daemon.control`. A failure gives the application no answer;
the provider records `dnsFailed` receipts and `dns_failed_*` counters, visible
in `mihomoboxctl app-proxy runtime`. The daemon does not log individual
queries, and `dns.resolve` is excluded from the routine audit log. Its error
replies are:

| Error | Meaning |
|---|---|
| `dns_invalidQuery` | Not a one-question standard query |
| `dns_busy` | 128 queries already in flight; extra queries fail at once |
| `dns_invalidResponse` | Mihomo's answer did not match the query ID, question or opcode |
| `dns_unavailable` | No answer from Mihomo DNS at `127.0.0.1:1153` (error or 4000 ms timeout) |

The extension itself waits at most 6 seconds. Check, in order:

- The daemon version. An older daemon rejects `dns.resolve`, so every App Proxy
  DNS query fails; upgrade the daemon together with the App (normal component
  synchronization or `mihomoboxctl components update`).
- `mihomo-daemon.log` for `result=peer_not_permitted role=<role>`. The daemon
  serves `dns.resolve` only to a peer whose code satisfies identifier
  `dev.linsheng.mihomo-app.app-proxy` plus the release certificate family,
  logged once per connection as `event=control_peer_classified
  role=app_proxy_extension`. `role=controller` on `dns.resolve` means the
  caller is not that extension; `role=app_proxy_extension` on any other
  operation means the extension asked for something it may not call.
- Whether the sandboxed extension can look up the Mach service at all. Its
  entitlement carries a `mach-lookup` temporary exception for
  `dev.linsheng.mihomo.daemon.control`; that this exception works for the
  sandboxed system extension is not yet verified on a device.
- Mihomo DNS itself: `mihomo_dns_ready` in `--health`.
