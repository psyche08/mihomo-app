#!/usr/bin/env python3
"""Apply or restore the minimal Mihomo DNS listener/upstream changes."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import secrets
import shutil
import sys
from typing import Optional

MANAGED_SCALARS = {
    "listen": "127.0.0.1:1153",
    "respect-rules": "false",
    "fake-ip-ttl": "1",
}

MANAGED_LISTS = {
    "nameserver": "tcp://127.0.0.1:1054",
    "direct-nameserver": "tcp://127.0.0.1:1054",
    "proxy-server-nameserver": "tcp://127.0.0.1:1054",
}

DEFAULT_CONTROLLER = "127.0.0.1:9090"


def top_level_block(lines: list[str], name: str) -> tuple[int, int]:
    pattern = re.compile(rf"^{re.escape(name)}:\s*(?:#.*)?$")
    start = next((index for index, line in enumerate(lines) if pattern.match(line)), None)
    if start is None:
        raise ValueError(f"top-level {name}: block not found")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.startswith((" ", "\t", "#")):
            end = index
            break
    return start, end


def dns_block(lines: list[str]) -> tuple[int, int]:
    return top_level_block(lines, "dns")


def direct_scalar(lines: list[str], section: str, key: str) -> Optional[str]:
    start, end = top_level_block(lines, section)
    pattern = re.compile(rf"^  {re.escape(key)}\s*:\s*(.*?)\s*(?:#.*)?$")
    for line in lines[start + 1 : end]:
        match = pattern.match(line.rstrip("\n"))
        if match:
            return match.group(1).strip().strip("\"'").lower()
    return None


def direct_key_range(block: list[str], key: str) -> tuple[Optional[int], Optional[int]]:
    pattern = re.compile(rf"^  {re.escape(key)}\s*:")
    start = next((index for index, line in enumerate(block) if pattern.match(line)), None)
    if start is None:
        return None, None
    end = start + 1
    while end < len(block):
        line = block[end]
        if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) <= 2:
            break
        end += 1
    return start, end


def replace_direct_scalar(block: list[str], key: str, value: str) -> list[str]:
    start, end = direct_key_range(block, key)
    replacement = [f"  {key}: {value}\n"]
    if start is None or end is None:
        return block + replacement
    return block[:start] + replacement + block[end:]


def replace_direct_list(block: list[str], key: str, value: str) -> list[str]:
    start, end = direct_key_range(block, key)
    replacement = [f"  {key}:\n", f"    - {value}\n"]
    if start is None or end is None:
        return block + replacement
    return block[:start] + replacement + block[end:]


def replace_top_level_scalar(lines: list[str], key: str, value: str) -> list[str]:
    pattern = re.compile(rf"^{re.escape(key)}\s*:")
    index = next((i for i, line in enumerate(lines) if pattern.match(line)), None)
    replacement = f"{key}: {value}\n"
    if index is None:
        return [replacement, *lines]
    return [*lines[:index], replacement, *lines[index + 1 :]]


def parse_yaml_scalar(value: str) -> str:
    value = value.strip()
    if not value or value.startswith("#"):
        return ""
    if value.startswith('"'):
        try:
            decoded, end = json.JSONDecoder().raw_decode(value)
            remainder = value[end:].strip()
            if not remainder or remainder.startswith("#"):
                return decoded if isinstance(decoded, str) else value
        except json.JSONDecodeError:
            pass
    if value.startswith("'"):
        quoted = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
        if quoted:
            return quoted.group(1).replace("''", "'")
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def top_level_scalar(lines: list[str], key: str) -> Optional[str]:
    pattern = re.compile(rf"^{re.escape(key)}\s*:\s*(.*?)\s*$")
    for line in lines:
        match = pattern.match(line.rstrip("\n"))
        if match:
            return parse_yaml_scalar(match.group(1))
    return None


def normalize_controller(value: Optional[str]) -> tuple[str, int]:
    candidate = (value or DEFAULT_CONTROLLER).strip()
    if "://" in candidate:
        candidate = candidate.split("://", 1)[1]
    candidate = candidate.rstrip("/")
    try:
        host, port_text = candidate.rsplit(":", 1)
        port = int(port_text)
    except (ValueError, AttributeError) as error:
        raise ValueError("external-controller must include a valid TCP port") from error
    if not 1 <= port <= 65_535:
        raise ValueError("external-controller port must be in 1...65535")
    if host.lower() not in {"127.0.0.1", "localhost", "0.0.0.0"}:
        raise ValueError("external-controller must be bound to loopback")
    return "127.0.0.1", port


def resolve_secret(profile_secret: Optional[str], secret_file: Optional[pathlib.Path]) -> str:
    secret = profile_secret or ""
    if not secret and secret_file and secret_file.exists():
        secret = secret_file.read_text(encoding="utf-8").strip()
    if not secret:
        secret = secrets.token_hex(32)
    if len(secret) > 256 or any(not character.isprintable() for character in secret):
        raise ValueError("controller secret is invalid")
    return secret


def atomic_write(path: pathlib.Path, data: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(data, encoding="utf-8")
    temporary.chmod(mode)
    temporary.replace(path)


def persist_controller(
    host: str,
    port: int,
    secret: str,
    secret_file: Optional[pathlib.Path],
    controller_metadata: Optional[pathlib.Path],
    daemon_config: Optional[pathlib.Path],
) -> None:
    if secret_file:
        atomic_write(secret_file, f"{secret}\n", 0o600)
    if controller_metadata:
        metadata = {"url": f"http://{host}:{port}", "secret": secret}
        atomic_write(controller_metadata, json.dumps(metadata, indent=2) + "\n", 0o640)
    if daemon_config:
        configuration = json.loads(daemon_config.read_text(encoding="utf-8"))
        configuration["controllerEndpoint"] = {"host": host, "port": port}
        configuration["controllerSecret"] = secret
        atomic_write(daemon_config, json.dumps(configuration, indent=2) + "\n", 0o600)


def apply(
    config: pathlib.Path,
    backup: pathlib.Path,
    secret_file: Optional[pathlib.Path] = None,
    controller_metadata: Optional[pathlib.Path] = None,
    daemon_config: Optional[pathlib.Path] = None,
) -> None:
    if not backup.exists():
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(config, backup)
    lines = config.read_text(encoding="utf-8").splitlines(keepends=True)
    host, port = normalize_controller(top_level_scalar(lines, "external-controller"))
    secret = resolve_secret(top_level_scalar(lines, "secret"), secret_file)
    start, end = dns_block(lines)
    block = lines[start + 1 : end]
    for key, value in MANAGED_SCALARS.items():
        block = replace_direct_scalar(block, key, value)
    for key, value in MANAGED_LISTS.items():
        block = replace_direct_list(block, key, value)
    lines = lines[: start + 1] + block + lines[end:]
    lines = replace_top_level_scalar(lines, "external-controller", f"{host}:{port}")
    lines = replace_top_level_scalar(lines, "secret", json.dumps(secret))
    if direct_scalar(lines, "tun", "enable") != "true":
        raise ValueError("managed system DNS requires tun.enable: true")
    config.write_text("".join(lines), encoding="utf-8")
    persist_controller(host, port, secret, secret_file, controller_metadata, daemon_config)


def restore(config: pathlib.Path, backup: pathlib.Path) -> None:
    if not backup.exists():
        raise ValueError(f"backup does not exist: {backup}")
    shutil.copy2(backup, config)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--backup", required=True, type=pathlib.Path)
    parser.add_argument("--secret-file", type=pathlib.Path)
    parser.add_argument("--controller-metadata", type=pathlib.Path)
    parser.add_argument("--daemon-config", type=pathlib.Path)
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    try:
        if args.restore:
            restore(args.config, args.backup)
        else:
            apply(
                args.config,
                args.backup,
                args.secret_file,
                args.controller_metadata,
                args.daemon_config,
            )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"configure_mihomo.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
