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
import socket
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
        atomic_write(controller_metadata, json.dumps(metadata, indent=2) + "\n", 0o600)
    if daemon_config:
        configuration = json.loads(daemon_config.read_text(encoding="utf-8"))
        configuration["controllerEndpoint"] = {"host": host, "port": port}
        configuration["controllerSecret"] = secret
        atomic_write(daemon_config, json.dumps(configuration, indent=2) + "\n", 0o600)


def proxy_server_hosts(lines: list[str]) -> list[str]:
    """Server addresses under ``proxies:``, in order, without duplicates."""
    hosts: list[str] = []
    in_proxies = False
    for line in lines:
        stripped = line.strip()
        if line[:1] not in (" ", "\t", "") and stripped.endswith(":"):
            in_proxies = stripped == "proxies:"
            continue
        if not in_proxies or not stripped.startswith("server:"):
            continue
        value = parse_yaml_scalar(stripped[len("server:") :])
        if value and value not in hosts:
            hosts.append(value)
    return hosts


ESCAPE_RESOLVER = ("127.0.0.1", 1054)


def query_escape_resolver(host: str, timeout: float = 2.0) -> list[str]:
    """Resolve through the agent's original-DNS escape.

    The system resolver is the wrong tool here. By the time a profile is
    reloaded the agent usually owns system DNS, so ``getaddrinfo`` answers from
    Fake-IP — and writing a Fake-IP address into the tunnel's exclusion list
    would be worse than writing nothing, since it excludes an address the
    kernel never dials while leaving the real one captured.
    """
    query = bytearray([0x4D, 0x48, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    for label in host.split("."):
        encoded = label.encode("idna") if label.isascii() is False else label.encode()
        if not 1 <= len(encoded) <= 63:
            return []
        query.append(len(encoded))
        query.extend(encoded)
    query.extend([0x00, 0x00, 0x01, 0x00, 0x01])

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(timeout)
        sock.sendto(bytes(query), ESCAPE_RESOLVER)
        response = sock.recv(4096)
    except OSError:
        return []
    finally:
        sock.close()

    if len(response) < 12:
        return []
    questions = int.from_bytes(response[4:6], "big")
    answers = int.from_bytes(response[6:8], "big")
    offset = 12

    def skip_name(start: int) -> Optional[int]:
        index = start
        while index < len(response):
            length = response[index]
            if length == 0:
                return index + 1
            if length & 0xC0 == 0xC0:
                return index + 2
            index += 1 + length
        return None

    for _ in range(questions):
        nxt = skip_name(offset)
        if nxt is None:
            return []
        offset = nxt + 4

    found: list[str] = []
    for _ in range(answers):
        nxt = skip_name(offset)
        if nxt is None or nxt + 10 > len(response):
            break
        offset = nxt
        rtype = int.from_bytes(response[offset : offset + 2], "big")
        length = int.from_bytes(response[offset + 8 : offset + 10], "big")
        offset += 10
        if offset + length > len(response):
            break
        if rtype == 1 and length == 4:
            found.append(".".join(str(byte) for byte in response[offset : offset + 4]))
        offset += length
    return found


def resolve_addresses(hosts: list[str], excluded_prefix: Optional[str]) -> list[str]:
    """Real addresses for each host, skipping unresolvable and Fake-IP ones."""
    addresses: list[str] = []
    for host in hosts:
        found = query_escape_resolver(host)
        if not found:
            # The escape resolver is not listening yet during a first install,
            # when nothing owns system DNS either, so this is safe there.
            try:
                infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
                found = [info[4][0] for info in infos]
            except OSError:
                continue
        for address in found:
            if excluded_prefix and address.startswith(excluded_prefix):
                continue
            if address not in addresses:
                addresses.append(address)
    return addresses


def fake_ip_prefix(lines: list[str]) -> Optional[str]:
    """Leading octets of the Fake-IP range, for rejecting synthetic answers."""
    value = direct_scalar(lines, "dns", "fake-ip-range") or "198.18.0.1/16"
    address = value.split("/")[0]
    octets = address.split(".")
    if len(octets) != 4:
        return None
    try:
        bits = int(value.split("/")[1]) if "/" in value else 16
    except ValueError:
        bits = 16
    if bits == 8:
        return f"{octets[0]}."
    if bits == 24:
        return f"{octets[0]}.{octets[1]}.{octets[2]}."
    return f"{octets[0]}.{octets[1]}."


def exclude_proxy_servers_from_tunnel(lines: list[str]) -> list[str]:
    """Keep the tunnel from swallowing the kernel's own outbound dials.

    ``auto-route`` installs a default route through the tunnel. The kernel
    still has to reach its proxy server over the physical network, so the
    server's address has to be excluded from that route — otherwise the dial is
    sent into the tunnel it exists to establish, and every proxied connection
    hangs while the machine looks entirely healthy. That fault was observed in
    the field: interface up, DNS answering, direct traffic fine, and only the
    traffic that mattered silently stopped.

    The addresses are resolved here, at load, rather than written into
    ``server:``. Replacing the hostname would break TLS, which uses it for SNI
    and certificate validation, and would pin an address that DDNS-backed
    servers change underneath. Resolving on every load keeps the exclusion
    current instead.
    """
    hosts = proxy_server_hosts(lines)
    if not hosts:
        return lines
    addresses = resolve_addresses(hosts, fake_ip_prefix(lines))
    if not addresses:
        # Better to leave routing untouched than to write an empty exclusion:
        # resolution can fail transiently, and a stale-but-correct list from a
        # previous load is worth more than none.
        return lines
    entries = "".join(f"    - {address}/32\n" for address in addresses)
    return replace_tun_list(lines, "route-exclude-address", entries)


def replace_tun_list(lines: list[str], key: str, entries: str) -> list[str]:
    """Rewrite ``tun.<key>`` with ``entries``, appending the key when absent."""
    try:
        start, end = top_level_block(lines, "tun")
    except ValueError:
        return lines
    block = lines[start + 1 : end]
    first, last = direct_key_range(block, key)
    replacement = [f"  {key}:\n", entries]
    if first is None:
        block = block + replacement
    else:
        block = block[:first] + replacement + block[last:]
    return lines[: start + 1] + block + lines[end:]


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
    # The kernel emits an enormous amount at warning: a week of field logs held
    # 1.82M warning lines against 8.5K errors, which buried the errors and cost
    # continuous disk writes for output nobody reads. Errors are what diagnosis
    # actually uses.
    lines = replace_top_level_scalar(lines, "log-level", "error")
    if direct_scalar(lines, "tun", "enable") != "true":
        raise ValueError("managed system DNS requires tun.enable: true")
    lines = exclude_proxy_servers_from_tunnel(lines)
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
