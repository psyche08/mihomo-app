#!/usr/bin/env python3
"""Bounded live AI App Proxy check; logs only categories, status and counters."""
import collections
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time

HOST = '/Applications/MihomoDNSProbe.app/Contents/MacOS/MihomoDNSProbe'
CTL = '/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl'
NODE = '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node'
PROFILE = 'ai-app-proxy-check.yaml'
report = {'tests': {}, 'counters': {}, 'routes': [], 'strict_dns_verified': False}
output = pathlib.Path(sys.argv[1])

def ctl(*args):
    r = subprocess.run([CTL, *args], capture_output=True, text=True, timeout=35)
    if r.returncode: raise RuntimeError('typed_action_failed')
    return json.loads(r.stdout) if r.stdout.lstrip().startswith(('{', '[')) else None

def state():
    return subprocess.check_output([HOST, '--app-status'], text=True, timeout=15)

# Fresh requests from an actual selected, vendor-signed helper, with no messages,
# prompts, auth tokens or account data sent to any AI service.
HTTPS = """
const https=require('https');let done=false;
function finish(ok){if(done)return;done=true;console.log(JSON.stringify({ok}));process.exit(ok?0:1)}
const req=https.get('https://example.com/', {agent:false},r=>{r.resume();r.on('end',()=>finish(r.statusCode===200))});
req.on('error',()=>finish(false));setTimeout(()=>finish(false),12000);
"""
STUN = """
const dgram=require('dgram'),crypto=require('crypto');const s=dgram.createSocket('udp4');
const id=crypto.randomBytes(12),p=Buffer.alloc(20);p.writeUInt16BE(1,0);p.writeUInt32BE(0x2112a442,4);id.copy(p,8);let done=false;
function finish(ok){if(done)return;done=true;s.close();console.log(JSON.stringify({ok}));process.exit(ok?0:1)}
s.on('error',()=>finish(false));s.on('message',b=>finish(b.length>=20&&b.readUInt16BE(0)===0x101&&b.subarray(8,20).equals(id)));
s.send(p,19302,'stun.l.google.com',e=>{if(e)finish(false)});setTimeout(()=>finish(false),12000);
"""
LOOPBACK = """
const http=require('http');const s=http.createServer((q,r)=>r.end('ok'));let done=false;
function finish(ok){if(done)return;done=true;s.close();console.log(JSON.stringify({ok}));process.exit(ok?0:1)}
s.on('error',()=>finish(false));s.listen(0,'127.0.0.1',()=>{
 const r=http.get({hostname:'127.0.0.1',port:s.address().port,path:'/',agent:false},r=>{r.resume();r.on('end',()=>finish(r.statusCode===200))});r.on('error',()=>finish(false));});
setTimeout(()=>finish(false),8000);
"""
def node(code):
    try:
        env = {k:v for k,v in os.environ.items() if k.lower() not in ['http_proxy','https_proxy','all_proxy','no_proxy','node_options']}
        env['NODE_USE_ENV_PROXY'] = '0'
        r = subprocess.run([NODE, '-e', code], capture_output=True, text=True, timeout=16, env=env)
        return {'ok': json.loads(r.stdout).get('ok') is True, 'exit': r.returncode}
    except (subprocess.TimeoutExpired, ValueError):
        return {'ok': False, 'timeout_or_invalid_result': True}

