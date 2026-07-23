#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="/private/tmp/mihomo-agent-e2e"
BINARY="$ROOT/.build/debug/mihomo-agent"
FAKE_PID=""
PROXY_PID=""

cleanup() {
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" >/dev/null 2>&1 || true
  [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" >/dev/null 2>&1 || true
  [[ -n "$PROXY_PID" ]] && wait "$PROXY_PID" >/dev/null 2>&1 || true
  [[ -n "$FAKE_PID" ]] && wait "$FAKE_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP"

python3 -c '
import socket, struct, threading
def response(query, truncated):
    value = bytearray(query)
    if len(value) >= 4:
        value[2] |= 0x80
        value[3] |= 0x80
        value[2] = (value[2] | 0x02) if truncated else (value[2] & ~0x02)
    return bytes(value)
def udp_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 15353))
    while True:
        query, peer = sock.recvfrom(65535)
        sock.sendto(response(query, True), peer)
threading.Thread(target=udp_server, daemon=True).start()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 15353))
server.listen()
while True:
    connection, _ = server.accept()
    with connection:
        length = struct.unpack("!H", connection.recv(2))[0]
        query = b""
        while len(query) < length:
            query += connection.recv(length - len(query))
        answer = response(query, False)
        connection.sendall(struct.pack("!H", len(answer)) + answer)
' &
FAKE_PID=$!

"$BINARY" --config "$ROOT/Tests/Fixtures/e2e-config.json" >"$TMP/service.log" 2>&1 &
PROXY_PID=$!

for _ in {1..50}; do
  if dig @127.0.0.1 -p 15355 test.invalid A +time=1 +tries=1 \
      >"$TMP/udp-response.txt" 2>&1; then
    break
  fi
  sleep 0.1
done

grep -q 'status: NOERROR' "$TMP/udp-response.txt"
dig @127.0.0.1 -p 15355 test.invalid A +tcp +time=1 +tries=1 \
  >"$TMP/tcp-response.txt" 2>&1
grep -q 'status: NOERROR' "$TMP/tcp-response.txt"

PIDS=()
for index in {1..32}; do
  dig @127.0.0.1 -p 15355 "parallel-${index}.invalid" A +time=2 +tries=1 \
    >"$TMP/parallel-${index}.txt" 2>&1 &
  PIDS+=("$!")
done
for pid in "${PIDS[@]}"; do
  wait "$pid"
done
for index in {1..32}; do
  grep -q 'status: NOERROR' "$TMP/parallel-${index}.txt"
done

if grep -Eq '(test|parallel-[0-9]+)\.invalid' "$TMP/service.log"; then
  echo "sensitive DNS content leaked to service log" >&2
  exit 1
fi

echo "mihomo-agent E2E passed (async parallel UDP/TCP DNS -> Mihomo UDP/TCP fallback)"
