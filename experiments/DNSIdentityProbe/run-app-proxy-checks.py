#!/usr/bin/env python3
"""Signed, bounded App Proxy experiment. No cache flush and no packet logging."""
import concurrent.futures
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

app = pathlib.Path("/Applications/MihomoDNSProbe.app")
host = app / "Contents/MacOS/MihomoDNSProbe"
clients = pathlib.Path("/Applications") if "--top-level-clients" in sys.argv[2:] else app / "Contents/Resources/Clients"
cli = "/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl"
output = pathlib.Path(sys.argv[1])
launch_services = "--launch-services" in sys.argv[2:]
selected, control = "MihomoDNSSelected", "MihomoDNSControl"
test_deadline = None


def ctl(*args):
    r = subprocess.run([cli, *args], capture_output=True, text=True, timeout=35)
    if r.returncode:
        raise RuntimeError("typed_action_failed")
    return json.loads(r.stdout) if r.stdout.lstrip().startswith(("{", "[")) else None


def run(client, mode, case="a"):
    try:
        timeout = 20 if test_deadline is None else min(20, test_deadline - time.monotonic())
        if timeout <= 0:
            raise subprocess.TimeoutExpired("bounded_test_client", 0)
        client_app = clients / (client + ".app")
        if launch_services:
            with tempfile.TemporaryDirectory(prefix="app-proxy-client-") as directory:
                result_file = pathlib.Path(directory) / "result.json"
                r = subprocess.run(["/usr/bin/open", "-n", "-W", "-g", "-a", str(client_app),
                                    "--stdout", str(result_file), "--stderr", "/dev/null", "--args", mode, case],
                                   capture_output=True, text=True, timeout=timeout)
                d = json.loads(result_file.read_text())
                exit_code = 0 if r.returncode == 0 and d.get("ok") else 1
        else:
            r = subprocess.run([str(client_app / "Contents/MacOS" / client), mode, case],
                               capture_output=True, text=True, timeout=timeout)
            d = json.loads(r.stdout)
            exit_code = r.returncode
        return {"client": "selected" if client == selected else "control", "mode": mode, "case": case,
                "exit": exit_code, "result": {k: d[k] for k in [
                    "ok", "fake_ip", "answer_count", "rcode", "status", "stage"] if k in d}}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {"client": "selected" if client == selected else "control", "mode": mode,
                "case": case, "failed": "timeout_or_invalid_result"}


subprocess.run([str(pathlib.Path(__file__).with_name("audit-cloud-app.sh"))], check=True,
               env=dict(os.environ, CI_DEVELOPER_ID_SIGNED_APP_PATH=str(app)))
if clients == pathlib.Path("/Applications"):
    for client in [selected, control]:
        copied = clients / (client + ".app")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        executable = pathlib.Path("Contents/MacOS") / client
        original = app / "Contents/Resources/Clients" / (client + ".app")
        assert hashlib.sha256((copied / executable).read_bytes()).digest() == hashlib.sha256(
            (original / executable).read_bytes()).digest(), "standalone_client_build_mismatch"
before = ctl("status", "--json")
assert before.get("active_profile") == "sheng.yaml" and before.get("health", {}).get("network_consistent") is True
assert "dns_probe_enabled=false" in subprocess.check_output([str(host), "--status"], text=True, timeout=15)
assert "app_probe_enabled=false" in subprocess.check_output([str(host), "--app-status"], text=True, timeout=15)
source = pathlib.Path.home() / "Library/Application Support/MihomoBox/profiles/sheng.yaml"
raw = source.read_text()
assert len(re.findall(r"^rules:\s*$", raw, re.M)) == 1
report = {"strict_dns_verified": False, "cache_flushed": False, "tests": [], "routes": [],
          "counters": {}, "provider_started": False, "rollback": False,
          "launch_services": launch_services, "top_level_clients": "--top-level-clients" in sys.argv[2:]}
