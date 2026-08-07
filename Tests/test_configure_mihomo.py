import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).parents[1] / "deploy" / "configure_mihomo.py"
SPEC = importlib.util.spec_from_file_location("configure_mihomo", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ConfigureMihomoTests(unittest.TestCase):
    def test_apply_is_idempotent_and_restore_is_exact(self):
        original = """port: 7890
tun:
  enable: true
dns:
  enable: true
  listen: :53
  enhanced-mode: fake-ip
  respect-rules: true
  nameserver:
    - https://1.1.1.1/dns-query
rules:
  - MATCH,Proxy
"""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = root / "config.yaml"
            backup = root / "backup.yaml"
            config.write_text(original)
            MODULE.apply(config, backup)
            once = config.read_text()
            MODULE.apply(config, backup)
            self.assertEqual(config.read_text(), once)
            self.assertIn("  listen: 127.0.0.1:1153\n", once)
            self.assertIn("  respect-rules: false\n", once)
            self.assertIn("log-level: error\n", once)
            self.assertIn("  fake-ip-ttl: 1\n", once)
            for key in ("nameserver", "direct-nameserver", "proxy-server-nameserver"):
                self.assertIn(f"  {key}:\n    - tcp://127.0.0.1:1054\n", once)
            self.assertIn("external-controller: 127.0.0.1:9090\n", once)
            first_secret = MODULE.top_level_scalar(once.splitlines(keepends=True), "secret")
            self.assertRegex(first_secret, r"^[0-9a-f]{64}$")
            self.assertIn("  enhanced-mode: fake-ip\n", once)
            MODULE.restore(config, backup)
            self.assertEqual(config.read_text(), original)

    def test_controller_and_generated_secret_are_persisted(self):
        original = """external-controller: 0.0.0.0:9191
secret: ''
tun:
  enable: true
dns:
  enable: true
"""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = root / "config.yaml"
            backup = root / "backup.yaml"
            secret_file = root / "controller-secret"
            metadata = root / "controller.json"
            daemon = root / "daemon.json"
            config.write_text(original)
            daemon.write_text("{}\n")

            MODULE.apply(config, backup, secret_file, metadata, daemon)

            configured = config.read_text()
            secret = secret_file.read_text().strip()
            self.assertRegex(secret, r"^[0-9a-f]{64}$")
            self.assertIn("external-controller: 127.0.0.1:9191\n", configured)
            self.assertIn(f'secret: "{secret}"\n', configured)
            self.assertEqual(
                json.loads(metadata.read_text()),
                {"url": "http://127.0.0.1:9191", "secret": secret},
            )
            daemon_config = json.loads(daemon.read_text())
            self.assertEqual(
                daemon_config["controllerEndpoint"],
                {"host": "127.0.0.1", "port": 9191},
            )
            self.assertEqual(daemon_config["controllerSecret"], secret)
            self.assertEqual(secret_file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)

            config.write_text(original)
            MODULE.apply(config, backup, secret_file, metadata, daemon)
            self.assertEqual(secret_file.read_text().strip(), secret)

    def test_remote_controller_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "loopback"):
            MODULE.normalize_controller("192.0.2.10:9090")

    def test_quoted_scalars_allow_yaml_comments(self):
        self.assertEqual(MODULE.parse_yaml_scalar('"" # generated when activated'), "")
        self.assertEqual(MODULE.parse_yaml_scalar("'a''b' # comment"), "a'b")

    def test_missing_dns_block_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.dns_block(["port: 7890\n"])

    def test_managed_dns_rejects_disabled_tun(self):
        original = """tun:
  enable: false
dns:
  enable: true
  enhanced-mode: fake-ip
"""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = root / "config.yaml"
            backup = root / "backup.yaml"
            config.write_text(original)
            with self.assertRaisesRegex(ValueError, "requires tun.enable: true"):
                MODULE.apply(config, backup)
            self.assertEqual(config.read_text(), original)


