import importlib.util
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
dns:
  enable: true
  listen: :53
  enhanced-mode: fake-ip
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
            self.assertIn("  listen: 127.0.0.1:1053\n", once)
            for key in ("nameserver", "direct-nameserver", "proxy-server-nameserver"):
                self.assertIn(f"  {key}:\n    - udp://127.0.0.1:1054\n", once)
            self.assertIn("external-controller: 127.0.0.1:9090\n", once)
            self.assertIn("secret: ''\n", once)
            self.assertIn("  enhanced-mode: fake-ip\n", once)
            MODULE.restore(config, backup)
            self.assertEqual(config.read_text(), original)

    def test_missing_dns_block_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.dns_block(["port: 7890\n"])


if __name__ == "__main__":
    unittest.main()
