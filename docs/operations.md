# Operations

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

For the private VPN regression, check the system route to `192.168.13.12`, then
run `ssh -o BatchMode=yes -o ConnectTimeout=10 m4pro /usr/bin/true` from the actual
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
still opens a picker). Embedded signed helpers follow the
application's route. Open **Signed executables** to inspect the discovered
paths, Signing IDs, Team IDs and designated requirements in a separate panel.
Refresh Nodes reads routing, available targets and extension status concurrently,
without repeating the signature scan or replacing an edited draft. The signature
inventory is cached for the displayed application list; use Rescan in the details
panel (or Rescan Signed Executables in the actions menu) after installing or
updating an app. Activation always performs a fresh signature verification.
Unsigned files and duplicate executable ownership are rejected.

Search applications or search inside each node picker. The fixed bottom bar
shows unsaved edits and keeps Apply, Discard and the extension switch visible.
An external settings change preserves the draft but blocks Apply until Discard
loads the latest saved settings, preventing accidental overwrites.
Choose a node or proxy group for every entry, then **Apply Changes**. Each row
has **Authorize & Enable**, **Retry Authorization** and **Disable** actions.
Authorize rescans that application's signed executables and lists them for one-click
confirmation; no file picker is needed for code in the home directory,
`/Applications`, `/opt/homebrew` or `/usr/local`. Other rows and their node
choices remain saved; declining one application's consent does not discard or
block other authorized applications. An application publishes rules only after
all of its discovered code and responsible hosts pass read-only access and
signature checks. Missing/new code requiring consent withdraws that application's
rules and displays a pending state; it is not labeled connected. Unselected or
pending applications follow the remaining macOS network configuration, including
TUN when applicable. No direct fallback is added by App Proxy.

**Turn Off** pauses the shared service while preserving row selections;
**Resume Selected Apps** rechecks selected applications without opening consent
panels. A fresh installation and legacy configurations without a verified
identity snapshot start with no selected applications. Existing v4 identities
seed selections; old bookmarks without durable publisher pins require one
explicit per-row reauthorization. Preferences belong to the logged-in user;
root profile settings still retain the complete application/node list.
An open consent panel continues renewing only the previous verified generation;
new rules are committed together after provider validation, with verified
rollback or complete shutdown on an ambiguous system-wide failure. Shared
Terminal rules contain only the admitted executables, never all child processes.

A LoadBalance group is accepted only when every candidate
resolves to a remote proxy. macOS may require Network Extension and VPN approval.
Disable App Proxy before adding or removing entries. Removing an entry only
removes its proxy routing, never the installed application. Apply saves these
changes; Restore Default Apps brings back the four initial categories.

Each entry's **Policy** editor adds code that shares that entry's node, in three
scopes, one entry per line (type, paste or drag in):

- **Team IDs**: every signed app in `/Applications` and `~/Applications`, and every
  CLI in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, signed by the team.
  Dropping an app fills in its Team ID.
- **Directories**: every signed executable below the folder, including versions
  installed later.
- **CLI executables**: exactly these executables (or **Choose Executable…**).

Then **Update Draft**, **Apply Changes**, and authorize the app. Turn App Proxy off
before editing a policy. A Team ID or directory belongs to one app. A scope follows
the code regardless of its launcher; it does not include every descendant of an app.
New tools under a scope are picked up by the next background scan (within about
20 seconds).

The same operations are available from a shell, run as the logged-in user:

```bash
mihomoboxctl app-proxy policy show chatgpt
mihomoboxctl app-proxy policy set chatgpt --team 2DC432GLL2 --directory ~/.codex
mihomoboxctl app-proxy targets chatgpt
mihomoboxctl app-proxy enable chatgpt --approve
mihomoboxctl app-proxy runtime
```

`policy set` replaces all three scopes of one application in the daemon-owned
settings. `targets`, `runtime`, `enable`, `disable`, `on` and `off` run the signed
MihomoBox host headlessly (`mihomo-app --app-proxy …`); the CLI first verifies that
host against its own Developer ID leaf. `--approve` consents to the scanned code and
scopes exactly as the confirmation sheet does; without it only earlier approvals
apply. A headless run and the menu-bar app serialize their App Proxy changes with a
per-user lock. `runtime` also prints the provider's recent process-validation stages
and counters (PIDs only, no paths or traffic), the same receipts the app shows.
For scripts, select the signed interpreter, which also covers its other uses.
Limits are 32 additional executables per entry and 128 total. Duplicate ownership,
missing files, unsigned programs and directories are rejected before accepting
the draft. Symlinks resolve to their canonical executable path, signatures are
verified again on activation, and the Signed executables panel includes these
additional binaries. Existing configurations migrate with an empty explicit list.