if __name__ == "__main__":
    unittest.main()


class ProxyServerExclusionTests(unittest.TestCase):
    def test_server_hosts_come_from_the_proxies_block_only(self) -> None:
        lines = (
            "dns:\n  server: 1.1.1.1\n"
            "proxies:\n"
            "  - name: A\n    server: jp.example.com\n    port: 443\n"
            "  - name: B\n    server: 203.0.113.9\n    port: 443\n"
            "  - name: C\n    server: jp.example.com\n    port: 8443\n"
            "rules:\n  - MATCH,Proxy\n"
        ).splitlines(keepends=True)
        self.assertEqual(
            MODULE.proxy_server_hosts(lines),
            ["jp.example.com", "203.0.113.9"],
        )

    def test_fake_ip_answers_are_never_excluded(self) -> None:
        # Writing a Fake-IP address into the exclusion list would exclude an
        # address the kernel never dials while leaving the real one captured —
        # worse than writing nothing.
        self.assertEqual(MODULE.resolve_addresses([], "198.18."), [])
        lines = "dns:\n  fake-ip-range: 198.18.0.1/16\n".splitlines(keepends=True)
        self.assertEqual(MODULE.fake_ip_prefix(lines), "198.18.")
        lines = "dns:\n  fake-ip-range: 10.0.0.1/8\n".splitlines(keepends=True)
        self.assertEqual(MODULE.fake_ip_prefix(lines), "10.")

    def test_exclusion_is_skipped_when_nothing_resolves(self) -> None:
        # Resolution fails transiently; a stale-but-correct list from a previous
        # load is worth more than an empty one. Stubbed rather than resolved for
        # real: a name that should not exist still resolves on networks whose
        # DNS hijacks NXDOMAIN, which is exactly how this test first failed.
        lines = (
            "tun:\n  enable: true\n  auto-route: true\n"
            "dns:\n  fake-ip-range: 198.18.0.1/16\n"
            "proxies:\n  - name: A\n    server: jp.example.com\n    port: 443\n"
        ).splitlines(keepends=True)
        original = MODULE.resolve_addresses
        MODULE.resolve_addresses = lambda hosts, prefix: []
        try:
            self.assertEqual(MODULE.exclude_proxy_servers_from_tunnel(lines), lines)
        finally:
            MODULE.resolve_addresses = original

    def test_exclusion_writes_every_resolved_address(self) -> None:
        lines = (
            "tun:\n  enable: true\n  auto-route: true\n"
            "dns:\n  fake-ip-range: 198.18.0.1/16\n"
            "proxies:\n  - name: A\n    server: jp.example.com\n    port: 443\n"
        ).splitlines(keepends=True)
        original = MODULE.resolve_addresses
        MODULE.resolve_addresses = lambda hosts, prefix: ["198.51.100.7", "203.0.113.9"]
        try:
            text = "".join(MODULE.exclude_proxy_servers_from_tunnel(lines))
        finally:
            MODULE.resolve_addresses = original
        self.assertIn("  route-exclude-address:\n", text)
        self.assertIn("    - 198.51.100.7/32\n", text)
        self.assertIn("    - 203.0.113.9/32\n", text)
        # The rest of the tun block survives.
        self.assertIn("  enable: true\n", text)
        self.assertIn("  auto-route: true\n", text)

    def test_exclusion_replaces_rather_than_appends_on_reload(self) -> None:
        lines = (
            "tun:\n  enable: true\n"
            "  route-exclude-address:\n    - 203.0.113.1/32\n"
            "  auto-route: true\n"
        ).splitlines(keepends=True)
        result = MODULE.replace_tun_list(
            lines, "route-exclude-address", "    - 198.51.100.7/32\n"
        )
        text = "".join(result)
        self.assertIn("    - 198.51.100.7/32\n", text)
        self.assertNotIn("203.0.113.1", text)
        self.assertEqual(text.count("route-exclude-address"), 1)
        self.assertIn("  auto-route: true\n", text)
