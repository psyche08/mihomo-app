#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/mihomobox-system-proxy.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/main.swift" <<'SWIFT'
import Foundation
let before: [String:Any] = ["HTTPEnable":0,"HTTPProxy":"previous.example","ExceptionsList":["*.local"],"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://private.invalid/pac"]
let patch = SystemProxyController.patch(port:7897)
var enabled = before.merging(patch) { _,new in new }
assert(SystemProxyController.matches(enabled,patch))
let restored = SystemProxyController.restored(current:enabled,before:before,applied:patch)
assert(NSDictionary(dictionary:restored).isEqual(to:before),"missing original keys must be removed; original PAC and bypass must survive")
enabled["HTTPProxy"] = "another-app.invalid"
assert(NSDictionary(dictionary:SystemProxyController.restored(current:enabled,before:before,applied:patch)).isEqual(to:enabled),"never clobber another client's edits")
var changedBypass = before.merging(patch) { _,new in new }; changedBypass["ExceptionsList"] = ["new.local"]
let rebased = SystemProxyController.restored(current:changedBypass,before:before,applied:patch)
assert(rebased["ExceptionsList"] as? [String] == ["new.local"],"unowned fields changed while active must survive")
assert(!SystemProxyController.matches(before,patch))
assert(!SystemProxyController.matches(changedBypass,SystemProxyController.patch(port:8899)))
print("system proxy preservation tests passed")
SWIFT
swiftc "$ROOT/Sources/MihomoDaemon/SystemProxyController.swift" "$STAGE/main.swift" -o "$STAGE/check"
"$STAGE/check"