For authenticated remote diagnosis, `mihomoboxctl app-proxy status` reads the
saved list and `mihomoboxctl app-proxy set-all Proxy` transactionally assigns
the existing entries to a group through the same typed XPC validation. Neither
command changes macOS extension approval or adds application identities.

This page does not prepare or enable Local DoH. A fresh CLI installation keeps
Local DoH unprepared until the operator explicitly invokes Prepare & Trust.
App Proxy forwards captured DNS queries over TCP to the existing Mihomo DNS
listener at `127.0.0.1:1153`, sharing the TUN resolver and its Fake-IP policy.
Its per-app resolver advertises the managed TUN DNS address `198.18.0.1`,
not `127.0.0.1:53` where no DNS service is bound. Low-level resolver calls
must be tested with App Proxy enabled: successful hostname/SOCKS forwarding
alone does not establish that system name resolution works.
It does not publish a supplemental default DNS resolver or use a separate
public DoH service. DNS follows the core's shared configuration; each app's
selected node still controls its proxied connections. With TUN off, the core's
standby DNS returns real addresses. A failed core DNS request fails closed.
Disabling Enhanced TUN keeps that standby core and DNS available, including
when switching away from Global DNS fallback. `mihomoboxctl rpc set-tun false`
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
over typed XPC into a controller/DNS standby state with TUN off. LocalHttpDns
certificate/profile preparation follows; a failed activation leaves the macOS
system DNS list untouched.

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
root-owned component version floor. It does not send v2 runtime mutations or
relax the certificate/profile prerequisite; missing or unsafe version state
and newer daemon protocols remain rejected.

The app name in user-facing copy, system extension metadata, DNS profiles and
VPN configuration names is **MihomoBox**. Feature labels such as App Proxy and
Local DoH describe functionality; Mihomo names the bundled upstream core.

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
Existing installed DNS/VPN names update when their configuration is regenerated
and approved or re-enabled, respectively.
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
   agent in TUN-off standby;
7. verifies controller, Mihomo DNS, absent TUN/Fake-IP route, and that no
   MihomoBox address remains in persistent or effective system DNS.

From the Config page, **Prepare & Trust / Open Profile** asks for explicit
confirmation of SSL trust and then asks the authenticated
root daemon to prepare a global/default DNS profile, independent of domain rules
and controller mode. The daemon writes the fixed profile at
`/Library/Application Support/Mihomo App/MihomoBox-Local-DoH.mobileconfig` as
root:wheel mode `0644` and returns only aggregate counts. The profile contains
both a `com.apple.security.root` certificate payload and the global DNS payload,
but manual macOS profile approval does not itself prove SSL trust. In the
same typed XPC transaction, the already-installed root daemon validates that
artifact, keeps its control service and standby agent online, generates a
root-owned local CA and loopback server certificate/private key, discards the
CA private key, and starts the daemon-owned DoH endpoint. The endpoint is
validated independently; profile preparation does not require TUN or a Fake-IP
route. It always forwards raw DNS through Mihomo's root-private Unix socket;
TUN-off standby makes Mihomo return real addresses. When Mihomo is stopped or
IPC is unresponsive, a daemon-owned forwarder uses current physical/scoped DNS
without depending on the agent, changing system DNS, or stopping port 443.
Valid Mihomo DNS error responses are returned unchanged. Preparation failure restores the previous
identity and prepared profile atomically before returning an error.
After preparation, the App sends a separate fixed `local-doh.trust-certificate`
action to install the current CA into the System keychain with SSL-only Admin
trust. It permits a macOS authorization dialog for up to two minutes, never
unlocks a keychain or weakens authorization rules, and verifies native SSL
trust before opening the profile. Cancellation/denial is reported without
automatic retry; **Trust Certificate for SSL** retries explicitly and **Open
Keychain Access** provides the manual path when system authorization cannot
run from the helper. No `sudo` or AppleScript is used. The App opens the
validated root-owned profile. Apple requires the
user to finish installation in **General > Device Management**; **Open Device
Management** reopens that exact System Settings pane at any time. There is no
normal LocalHttpDns-off action: after approval it remains available whether
Enhanced TUN is on or off. Full helper uninstall verifies removal of the fixed
profile identifier before deleting legacy trust residue, server identity and
the root installation.

