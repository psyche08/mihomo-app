# Operations

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.

The installer:

1. copies `mihomo` and `mihomo-daemon` from the App to
   `/Library/Application Support/Mihomo App/`;
2. migrates `/opt/homebrew/etc/mihomo/` when present, otherwise installs the
   minimal default profile;
3. forces only the loopback controller and DNS recursion-boundary keys;
4. validates the copied Mihomo configuration;
5. stops a running Homebrew Mihomo service to prevent duplicate owners;
6. installs and starts the root LaunchDaemon;
7. verifies controller, system-DNS listener, and effective Global DNS.

Inspect without changes:

```bash
sudo scripts/install-daemon.sh --dry-run
```

## Restore

```bash
sudo scripts/install-daemon.sh --restore
```

Restore stops the daemon/Mihomo child, restores the backed-up Global DNS,
removes only a daemon-created alias, restarts a previously active Homebrew
Mihomo service, and removes installed system files.

## Runtime Paths

```text
/Library/LaunchDaemons/dev.linsheng.mihomo-app.daemon.plist
/Library/Application Support/Mihomo App/daemon.json
/Library/Application Support/Mihomo App/mihomo
/Library/Application Support/Mihomo App/mihomo-daemon
/Library/Application Support/Mihomo App/mihomo-data/config.yaml
/Library/Logs/Mihomo App/mihomo.log
/Library/Logs/Mihomo App/mihomo-daemon.log
```

## Diagnosis

```bash
sudo launchctl print system/dev.linsheng.mihomo-app.daemon
tail -f '/Library/Logs/Mihomo App/mihomo-daemon.log'
tail -f '/Library/Logs/Mihomo App/mihomo.log'
curl -fsS http://127.0.0.1:9090/version
dig @127.0.0.53 -p 53 example.com
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```
