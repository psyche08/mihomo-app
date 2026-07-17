#!/usr/bin/env python3
"""Apply or restore the minimal Mihomo DNS listener/upstream changes."""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import sys

MANAGED = {
    "listen": "127.0.0.1:1053",
    "nameserver": "udp://127.0.0.1:1054",
    "direct-nameserver": "udp://127.0.0.1:1054",
    "proxy-server-nameserver": "udp://127.0.0.1:1054",
}

MANAGED_TOP_LEVEL = {
    "external-controller": "127.0.0.1:9090",
    "secret": "''",
}


def dns_block(lines: list[str]) -> tuple[int, int]:
    start = next((index for index, line in enumerate(lines) if re.match(r"^dns:\s*(?:#.*)?$", line)), None)
    if start is None:
        raise ValueError("top-level dns: block not found")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.startswith((" ", "\t", "#")):
            end = index
            break
    return start, end


def replace_direct_key(block: list[str], key: str, value: str) -> list[str]:
    pattern = re.compile(rf"^  {re.escape(key)}\s*:")
    start = next((index for index, line in enumerate(block) if pattern.match(line)), None)
    replacement = [f"  {key}:\n", f"    - {value}\n"] if key != "listen" else [f"  {key}: {value}\n"]
    if start is None:
        return block + replacement
    end = start + 1
    while end < len(block):
        line = block[end]
        if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) <= 2:
            break
        end += 1
    return block[:start] + replacement + block[end:]


def replace_top_level_scalar(lines: list[str], key: str, value: str) -> list[str]:
    pattern = re.compile(rf"^{re.escape(key)}\s*:")
    index = next((i for i, line in enumerate(lines) if pattern.match(line)), None)
    replacement = f"{key}: {value}\n"
    if index is None:
        return [replacement, *lines]
    return [*lines[:index], replacement, *lines[index + 1 :]]


def apply(config: pathlib.Path, backup: pathlib.Path) -> None:
    if not backup.exists():
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(config, backup)
    lines = config.read_text(encoding="utf-8").splitlines(keepends=True)
    start, end = dns_block(lines)
    block = lines[start + 1 : end]
    for key, value in MANAGED.items():
        block = replace_direct_key(block, key, value)
    lines = lines[: start + 1] + block + lines[end:]
    for key, value in MANAGED_TOP_LEVEL.items():
        lines = replace_top_level_scalar(lines, key, value)
    config.write_text("".join(lines), encoding="utf-8")


def restore(config: pathlib.Path, backup: pathlib.Path) -> None:
    if not backup.exists():
        raise ValueError(f"backup does not exist: {backup}")
    shutil.copy2(backup, config)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--backup", required=True, type=pathlib.Path)
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    try:
        if args.restore:
            restore(args.config, args.backup)
        else:
            apply(args.config, args.backup)
    except (OSError, ValueError) as error:
        print(f"configure_mihomo.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
