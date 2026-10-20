#!/usr/bin/env python3
"""Bounded unified-Fake-IP experiment using only the existing typed daemon CLI.

No cache flush, second core, packet log, or original-profile modification.
Source profiles stay in a mode-0700 temporary folder; output is a whitelist.
"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

CLI = "/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl"
HOST = "/Applications/MihomoDNSProbe.app/Contents/MacOS/MihomoDNSProbe"
output = pathlib.Path(sys.argv[1])
clients = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else pathlib.Path(
    "/Applications/MihomoDNSProbe.app/Contents/Resources/Clients")
launch_services = "--launch-services" in sys.argv[2:]
selected, control = "MihomoDNSSelected", "MihomoDNSControl"


def ctl(*args):
    result = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=35)
    if result.returncode:
        raise RuntimeError("typed_action_failed")
    return json.loads(result.stdout) if result.stdout.lstrip().startswith(("{", "[")) else None


def run(client, mode, case):
    try:
        client_app = clients / (client + ".app")
        if launch_services:
            with tempfile.TemporaryDirectory(prefix="mixed-probe-client-") as directory:
                result_file = pathlib.Path(directory) / "result.json"
                r = subprocess.run(["/usr/bin/open", "-n", "-W", "-g", "-a", str(client_app),
                                    "--stdout", str(result_file), "--stderr", "/dev/null", "--args", mode, case],
                                   capture_output=True, text=True, timeout=20)
                data = json.loads(result_file.read_text())
                exit_code = 0 if r.returncode == 0 and data.get("ok") else 1
        else:
            r = subprocess.run([str(client_app / "Contents/MacOS" / client), mode, case],
                               capture_output=True, text=True, timeout=20)
            data = json.loads(r.stdout)
            exit_code = r.returncode
        safe = {k: data[k] for k in ["ok", "fake_ip", "status", "resolver_code", "answer_count", "stage"] if k in data}
        return {"client": "selected" if client == selected else "control", "mode": mode,
                "case": case, "exit": exit_code, "result": safe}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {"client": "selected" if client == selected else "control", "mode": mode,
                "case": case, "failed": "timeout_or_invalid_result"}


def observe(pending):
    seen = set()
    while not all(f.done() for f in pending):
        for connection in ctl("rpc", "connections").get("connections", []):
            metadata = connection.get("metadata", {})
            process = metadata.get("process")
            if process not in [selected, control, "MihomoDNSHelper"]:
                continue
            # Never retain domains, addresses, node names, connection IDs, or raw metadata.
            record = {"client": "selected" if process == selected else "helper" if process == "MihomoDNSHelper" else "control",
                      "proxy": "Proxy" in connection.get("chains", []),
                      "direct": "DIRECT" in connection.get("chains", []),
                      "process_rule": connection.get("rule") == "ProcessName",
                      "rule_matches_client": connection.get("rulePayload") == process}
            seen.add(json.dumps(record, sort_keys=True))
        time.sleep(0.1)
    return [json.loads(r) for r in sorted(seen)]

def local_doh_answer():
    # Native URLSession honors the same macOS trust policy as the installed resolver.
    return run(control, "doh", "a")


before = ctl("status", "--json")
assert before.get("active_profile") == "sheng.yaml" and before.get("health", {}).get("network_consistent") is True
assert "dns_probe_enabled=false" in subprocess.check_output([HOST, "--status"], text=True, timeout=15)
assert "app_probe_enabled=false" in subprocess.check_output([HOST, "--app-status"], text=True, timeout=15)
source = pathlib.Path.home() / "Library/Application Support/MihomoBox/profiles/sheng.yaml"
raw = source.read_text()
original_digest = hashlib.sha256(source.read_bytes()).hexdigest()
assert len(re.findall(r"^rules:\s*$", raw, re.M)) == 1
assert re.search(r"^  enhanced-mode:\s*fake-ip\s*$", raw, re.M)
assert re.search(r"^  fake-ip-filter-mode:\s*rule\s*$", raw, re.M)
assert len(re.findall(r"^  fake-ip-filter:\s*$", raw, re.M)) == 1
report = {"cache_flushed": False, "strict_system_dns_isolation": False, "phases": [], "rollback": False,
          "launch_services": launch_services}
deadline = time.monotonic() + 210
watchdog = None
try:
    with tempfile.TemporaryDirectory(prefix="mihomo-mixed-cache-") as folder:
        target = pathlib.Path(folder) / "mixed-cache-probe.yaml"
        # Independent restoration if this test process dies. Only restore while
        # our exact temporary profile is active; do not overwrite a user switch.
        watchdog_code = """
