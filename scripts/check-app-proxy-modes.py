#!/usr/bin/env python3
"""Isolated pinned-core test: loopback fixtures only, no TUN or system changes."""
import json
import pathlib
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.request


class Fixture(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        reader = self.request.makefile('rb')
        first = reader.readline()
        while reader.readline() not in (b'\r\n', b'\n', b''):
            pass
        if first.startswith(b'CONNECT '):
            self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            while reader.readline() not in (b'\r\n', b'\n', b''):
                pass
        body = self.server.label.encode()
        self.request.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: '
                            + str(len(body)).encode() + b'\r\n\r\n' + body)


def fixture(label):
    server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    server.label = label
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


binary, config = sys.argv[1:]
path = pathlib.Path(config)
servers = [fixture('app-node'), fixture('global-node'), fixture('direct')]
controller, inbound = free_port(), free_port()
source = path.read_text().replace('port: 12345', 'port: ' + str(servers[0].server_address[1]))
source = source.replace('port: 12346', 'port: ' + str(servers[1].server_address[1]))
source = source.replace('127.0.0.1:12347', '127.0.0.1:' + str(controller))
source = source.replace('port: 17999', 'port: ' + str(inbound))
path.write_text(source)
core = subprocess.Popen([binary, '-d', str(path.parent), '-f', str(path)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(route, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request('http://127.0.0.1:' + str(controller) + route,
                                     data=data, method=method, headers={'Content-Type': 'application/json'})
    with opener.open(request, timeout=3) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


try:
    deadline = time.monotonic() + 12
    while True:
        try:
            api('/version')
            break
        except OSError:
            assert core.poll() is None and time.monotonic() < deadline, 'Fixture core did not start'
            time.sleep(.05)
    api('/proxies/GLOBAL', 'PUT', {'name': 'global-node'})
    results = {}
    for mode, expected in [('rule', 'app-node'), ('global', 'global-node'), ('direct', 'direct'), ('rule', 'app-node')]:
        api('/configs', 'PATCH', {'mode': mode})
        result = subprocess.run(['/usr/bin/curl', '--noproxy', '', '--proxy', 'http://127.0.0.1:' + str(inbound),
                                 '--max-time', '5', '-fsS', 'http://127.0.0.1:' + str(servers[2].server_address[1])],
                                capture_output=True, text=True, timeout=8)
        assert result.returncode == 0 and result.stdout == expected, (mode, result.returncode, result.stdout)
        results[mode] = result.stdout
    print(json.dumps(results))
finally:
    core.terminate()
    try:
        core.wait(timeout=5)
    except subprocess.TimeoutExpired:
        core.kill()
        core.wait()
    for server in servers:
        server.shutdown()
        server.server_close()
