import Foundation
// Built-in listener ports of the v5 configuration. Tests/Fixtures/app-proxy-configuration.swift
// covers validation; this standalone check keeps the probe's port table honest.
var count = 0
func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); count += 1 }
let stamp = String(repeating: "a", count: 64)
let routes = AIProxyConfiguration.builtinPorts.keys.sorted().enumerated().map { index, category in
    AppProxyPolicy.Route(category: category, teams: [String(format: "TEAM%06d", index)], identifiers: ["test"])
}
let policy = AppProxyPolicy(ownerUID: getuid(), routes: routes, folders: [], grants: [], codeStamp: stamp)
let raw: [String: Any] = ["mode": "ai", "routing": AIProxyConfiguration.routing, "policy": try! policy.encoded(),
                          "rulesDigest": stamp, "bypassCIDRs": [String](), "ports": AIProxyConfiguration.builtinPorts]
let configuration = try! AIProxyConfiguration(raw)
check(configuration.proxyPort(for: "chatgpt") == 17971)
check(configuration.proxyPort(for: "codex_cli") == 17972)
check(configuration.proxyPort(for: "claude") == 17973)
check(configuration.proxyPort(for: "claude_cli") == 17974)
check(configuration.proxyPort(for: "jetbrains") == 17970)
check(configuration.proxyPort(for: "unknown") == nil)
var stale = raw; stale["routing"] = "per-application-v4"
check((try? AIProxyConfiguration(stale)) == nil)
print("AI configuration checks passed: \(count)")
