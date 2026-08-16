# Operations

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.
If no previously authenticated active profile exists, installation stages a
REJECT-only provisioning profile and starts only the authenticated XPC daemon;
the agent, TUN, and managed DNS remain stopped. The selected user profile is
then activated over typed XPC. Only a full-health readback starts networking
and clears provisioning; a failed activation leaves real system DNS intact.

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
6. installs the XPC Mach service and starts the root daemon, which launches the agent;
7. verifies controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, persisted
   PrimaryService DNS, and effective resolver state.

There are two intentionally separate startup mechanisms. The root
LaunchDaemon starts the managed network service at system startup with the
active profile, whose managed configuration requires `tun.enable: true`. Once
the App has observed a healthy Enhanced TUN runtime, it also applies a one-time
current-user login-item default so the hidden tray App returns after login.
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

After this bootstrap has installed a protocol-compatible update-capable daemon,
normal App updates do not require another administrator dialog. On launch, the
App compares the bundled and installed daemon/agent/Mihomo digests. Changed
binaries cross the authenticated XPC channel, are independently validated
against the same leaf certificate, atomically replaced with rollback, and
restarted by the daemon or launchd. Daemon replacement remains
`update_pending` across launchd restart until the new set passes full network
health; App and CLI report success only after that commit. Plist, path-layout,
signing-certificate, or control-protocol migrations still require **Install /
Repair Daemon**.

### Migrating a 0.7 daemon

The 0.8.1 App recognizes the authenticated version-1 response emitted by an
installed 0.7 daemon. It does not reinterpret a connection failure, malformed
reply, missing marker file, or error string as proof of a legacy daemon. In the
confirmed legacy state the tray shows `Daemon upgrade required` and disables
all incompatible XPC actions. Select the emphasized `Upgrade Daemon…` item (or
`Tools > Install / Repair Daemon… (Required)`) and authorize the existing
verified installer. Repair preserves the root-owned active profile and does
not import user profile bytes again.

The repair briefly restarts Mihomo, Enhanced TUN and managed DNS. It succeeds
only after a version-2 tray-state response is received; cancellation, timeout,
rollback, or another version-1 response leaves the repair-required state
visible. An installation with a root-owned active profile must also pass the
full controller/TUN/Fake-IP/DNS health gate. Without one, repair safely remains
in REJECT-only provisioning with the agent, TUN, and managed DNS stopped until
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

Sparkle performs automatic signed update checks from the Swift user process.
It verifies the signed appcast, the enclosure's EdDSA signature, Apple code
signature, and notarization chain before atomically replacing the App and
relaunching. System profiling is disabled. The updater never changes the root
LaunchDaemon directly; the relaunched App performs the existing authenticated
three-component synchronization. Updater diagnostics must not include proxy or
subscription configuration.

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

The tray exposes the same operation through authenticated XPC.
It restores system DNS, removes the managed alias, flushes system/Mihomo DNS
caches, stops TUN, and removes its routes.

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
log folder.

The user paths stage local tray imports before daemon installation. When a
profile accompanies first installation, the unprivileged App freezes its
bounded bytes before authorization; root never reopens that user-writable path.
After the verified installer brings up the daemon, the App sends those bytes
through the typed XPC profile transaction for validation and activation. If
that first-install activation fails, it stops the agent and confirms TUN and
system DNS restoration before returning the error, rather than leaving the
minimal direct profile active.

## Diagnosis

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
dig @127.0.0.53 -p 53 example.com
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```

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

`--health` reports controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, and
system-DNS consistency. The first failed observation immediately disables
Fake-IP answers. Domains still owned by Fake-IP fail closed instead of leaking
to original DNS; only domains explicitly excluded by the active Fake-IP policy
may receive real upstream answers. Recovery starts after three consecutive
failures; only a failed recovery window rolls back real system DNS and stops
the managed Mihomo child.
