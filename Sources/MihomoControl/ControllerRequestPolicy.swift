import Foundation

/// Which Mihomo controller requests the daemon will forward on behalf of the
/// dashboard.
///
/// This is an allowlist guarding a privilege boundary: the WebView is untrusted
/// and reaches the root-owned controller only through here, so anything not
/// named below is refused rather than passed along. It lives in this module,
/// away from the daemon executable, so the boundary can actually be tested —
/// it previously had no test coverage at all.
public enum ControllerRequestPolicy {
    /// Requests matched literally as "METHOD /path".
    static let exact: Set<String> = [
        "GET /version", "GET /configs", "GET /proxies", "GET /rules",
        "GET /providers/proxies", "GET /providers/rules", "GET /connections",
        "DELETE /connections", "PATCH /configs", "PUT /configs", "PATCH /rules/disable",
        "POST /cache/fakeip/flush", "POST /cache/dns/flush", "POST /configs/geo",
        // The dashboard's DNS Query tool. Its query string carries the name
        // being looked up, which is exactly what this project refuses to
        // record — allowed only because the control path logs operation names
        // and never targets or arguments.
        "GET /dns/query",
    ]

    public static func allows(method: String, path: String) -> Bool {
        if exact.contains("\(method) \(path)") { return true }
        return matches(method, path, prefix: "/proxies/", segmentCounts: [1], suffix: nil)
            || matches(method, path, prefix: "/proxies/", segmentCounts: [1], suffix: "/delay")
            || matches(method, path, prefix: "/group/", segmentCounts: [1], suffix: "/delay")
            || matches(method, path, prefix: "/providers/proxies/", segmentCounts: [1], suffix: nil)
            || matches(
                method, path, prefix: "/providers/proxies/",
                segmentCounts: [1, 2], suffix: "/healthcheck"
            )
            || matches(method, path, prefix: "/providers/rules/", segmentCounts: [1], suffix: nil)
            || matches(method, path, prefix: "/connections/", segmentCounts: [1], suffix: nil)
    }

    private static func matches(
        _ method: String,
        _ path: String,
        prefix: String,
        segmentCounts: Set<Int>,
        suffix: String?
    ) -> Bool {
        let methods: Set<String>
        if prefix == "/proxies/" && suffix == nil { methods = ["PUT", "DELETE"] }
        else if prefix == "/connections/" { methods = ["DELETE"] }
        else if suffix == "/delay" || suffix == "/healthcheck" { methods = ["GET"] }
        else { methods = ["PUT"] }
        guard methods.contains(method), path.hasPrefix(prefix) else { return false }
        var middle = String(path.dropFirst(prefix.count))
        if let suffix {
            guard middle.hasSuffix(suffix) else { return false }
            middle.removeLast(suffix.count)
        }
        let segments = middle.split(separator: "/", omittingEmptySubsequences: false)
        return segmentCounts.contains(segments.count) && segments.allSatisfy { !$0.isEmpty }
    }
}
