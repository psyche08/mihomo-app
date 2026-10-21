import Foundation
var count = 0
func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); count += 1 }
let now = Date().timeIntervalSince1970
let target = ["id": "test", "path": "/Applications/Test.app/Contents/MacOS/Test", "category": "chatgpt", "requirement": "identifier test"]
let valid: [String: Any] = ["mode": "ai", "deadline": now + 100, "targets": [target]]
check((try? AIProxyConfiguration(valid, now: now)) != nil)
for value: Any in [true, "100", -1, now - 1, now + 331, Double.infinity, Double.nan] {
    var bad = valid; bad["deadline"] = value
    check((try? AIProxyConfiguration(bad, now: now)) == nil)
}
var persistent = valid; persistent["deadline"] = 0
check((try! AIProxyConfiguration(persistent, now: now)).deadline == nil)
for pair in [("id", ""), ("path", "relative"), ("path", "/Applications/../tmp/test"),
             ("category", "other"), ("requirement", "not a valid requirement")] {
    var record = target; record[pair.0] = pair.1
    var bad = valid; bad["targets"] = [record]
    check((try? AIProxyConfiguration(bad, now: now)) == nil)
}
for records in [[], Array(repeating: target, count: 513)] {
    var bad = valid; bad["targets"] = records
    check((try? AIProxyConfiguration(bad, now: now)) == nil)
}
var extra = valid; extra["unexpected"] = true
check((try? AIProxyConfiguration(extra, now: now)) == nil)
var routed = persistent; routed["routing"] = "per-application-v1"
let routing = try! AIProxyConfiguration(routed, now: now)
check(routing.proxyPort(for: "chatgpt") == 17971)
check(routing.proxyPort(for: "codex_cli") == 17972)
check(routing.proxyPort(for: "claude") == 17973)
check(routing.proxyPort(for: "claude_cli") == 17974)
check(routing.proxyPort(for: "cli_host") == nil)
check(routing.proxyPort(for: "unknown") == nil)
check((try! AIProxyConfiguration(persistent, now: now)).proxyPort(for: "chatgpt") == 7897)
routed["routing"] = "unexpected"
check((try? AIProxyConfiguration(routed, now: now)) == nil)
print("AI configuration checks passed: \(count)")
