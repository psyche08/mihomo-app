#!/usr/bin/env python3
"""Run only after signed-bundle verification and ordinary OS activation approval.
Never activate the extension, edit profiles, or print DNS wire data/domains.
"""
import concurrent.futures
import json
import pathlib
import queue
import subprocess
import sys
import threading
import time

app = pathlib.Path('/Applications/MihomoDNSProbe.app')
host = app/'Contents/MacOS/MihomoDNSProbe'
clients = app/'Contents/Resources/Clients'
output = pathlib.Path(sys.argv[1]) if len(sys.argv) == 2 else None
if output is None:
    raise SystemExit('usage: run-live-checks.py RESULT.json')
# This audit is the same mandatory signature/profile check used by Cloud.
import os
env = dict(os.environ, CI_DEVELOPER_ID_SIGNED_APP_PATH=str(app))
subprocess.run([str(pathlib.Path(__file__).with_name('audit-cloud-app.sh'))], env=env, check=True)
state = subprocess.check_output([str(host), '--status'], text=True, timeout=15)
if 'dns_probe_enabled=false' not in state:
    raise SystemExit('Probe already enabled; inspect/disable the prior session before testing')
log_lines, host_lines = [], queue.Queue()
logger = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info', '--predicate', 'subsystem == "dev.linsheng.mihomo-dns-probe"'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def read_log():
    for line in logger.stdout:
        if 'counter ' in line or 'probe_started' in line or 'probe_stopped' in line:
            log_lines.append(line.strip())
            if len(log_lines) > 2000: del log_lines[:1000]
threading.Thread(target=read_log, daemon=True).start()
results = {'strict_dns_verified': False, 'mode': 'observation', 'tests': [], 'rollback': False}
session = None
try:
    session = subprocess.Popen([str(host), '--session'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    def read_host():
        for line in session.stdout: host_lines.put(line.strip())
    threading.Thread(target=read_host, daemon=True).start()
    line = host_lines.get(timeout=20)
    if not line.startswith('dns_probe_enabled;'): raise RuntimeError('DNS manager did not enable the test session')
    deadline = time.monotonic()+15
    while not any('probe_started' in s for s in log_lines) and time.monotonic() < deadline: time.sleep(0.25)
    if not any('probe_started' in s for s in log_lines): raise RuntimeError('No provider-start evidence; stop without claiming a runtime test')
    def run(client, mode, case='a'):
        exe = clients/(client+'.app')/'Contents/MacOS'/client
        try:
            r = subprocess.run([str(exe), mode, case], capture_output=True, text=True, timeout=20)
            return {'client': client, 'mode': mode, 'case': case, 'exit': r.returncode, 'result': json.loads(r.stdout)}
        except (subprocess.TimeoutExpired, ValueError):
            return {'client': client, 'mode': mode, 'case': case, 'failed': 'timeout_or_invalid_result'}
    selected, control = 'MihomoDNSSelected', 'MihomoDNSControl'
    for mode in ['udp', 'tcp', 'system']:
        for client, case in [(selected,'a'),(control,'a'),(control,'b'),(selected,'b')]:
            results['tests'].append(run(client, mode, case))
    results['tests'].append(run(selected, 'helper'))
    for client in [selected, control]: results['tests'].append(run(client, 'https'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results['tests'].extend(pool.map(lambda c: run(c, 'system', 'a'), [selected, control]))
except Exception as error:
    # Only fixed stage text/type; never serialize arbitrary process output.
    results['experiment_error'] = type(error).__name__
finally:
    try:
        r = subprocess.run([str(host), '--disable'], capture_output=True, text=True, timeout=20)
        results['rollback'] = r.returncode == 0 and 'dns_probe_disabled' in r.stdout
    finally:
        if session and session.poll() is None: session.terminate()
        logger.terminate()
        try: logger.wait(timeout=5)
        except subprocess.TimeoutExpired: logger.kill()
        results['counters'] = log_lines
        output.write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps({'cases': len(results['tests']), 'rollback': results['rollback'], 'strict_dns_verified': False}))
if not results['rollback'] or 'experiment_error' in results: raise SystemExit(1)