session = None
watchdog = None
logger = subprocess.Popen(["/usr/bin/log", "stream", "--style", "compact", "--level", "info",
                           "--predicate", 'subsystem == "dev.linsheng.mihomo-dns-probe" AND category == "app-proxy"'],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def read_log():
    for line in logger.stdout:
        if "app_probe_started" in line:
            report["provider_started"] = True
        m = re.search(r"app_counter ([a-z_]+)=(\d+)", line)
        if m:
            report["counters"][m[1]] = int(m[2])
threading.Thread(target=read_log, daemon=True).start()
observing = True
def observe():
    seen = set()
    while observing:
        try:
            for c in ctl("rpc", "connections").get("connections", []):
                m = c.get("metadata", {})
                if m.get("process") != "MihomoDNSProbeExtension":
                    continue
                record = {"extension_process": True, "proxy": "Proxy" in c.get("chains", []),
                          "direct": "DIRECT" in c.get("chains", []),
                          "process_rule": c.get("rule") == "ProcessName",
                          "rule_matches_extension": c.get("rulePayload") == "MihomoDNSProbeExtension"}
                key = json.dumps(record, sort_keys=True)
                if key not in seen:
                    seen.add(key); report["routes"].append(record)
        except Exception:
            pass
        time.sleep(0.2)
observer = threading.Thread(target=observe, daemon=True)
try:
    with tempfile.TemporaryDirectory(prefix="mihomo-app-proxy-") as folder:
        target = pathlib.Path(folder) / "app-proxy-cache-probe.yaml"
        watchdog_code = """
import subprocess,json,time
time.sleep(270)
c='/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl'
h='/Applications/MihomoDNSProbe.app/Contents/MacOS/MihomoDNSProbe'
try:
 subprocess.run([h,'--app-disable'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=25)
 d=json.loads(subprocess.check_output([c,'status','--json'],timeout=30))
 if d.get('active_profile')=='app-proxy-cache-probe.yaml':
  subprocess.run([c,'profile','switch','sheng.yaml'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=35)
except Exception: pass
"""
        watchdog = subprocess.Popen([sys.executable, "-c", watchdog_code],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        def apply(policy):
            content = re.sub(r"^(rules:\s*)$", lambda m: m[1] +
                             "\n  - PROCESS-NAME,MihomoDNSProbeExtension," + policy +
                             "\n  - PROCESS-NAME,MihomoDNSControl,DIRECT", raw, count=1, flags=re.M)
            fd = os.open(target, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(content)
            ctl("profile", "import", str(target), "--activate")
            rules = ctl("rpc", "rules").get("rules", [])
            assert rules[0].get("type") == "ProcessName" and rules[0].get("payload") == "MihomoDNSProbeExtension"
            assert rules[0].get("proxy") == policy
        apply("Proxy")
        report["prewarmed"] = [run(control, "system", "b"), run(selected, "system", "a")]
        test_deadline = time.monotonic() + 210
        session = subprocess.Popen([str(host), "--app-session"], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
        def read_host():
            # Fixed milestone only; do not persist arbitrary errors or settings.
            for line in session.stdout:
                if line.startswith("app_probe_start_requested;"):
                    report["start_requested"] = True
        threading.Thread(target=read_host, daemon=True).start()
        print("waiting_for_app_proxy_start", flush=True)
        ready_deadline = time.monotonic() + 90
        while time.monotonic() < ready_deadline:
            if report["provider_started"]:
                break
            if session.poll() is not None:
                raise RuntimeError("app_host_exited_before_start")
            time.sleep(0.5)
        if not report["provider_started"]:
            raise TimeoutError("provider_start_not_observed")
        observer.start()
        print("app_proxy_started", flush=True)
        budget = test_deadline
        for mode in ["system", "udp", "tcp", "connect", "https"]:
            for client, case in [(selected, "a"), (control, "a"), (control, "b"), (selected, "b")]:
                if time.monotonic() >= budget:
                    raise TimeoutError("case_budget")
                report["tests"].append(run(client, mode, case))
            print(json.dumps({"completed_mode": mode}), flush=True)
        for mode in ["helper", "helper-connect", "helper-https"]:
            report["tests"].append(run(selected, mode))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            report["tests"].extend(pool.map(lambda client: run(client, "system"), [selected, control]))
        if time.monotonic() + 45 >= budget:
            raise TimeoutError("insufficient_failure_test_budget")
        report["connected_before_failure"] = "status=3;" in subprocess.check_output(
            [str(host), "--app-status"], text=True, timeout=15)
        apply("REJECT")
        report["proxy_failure"] = [run(selected, "https"), run(control, "https")]
        report["connected_after_failure"] = "status=3;" in subprocess.check_output(
            [str(host), "--app-status"], text=True, timeout=15)
        report["proxy_failure_blocked"] = (
            report["proxy_failure"][0].get("result", {}).get("ok") is False
            and report["proxy_failure"][1].get("result", {}).get("status") == 200
            and report["connected_before_failure"] and report["connected_after_failure"])
except Exception as error:
    report["error"] = type(error).__name__
finally:
    observing = False
    try:
        disabled = subprocess.run([str(host), "--app-disable"], capture_output=True, text=True, timeout=25)
        report["app_disabled"] = disabled.returncode == 0 and "app_probe_disabled" in disabled.stdout
        if session and session.poll() is None:
            session.terminate(); session.wait(timeout=5)
        ctl("profile", "switch", "sheng.yaml")
        after = ctl("status", "--json")
        doh = ctl("local-doh", "status")
        report["rollback"] = (report["app_disabled"] and after.get("active_profile") == "sheng.yaml"
                              and after.get("health", {}).get("network_consistent") is True
                              and doh.get("runtime_healthy") is True)
        if watchdog and report["rollback"]:
            watchdog.terminate(); watchdog.wait(timeout=5)
    finally:
        logger.terminate()
        try:
            logger.wait(timeout=5)
        except subprocess.TimeoutExpired:
            logger.kill()
        report["basic_cases_passed"] = len(report["tests"]) == 25 and all(
            t.get("exit") == 0 and t.get("result", {}).get("ok") is True
            and t.get("result", {}).get("rcode", 0) == 0 for t in report["tests"])
        report["proxy_route_observed"] = bool(report["routes"]) and all(
            r["proxy"] and not r["direct"] and r["process_rule"] and r["rule_matches_extension"]
            for r in report["routes"])
        dns_tests = [t for t in report["tests"] if t["mode"] in ["system", "udp", "tcp"]]
        report["controlled_dns_separation_observed"] = len(dns_tests) == 14 and all(
            t.get("exit") == 0 and t.get("result", {}).get("ok") is True
            and t.get("result", {}).get("fake_ip") is (t["client"] == "control")
            and t.get("result", {}).get("rcode", 0) == 0 for t in dns_tests)
        output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"cases": len(report["tests"]), "provider_started": report["provider_started"],
                  "rollback": report["rollback"], "strict_dns_verified": False}))
if (not report["rollback"] or "error" in report or not report.get("proxy_failure_blocked")
        or not report["counters"].get("hostname_tcp_selected")
        or not report["basic_cases_passed"] or not report["proxy_route_observed"]
        or not report["controlled_dns_separation_observed"]):
    raise SystemExit(1)