Config shows separate `Awaiting macOS Approval`, `Active`, and `Needs Attention`
states. It refreshes authenticated root/profile state while visible, so
finishing approval in System Settings does not require relaunching the App.
New profiles omit `SupplementalMatchDomains` for global coverage. Existing split
profiles need one regeneration and manual reinstall to adopt this behavior;
later rule, selector, and GeoSite changes no longer require profile regeneration.

There are two intentionally separate startup mechanisms. The root LaunchDaemon
starts LocalHttpDns and the managed Mihomo runtime at system startup. The
`enhancedTUNResumeEnabled` preference restores the last explicit TUN choice;
turning TUN off survives restarts and component updates. Upgrades use the old
current state instead of the legacy "ever enabled" flag. LocalHttpDns is unchanged
by that choice. On launch, the App
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

The repair briefly restarts Mihomo and migrates legacy DNS state to
LocalHttpDns standby. It succeeds only after a version-3 tray-state response is
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
returns to standby and keeps LocalHttpDns active. The explicit CLI stop remains
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
files.

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

## Selecting DNS integration

In Config > DNS Integration, **Use Global DNS** persists the existing Global
DNS configuration (`globalDNSFallbackEnabled` is retained as the compatible
storage key), starts and verifies Enhanced TUN DNS at `198.18.0.1`, releases
443, and removes only MihomoBox's installed DoH profile. The App confirms this
impact before starting. A removal error remains visible, never an active-mode
success. Certificate identity files and the prepared profile are retained.

To return, choose **Prepare & Trust / Open Profile**, authorize SSL trust if
needed, and approve the profile in Device Management. **Use Local DoH** is
enabled only after certificate and installed-profile readiness. Local DoH
continues using original-network DNS when the Mihomo backend is unavailable.
Global DNS requires Enhanced TUN and restores the original DNS when stopped.

## Diagnosis

Local DoH status is available through `mihomoboxctl local-doh status`. A matched
installed profile and a listening 443 port do not prove macOS trusts HTTPS.
`certificate_trusted: false` means the current loopback certificate fails
native system SSL evaluation. Manual profile installation can import the CA
while leaving SSL trust unspecified. Review the exact current certificate in
Keychain Access; do not trust or delete every certificate sharing its name.
MihomoBox never silently grants trust; use the explicit SSL-trust action or
Keychain Access. After one minute of continuously observed
installed-profile/trust failure it releases 443 and enters Global DNS fallback.
The identity and prepared profile remain for retry; only the fixed installed
DoH profile is removed after the fallback DNS runtime passes its health gate.
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
dig @198.18.0.1 -p 53 example.com
dig @198.18.0.1 -p 53 example.com +tcp
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```

The `198.18.0.1` probes apply to Global DNS fallback; LocalHttpDns normally
listens on `127.0.0.1:443`, and 9443 is no longer used. Config reports fallback
separately from pending DoH-profile removal. A successful TUN probe alone does
not prove that macOS has stopped using the old encrypted-DNS profile.

The `--check-system-dns` command verifies the persisted CurrentSet
PrimaryService DNS value (or the Global fallback when no primary service is
available). `scutil --dns` verifies the effective dynamic resolver state; the
installer requires both checks to pass.

The inverse `--check-system-dns-restored` command succeeds only when the
managed address is absent from Global DNS and every service DNS entry in the
persistent CurrentSet, and from every current dynamic Global/service DNS state.
Provisioning installation also requires no managed
agent or Mihomo process, no TUN or Fake-IP route, and no managed DNS listener
before it reports a safely stopped runtime.

`--health` reports controller, TUN, Fake-IP route, Mihomo DNS, absence of legacy
system-DNS ownership, and overall consistency. The first failed Enhanced-mode
observation immediately disables Fake-IP answers. Domains still owned by
Fake-IP fail closed instead of leaking to original DNS; only domains explicitly
excluded by the active Fake-IP policy may receive real upstream answers.
Recovery starts after three consecutive failures. TUN-off standby does not
accrue those failures. LocalHttpDns now delegates all DNS decisions to Mihomo
over IPC when available. A stopped/restarting Mihomo uses the daemon's independent
current-network DNS fallback; the next request retries IPC automatically.
Local DoH status accepts either a ready Mihomo backend or an available original
DNS resolver configuration, plus listener and SSL trust. This is not proof of
Internet reachability; acceptance must still exercise actual DNS and HTTPS.
