import Foundation

let custom = "app_00000000-0000-0000-0000-000000000001"
let record = ["id": "example.cli", "path": "/Applications/Example.app/Contents/MacOS/example",
              "category": custom, "requirement": "identifier \"example.cli\""]
let valid: [String: Any] = ["mode": "ai", "deadline": 0, "routing": "per-application-v2",
                           "targets": [record], "ports": [custom: 17975]]
func accepted(_ raw: [String: Any]) -> Bool { (try? AIProxyConfiguration(raw, now: 1)) != nil }
precondition(accepted(valid))
let config = try AIProxyConfiguration(valid, now: 1)
precondition(config.proxyPort(for: custom) == 17975)
precondition(config.proxyPort(for: "cli_host") == nil)
precondition(config.proxyPort(for: "unknown") == nil)
precondition(!config.bypass.contains("192.168.13.12"))
var current = valid
current["routing"] = "per-application-v3"
current["bypassCIDRs"] = ["192.168.13.12/32", "fd12::/16"]
let currentConfig = try AIProxyConfiguration(current, now: 1)
precondition(currentConfig.bypass.contains("192.168.13.12"))
precondition(!currentConfig.bypass.contains("192.168.13.14"))
precondition(!currentConfig.bypass.contains("1.1.1.1"))
current["bypassCIDRs"] = [String]()
let disabledConfig = try AIProxyConfiguration(current, now: 1)
precondition(!disabledConfig.bypass.contains("192.168.13.12"))
for value: Any in [["0.0.0.0/0"], ["198.18.0.0/16"], [true], "10.0.0.0/8"] {
    current["bypassCIDRs"] = value
    precondition(!accepted(current))
}
current.removeValue(forKey: "bypassCIDRs")
precondition(!accepted(current))
for ports: [String: Any] in [[custom: 7897], [custom: 18003], [custom: true], [custom: 17975.5],
                            ["chatgpt": 17975], ["unknown": 17975], [:],
                            [custom: 17975, "app_00000000-0000-0000-0000-000000000002": 17975]] {
    var invalid = valid; invalid["ports"] = ports
    precondition(!accepted(invalid))
}
var invalid = valid; invalid["targets"] = [record, record]
precondition(!accepted(invalid))
var unknown = record; unknown["category"] = "chatgpt"
invalid = valid; invalid["targets"] = [unknown]
precondition(!accepted(invalid))
var legacyRecord = record; legacyRecord["category"] = "chatgpt"
let legacy: [String: Any] = ["mode": "ai", "deadline": 0, "routing": "per-application-v1", "targets": [legacyRecord]]
precondition(accepted(legacy))
let legacyConfiguration = try AIProxyConfiguration(legacy, now: 1)
precondition(legacyConfiguration.proxyPort(for: "chatgpt") == 17971)
print("App Proxy configuration validation passed")
