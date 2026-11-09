import Foundation

let custom = "app_00000000-0000-0000-0000-000000000001"
let stamp = String(repeating: "a", count: 64)
let route = AppProxyPolicy.Route(category: custom, teams: ["ABCDE12345"], identifiers: ["example.cli"])
let policy = AppProxyPolicy(ownerUID: getuid(), routes: [route], folders: [], grants: [], codeStamp: stamp)
let valid: [String: Any] = ["mode": "ai", "routing": "per-application-v5", "policy": try policy.encoded(),
                            "rulesDigest": stamp, "bypassCIDRs": [String](), "ports": [custom: 17975]]
func accepted(_ raw: [String: Any]) -> Bool { (try? AIProxyConfiguration(raw)) != nil }
precondition(accepted(valid))
let config = try AIProxyConfiguration(valid)
precondition(config.proxyPort(for: custom) == 17975)
precondition(config.proxyPort(for: "unknown") == nil)
precondition(config.routes.map(\.route) == [route], "every route compiles its Team requirement")
precondition(!config.bypass.contains("192.168.50.20"))
var current = valid
current["bypassCIDRs"] = ["192.168.50.20/32", "fd12::/16"]
let currentConfig = try AIProxyConfiguration(current)
precondition(currentConfig.bypass.contains("192.168.50.20"))
precondition(!currentConfig.bypass.contains("192.168.50.22"))
precondition(!currentConfig.bypass.contains("1.1.1.1"))
for value: Any in [["0.0.0.0/0"], ["198.18.0.0/16"], [true], "10.0.0.0/8"] {
    current["bypassCIDRs"] = value
    precondition(!accepted(current))
}
current.removeValue(forKey: "bypassCIDRs")
precondition(!accepted(current))
// Every route needs its own listener; built-in applications keep their fixed ports.
for ports: [String: Any] in [[custom: 7897], [custom: 18003], [custom: true], [custom: 17975.5],
                            ["chatgpt": 17975], ["unknown": 17975], [:],
                            ["app_00000000-0000-0000-0000-000000000002": 17976],
                            [custom: 17975, "app_00000000-0000-0000-0000-000000000002": 17975]] {
    var invalid = valid; invalid["ports"] = ports
    precondition(!accepted(invalid))
}
let builtin = AppProxyPolicy(ownerUID: getuid(), routes: [.init(category: "chatgpt", teams: ["2DC432GLL2"], identifiers: ["codex"])],
                             folders: [], grants: [], codeStamp: stamp)
var preset = valid; preset["policy"] = try builtin.encoded(); preset["ports"] = ["chatgpt": 17971]
precondition(accepted(preset))
preset["ports"] = ["chatgpt": 17972]
precondition(!accepted(preset))
// Older generations listed scanned executables: never accepted, so the host saves this one again.
for routing in ["per-application-v1", "per-application-v2", "per-application-v3", "per-application-v4"] {
    var old = valid; old["routing"] = routing
    precondition(!accepted(old))
}
for key in ["deadline", "targets", "identitySnapshot"] {
    var extra = valid; extra[key] = 0
    precondition(!accepted(extra))
}
for key in ["policy", "rulesDigest", "ports", "mode"] {
    var missing = valid; missing.removeValue(forKey: key)
    precondition(!accepted(missing))
}
for digest in ["stale", String(repeating: "A", count: 64)] {
    var invalid = valid; invalid["rulesDigest"] = digest
    precondition(!accepted(invalid))
}
// The provider validates the policy itself, whatever the host encoded.
let duplicate = AppProxyPolicy(ownerUID: getuid(), routes: [route, .init(category: "chatgpt", teams: ["ABCDE12345"], identifiers: ["example.cli"])],
                               folders: [], grants: [], codeStamp: stamp)
let root = AppProxyPolicy(ownerUID: 0, routes: [route], folders: [], grants: [], codeStamp: stamp)
for data in [Data("{}".utf8), try JSONEncoder().encode(duplicate), try JSONEncoder().encode(root)] {
    var invalid = valid; invalid["policy"] = data; invalid["ports"] = [custom: 17975, "chatgpt": 17971]
    precondition(!accepted(invalid))
}
print("App Proxy v5 configuration validation passed")