before = ctl('status', '--json')
original = before.get('active_profile')
assert original == 'sheng.yaml' and before.get('health', {}).get('network_consistent') is True
snapshot = ctl('rpc', 'snapshot')
assert snapshot.get('configs', {}).get('mixed-port') == 7897
assert snapshot.get('configs', {}).get('mode', '').lower() == 'rule'
assert 'app_probe_enabled=false' in state()
assert 'dns_probe_enabled=false' in subprocess.check_output([HOST, '--status'], text=True, timeout=15)
source = pathlib.Path.home()/'Library/Application Support/MihomoBox/profiles'/original
raw = source.read_text()
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
assert len(re.findall(r'^rules:\s*$', raw, re.M)) == 1
inventory = json.loads(subprocess.check_output([HOST, '--app-ai-inventory'], timeout=90))
report['targets'] = dict(collections.Counter(t['category'] for t in inventory))
logger = subprocess.Popen(['/usr/bin/log','stream','--style','compact','--level','info','--predicate',
                           'subsystem == "dev.linsheng.mihomo-dns-probe" AND category == "app-proxy"'],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def logs():
    for line in logger.stdout:
        if 'app_probe_started' in line: report['started'] = True
        match = re.search(r'app_counter ([a-z_]+)=(\d+)', line)
        if match: report['counters'][match[1]] = int(match[2])
threading.Thread(target=logs, daemon=True).start()
observing = True
observe_positive = True
def observe():
    while observing:
        try:
            connections = ctl('rpc','connections').get('connections', [])
            if observe_positive:
                for c in connections:
                    if c.get('metadata', {}).get('process') != 'MihomoDNSProbeExtension': continue
                    row = {'proxy': 'Proxy' in c.get('chains', []), 'direct': 'DIRECT' in c.get('chains', []),
                           'extension_rule': c.get('rule') == 'ProcessName' and c.get('rulePayload') == 'MihomoDNSProbeExtension'}
                    if row not in report['routes']: report['routes'].append(row)
        except Exception: pass
        time.sleep(.25)
threading.Thread(target=observe, daemon=True).start()
watchdog_code = """
import subprocess,json,time
h,c,p,original=%r,%r,%r,%r
time.sleep(270)
try:
 subprocess.run([h,'--app-disable'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=25)
 d=json.loads(subprocess.check_output([c,'status','--json'],timeout=30))
 if d.get('active_profile')==p: subprocess.run([c,'profile','switch',original],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=35)
except Exception: pass
""" % (HOST, CTL, PROFILE, original)
watchdog = subprocess.Popen([sys.executable,'-c',watchdog_code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
session = None
try:
    with tempfile.TemporaryDirectory(prefix='mihomo-ai-check-') as directory:
        target = pathlib.Path(directory)/PROFILE
        def apply(policy):
            text = re.sub(r'^(rules:\s*)$',lambda m: m[1]+'\n  - PROCESS-NAME,MihomoDNSProbeExtension,'+policy,
                          raw,count=1,flags=re.M)
            fd = os.open(target, os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
            with os.fdopen(fd,'w') as stream: stream.write(text)
            ctl('profile','import',str(target),'--activate')
            first = ctl('rpc','rules')['rules'][0]
            assert first.get('payload') == 'MihomoDNSProbeExtension' and first.get('proxy') == policy
        apply('Proxy')
        session = subprocess.Popen([HOST,'--app-ai-session'] + (['--rules',sys.argv[3]] if len(sys.argv)>3 and sys.argv[2]=='--rules' else []),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        def host_messages():
            allowed = ['app_ai_target_discovery_failed','app_ambiguous_configuration','app_save_failed','app_readback_failed','app_start_failed','app_probe_disabled','app_requires_source_application_routing','app_already_enabled','disable_dns_probe_before_app_probe']
            for line in session.stdout:
                line = line.strip()
                if line in allowed or line.startswith(('app_probe_start_requested;', 'app_readback_rules_actual=', 'app_save_error_code=')): report.setdefault('host_messages',[]).append(line)
        threading.Thread(target=host_messages,daemon=True).start()
        deadline = time.monotonic()+75
        while time.monotonic()<deadline:
            if 'status=3;' in state(): break
            if session.poll() is not None: raise RuntimeError('host_exited')
            time.sleep(1)
        assert 'status=3;' in state(), 'not_connected'
        print('ai_app_proxy_connected',flush=True)
        report['tests']['selected_loopback'] = node(LOOPBACK)
        report['tests']['selected_https'] = node(HTTPS)
        report['tests']['selected_udp_stun'] = node(STUN)
        # Read-only CLI requests; output is discarded to avoid recording task or account data.
        try:
            r = subprocess.run(['/opt/homebrew/bin/codex','cloud','list','--limit','1','--json'],
                               stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
            report['tests']['codex_read_only_request'] = {'exit':r.returncode}
        except subprocess.TimeoutExpired: report['tests']['codex_read_only_request'] = {'timeout':True}
        try:
            r = subprocess.run(['/opt/homebrew/bin/claude','auth','status'],
                               stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
            report['tests']['claude_auth_status'] = {'exit':r.returncode,'network_not_guaranteed':True}
        except subprocess.TimeoutExpired: report['tests']['claude_auth_status'] = {'timeout':True}
        subprocess.run(['/usr/bin/open','-g','-a','/Applications/Claude.app'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        time.sleep(8)
        observe_positive = False
        apply('REJECT')
        report['tests']['selected_reject'] = node(HTTPS)
        report['connected_during_reject'] = 'status=3;' in state()
        apply('Proxy')
        report['tests']['selected_recovered'] = node(HTTPS)
except Exception as error:
    report['error'] = type(error).__name__
    if str(error) in ['host_exited','typed_action_failed','not_connected']: report['reason'] = str(error)
finally:
    observing = False
    try:
        r = subprocess.run([HOST,'--app-disable'],capture_output=True,text=True,timeout=25)
        report['disabled'] = r.returncode == 0 and 'app_probe_disabled' in r.stdout
        if session and session.poll() is None: session.terminate();session.wait(timeout=5)
        ctl('profile','switch',original)
        after = ctl('status','--json');doh=ctl('local-doh','status')
        report['restored'] = (report['disabled'] and after.get('active_profile') == original
                              and after.get('health',{}).get('network_consistent') is True
                              and doh.get('runtime_healthy') is True
                              and hashlib.sha256(source.read_bytes()).hexdigest() == source_hash)
        if report['restored']: watchdog.terminate();watchdog.wait(timeout=5)
    finally:
        logger.terminate(); logger.wait(timeout=5)
        report['tcp_verified'] = (report['tests'].get('selected_https',{}).get('ok') is True
            and report['tests'].get('selected_reject',{}).get('ok') is False
            and report['tests'].get('selected_recovered',{}).get('ok') is True
            and report.get('connected_during_reject') is True
            and report['counters'].get('hostname_tcp_chatgpt',0)>0
            and bool(report['routes']) and all(x['proxy'] and not x['direct'] and x['extension_rule'] for x in report['routes']))
        output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report.get(k) for k in ['tcp_verified','restored','targets','tests','counters','error','reason','host_messages']}))
if not report.get('tcp_verified') or not report.get('restored') or 'error' in report: raise SystemExit(1)
