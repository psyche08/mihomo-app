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
        self.server.requests += 1
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
    server.requests = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


binary, config = sys.argv[1:]
path = pathlib.Path(config)
servers = [fixture('app-node'), fixture('global-node'), fixture('direct')]
controller, inbound, second_inbound, ordinary_inbound = [free_port() for _ in range(4)]
source = path.read_text().replace('port: 12345', 'port: ' + str(servers[0].server_address[1]))
source = source.replace('port: 12346', 'port: ' + str(servers[1].server_address[1]))
source = source.replace('127.0.0.1:12347', '127.0.0.1:' + str(controller))
source = source.replace('port: 17999', 'port: ' + str(inbound))
source = source.replace('port: 17998', 'port: ' + str(second_inbound))
source = source.replace('mixed-port: 12348', 'mixed-port: ' + str(ordinary_inbound))
domains = ['direct.test', 'named-direct.test', 'reject.test', 'drop.test', 'pass.test', 'provider-direct.test',
           'provider-proxy.test', 'proxy.sub.test', 'direct.sub.test', 'reject.sub.test',
           'logic.test', 'regex123.test', 'proxy.test', 'unmatched.test']
source += '\nhosts:\n' + ''.join('  ' + domain + ': 127.0.0.1\n' for domain in domains)
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
    results = []

    def check(mode, domain, expected, listener=inbound):
        before = [server.requests for server in servers]
        result = subprocess.run(['/usr/bin/curl', '--noproxy', '', '--proxy', 'http://127.0.0.1:' + str(listener),
                                 '--max-time', '3', '-fsS', 'http://' + domain + ':' + str(servers[2].server_address[1])],
                                capture_output=True, text=True, timeout=6)
        if expected == 'reject':
            assert result.returncode != 0 and [server.requests for server in servers] == before, (mode, domain, result.stdout)
        else:
            assert result.returncode == 0 and result.stdout == expected, (mode, domain, result.returncode, result.stdout)
        results.append({'mode': mode, 'domain': domain, 'expected': expected, 'passed': True})

    for mode in ['rule', 'global', 'direct', 'rule']:
        api('/configs', 'PATCH', {'mode': mode})
        for domain in domains:
            if mode == 'global': expected = 'global-node'
            elif mode == 'direct': expected = 'direct'
            elif domain in ['reject.test', 'drop.test', 'reject.sub.test']: expected = 'reject'
            elif domain in ['direct.test', 'named-direct.test', 'pass.test', 'provider-direct.test', 'direct.sub.test', 'unmatched.test']: expected = 'direct'
            else: expected = 'app-node'
            check(mode, domain, expected)
        if mode == 'rule':
            check(mode, 'proxy.test', 'global-node', second_inbound)
            check(mode, 'direct.test', 'direct', second_inbound)
            check(mode, 'proxy.test', 'global-node', ordinary_inbound)
            check(mode, 'reject.test', 'reject', ordinary_inbound)
    print(json.dumps({'passed': True, 'cases': len(results), 'coverage':
                     ['two independent apps', 'original listener', 'direct', 'reject', 'reject-drop',
                      'pass', 'rule providers', 'nested sub-rules', 'logic', 'regex with commas',
                      'unmatched direct', 'global', 'direct mode', 'live mode changes']}))
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