import subprocess,json,time
time.sleep(230)
c='/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl'
try:
 d=json.loads(subprocess.check_output([c,'status','--json'],timeout=30))
 if d.get('active_profile')=='mixed-cache-probe.yaml':
  subprocess.run([c,'profile','switch','sheng.yaml'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=35)
except Exception: pass
"""
        watchdog = subprocess.Popen([sys.executable, "-c", watchdog_code],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for phase, selected_policy, control_policy in [
                ("selected_proxy", "Proxy", "DIRECT"),
                ("selected_reject", "REJECT", "DIRECT"),
                ("policies_swapped", "DIRECT", "Proxy")]:
            if time.monotonic() >= deadline:
                raise TimeoutError("experiment_budget")
            content = re.sub(r"^(rules:\s*)$", lambda m: m[1] +
                             "\n  - PROCESS-NAME,MihomoDNSSelected," + selected_policy +
                             "\n  - PROCESS-NAME,MihomoDNSHelper," + selected_policy +
                             "\n  - PROCESS-NAME,MihomoDNSControl," + control_policy, raw, count=1, flags=re.M)
            # Same Fake IP semantics for both test names and every test identity.
            content = re.sub(r"^(  fake-ip-filter:\s*)$", lambda m: m[1] +
                             "\n    - DOMAIN-SUFFIX,example.com,fake-ip\n    - DOMAIN-SUFFIX,example.org,fake-ip",
                             content, count=1, flags=re.M)
            fd = os.open(target, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(content)
            ctl("profile", "import", str(target), "--activate")
            rules = ctl("rpc", "rules").get("rules", [])
            assert [(r.get("type"), r.get("payload"), r.get("proxy")) for r in rules[:3]] == [
                ("ProcessName", selected, selected_policy), ("ProcessName", "MihomoDNSHelper", selected_policy),
                ("ProcessName", control, control_policy)]
            item = {"phase": phase, "tests": [], "routes": [], "local_doh": local_doh_answer(),
                    "fresh_system": run(selected, "system", "fresh")}
            report["phases"].append(item)
            # Both first-query orders, then warm/concurrent queries, without a flush.
            for client, case in [(selected, "a"), (control, "a"), (control, "b"), (selected, "b")]:
                item["tests"].append(run(client, "system", case))
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(run, client, "system", "a") for client in [selected, control]]
                item["tests"].extend(f.result() for f in futures)
                for mode in ["https", "doh-connect"]:
                    for case in ["a", "b"]:
                        futures = [pool.submit(run, client, mode, case) for client in [selected, control]]
                        item["routes"].extend(observe(futures))
                        item["tests"].extend(f.result() for f in futures)
            item["dns_consistent"] = all(t.get("exit") == 0 and t.get("result", {}).get("fake_ip") is True
                                         for t in item["tests"] if t["mode"] == "system")
            item["connections_expected"] = all(
                (t.get("exit") != 0 and t.get("result", {}).get("ok") is False)
                if phase == "selected_reject" and t["client"] == "selected"
                else (t.get("exit") == 0 and t.get("result", {}).get("status") == 200)
                for t in item["tests"] if t["mode"] == "https")
            expected = {"selected": selected_policy, "control": control_policy}
            item["routes_expected"] = all(
                any(r["client"] == client and r["process_rule"] and r["rule_matches_client"]
                    and r["proxy"] == (policy == "Proxy") and r["direct"] == (policy == "DIRECT")
                    for r in item["routes"])
                for client, policy in expected.items() if policy != "REJECT")
            item["routes_expected"] = item["routes_expected"] and all(
                r["process_rule"] and r["rule_matches_client"]
                and r["proxy"] == (expected[r["client"]] == "Proxy")
                and r["direct"] == (expected[r["client"]] == "DIRECT") for r in item["routes"])
            fakeip_tests = [t for t in item["tests"] if t["mode"] == "doh-connect"]
            item["fakeip_connections_expected"] = len(fakeip_tests) == 4 and all(
                (t.get("exit") != 0 and t.get("result", {}).get("ok") is False
                 and t.get("result", {}).get("stage", "").startswith("tls_"))
                if phase == "selected_reject" and t["client"] == "selected"
                else (t.get("exit") == 0 and t.get("result", {}).get("status") == 200
                      and t.get("result", {}).get("fake_ip") is True)
                for t in fakeip_tests)
            print(json.dumps({"phase": phase, "dns_consistent": item["dns_consistent"],
                              "connections_expected": item["connections_expected"],
                              "observed_routes": len(item["routes"])}), flush=True)
except Exception as error:
    report["error"] = type(error).__name__
finally:
    try:
        ctl("profile", "switch", "sheng.yaml")
        after = ctl("status", "--json")
        doh = ctl("local-doh", "status")
        report["rollback"] = (after.get("active_profile") == "sheng.yaml"
                              and after.get("health", {}).get("network_consistent") is True
                              and doh.get("runtime_healthy") is True
                              and hashlib.sha256(source.read_bytes()).hexdigest() == original_digest)
    finally:
        if watchdog and report["rollback"]:
            watchdog.terminate()
            watchdog.wait(timeout=5)
        report["basic_cases_passed"] = len(report["phases"]) == 3 and all(
            p.get("dns_consistent") and p.get("connections_expected") and p.get("routes_expected")
            for p in report["phases"])
        report["fakeip_connection_path_verified"] = len(report["phases"]) == 3 and all(
            p.get("fakeip_connections_expected") and p.get("routes_expected") for p in report["phases"])
        output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: report[k] for k in ["basic_cases_passed", "rollback", "strict_system_dns_isolation"]}))
if not report["rollback"] or not report["basic_cases_passed"]:
    raise SystemExit(1)
