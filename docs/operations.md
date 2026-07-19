# Operations

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.

For a remote Mac, invoke the detached installer entry point from an authenticated
SSH session with `sudo`. It is embedded at
`Contents/Resources/scripts/install-daemon-remote.sh`, starts the real installer
under `nohup`, and prints a root-only log path. Migration therefore continues if
the TUN handoff interrupts SSH. Launchd never executes from the movable App
bundle.

The visible bundle is `MihomoBox.app`. Existing
`/Library/Application Support/Mihomo App` and `/Library/Logs/Mihomo App` paths
remain stable so upgrades preserve configuration, DNS backups, and logs.

The installer:

1. copies `mihomo` and `mihomo-daemon` from the App to
   `/Library/Application Support/Mihomo App/`;
2. migrates `/opt/homebrew/etc/mihomo/` when present, otherwise installs the
   minimal default profile;
3. forces only the loopback controller and DNS recursion-boundary keys;
4. validates the copied Mihomo configuration;
5. stops a running Homebrew Mihomo service to prevent duplicate owners;
6. installs and starts the root LaunchDaemon;
7. verifies controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, persisted
   system DNS, and effective Global DNS.

It also installs `/usr/local/bin/mihomoboxctl` as a symlink to the signed App
bundle. An unrelated existing file or symlink at that path is preserved.

Upgrades migrate the former `dev.linsheng.mihomo-app.daemon` label to
`dev.linsheng.mihomo.daemon`. The old job is stopped and its plist removed
before the new job starts; rollback restores the prior running label.

Inspect without changes:

```bash
sudo scripts/install-daemon.sh --dry-run
```

## Restore

Stop the service and restore normal networking while preserving profiles and
installation files:

```bash
sudo scripts/install-daemon.sh --restore-network
```

The tray exposes the same operation as `Stop Service & Restore Network…`.
It restores Global DNS, removes the managed alias, flushes system/Mihomo DNS
caches, stops TUN, and removes its routes.

To remove the installed service and files entirely:

```bash
sudo scripts/install-daemon.sh --restore
```

Restore stops the daemon/Mihomo child, restores the backed-up Global DNS,
removes only a daemon-created alias, restarts a previously active Homebrew
Mihomo service, removes the managed CLI symlink, and removes installed system
files.

## CLI

```bash
mihomoboxctl status [--json]
mihomoboxctl profile list [--json]
mihomoboxctl profile import /path/to/profile.yaml [--activate]
mihomoboxctl profile switch profile.yaml
mihomoboxctl install
mihomoboxctl start
mihomoboxctl restart
mihomoboxctl stop
mihomoboxctl uninstall
```

`status` and `profile list` are read-only and never invoke `sudo`. Other
commands map to a fixed set of operations in the App's bundled installer; the
CLI cannot pass arbitrary privileged commands. `start` and `restart` restore
real DNS before launch and do not report success until the managed network is
consistent. `stop` restores real DNS before unloading the LaunchDaemon.

## Runtime Paths

```text
/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist
/Library/Application Support/Mihomo App/daemon.json
/Library/Application Support/Mihomo App/mihomo
/Library/Application Support/Mihomo App/mihomo-daemon
/Library/Application Support/Mihomo App/mihomo-data/config.yaml
/Library/Application Support/Mihomo App/profiles/
/Library/Application Support/Mihomo App/active-profile
/Library/Logs/Mihomo App/mihomo.log
/Library/Logs/Mihomo App/mihomo-daemon.log
```

## Diagnosis

```bash
sudo launchctl print system/dev.linsheng.mihomo.daemon
sudo '/Library/Application Support/Mihomo App/mihomo-daemon' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --check-system-dns
sudo '/Library/Application Support/Mihomo App/mihomo-daemon' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --health
tail -f '/Library/Logs/Mihomo App/mihomo-daemon.log'
tail -f '/Library/Logs/Mihomo App/mihomo.log'
curl -fsS http://127.0.0.1:9090/version
dig @127.0.0.53 -p 53 example.com
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```

The `--check-system-dns` command verifies the persisted CurrentSet Global DNS
value. `scutil --dns` verifies the effective dynamic resolver state; the
installer requires both checks to pass.

`--health` reports controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, and
system-DNS consistency. A first DNS probe failure immediately disables Fake-IP
answers and serves real IPs; a consecutive failure rolls back real system DNS
and stops the managed Mihomo child.
