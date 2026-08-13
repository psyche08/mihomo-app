import CoreFoundation
import Foundation

/// Which Mihomo controller requests the daemon will forward on behalf of the
/// native dashboard.
///
/// This is an allowlist guarding a privilege boundary: UI input remains
/// untrusted and reaches the root-owned controller only through here, so
/// anything not named below is refused rather than passed along. It lives in this module,
/// away from the daemon executable, so the boundary can actually be tested —
/// it previously had no test coverage at all.
public enum ControllerRequestPolicy {
    public static let latencyProbe = "https://cp.cloudflare.com/generate_204"
    public static let delayTimeoutRange = 1 ... 60_000

    /// Requests matched literally as "METHOD /path".
    static let exact: Set<String> = [
        "GET /version", "GET /configs", "GET /proxies", "GET /rules",
        "GET /providers/proxies", "GET /providers/rules", "GET /connections",
        "DELETE /connections", "PATCH /configs", "PATCH /rules/disable",
        "POST /cache/fakeip/flush", "POST /cache/dns/flush", "POST /configs/geo",
    ]

    /// Validates the complete request that may cross from the unprivileged app
    /// into the root daemon. This deliberately validates query values and JSON
    /// bodies as well as the route: a path-only allowlist would still let a
    /// caller choose an arbitrary latency-probe URL or patch managed settings.
    public static func allows(method: String, target: String, body: Data?) -> Bool {
        guard target.utf8.count <= 4_096,
              (body?.count ?? 0) <= 1_048_576,
              let components = URLComponents(string: target),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/"),
              allows(method: method, path: components.percentEncodedPath),
              validQuery(method: method, components: components) else {
            return false
        }

        let path = components.percentEncodedPath
        switch (method, path) {
        case ("PATCH", "/configs"):
            return validConfigPatch(body)
        case ("PATCH", "/rules/disable"):
            return validRulePatch(body)
        default:
            return body == nil || body?.isEmpty == true
        }
    }

    public static func allows(method: String, path: String) -> Bool {
        if exact.contains("\(method) \(path)") { return true }
        return matches(method, path, prefix: "/proxies/", segmentCounts: [1], suffix: "/delay")
            || matches(method, path, prefix: "/group/", segmentCounts: [1], suffix: "/delay")
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
        if prefix == "/connections/" { methods = ["DELETE"] }
        else if suffix == "/delay" || suffix == "/healthcheck" { methods = ["GET"] }
        else { methods = ["PUT"] }
        guard methods.contains(method), path.hasPrefix(prefix) else { return false }
        var middle = String(path.dropFirst(prefix.count))
        if let suffix {
            guard middle.hasSuffix(suffix) else { return false }
            middle.removeLast(suffix.count)
        }
        let segments = middle.split(separator: "/", omittingEmptySubsequences: false)
        return segmentCounts.contains(segments.count) && segments.allSatisfy { segment in
            guard !segment.isEmpty,
                  let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".", decoded != "..",
                  decoded.utf8.count <= 1_024 else {
                return false
            }
            return !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private static func validQuery(method: String, components: URLComponents) -> Bool {
        let path = components.percentEncodedPath
        let isDelay = method == "GET" && (
            ((path.hasPrefix("/proxies/") || path.hasPrefix("/group/")) &&
                path.hasSuffix("/delay")) ||
                providerNodeHealthcheck(path)
        )
        guard isDelay else { return components.percentEncodedQuery == nil }
        guard let items = components.queryItems, items.count == 2 else { return false }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                return false
            }
        }
        guard values.count == 2,
              values["url"] == latencyProbe,
              let timeout = values["timeout"].flatMap(Int.init),
              delayTimeoutRange.contains(timeout) else {
            return false
        }
        return true
    }

    private static func providerNodeHealthcheck(_ path: String) -> Bool {
        guard path.hasPrefix("/providers/proxies/"), path.hasSuffix("/healthcheck") else {
            return false
        }
        let prefix = "/providers/proxies/"
        let suffix = "/healthcheck"
        let middle = path.dropFirst(prefix.count).dropLast(suffix.count)
        return middle.split(separator: "/", omittingEmptySubsequences: false).count == 2
    }

    private static func validConfigPatch(_ body: Data?) -> Bool {
        guard let object = jsonObject(body), object.count == 1,
              let (key, value) = object.first else {
            return false
        }
        switch key {
        case "allow-lan", "ipv6", "unified-delay", "tcp-concurrent":
            return isJSONBoolean(value)
        case "log-level":
            return (value as? String).map {
                ["silent", "error", "warning", "info", "debug"].contains($0)
            } ?? false
        case "find-process-mode":
            return (value as? String).map {
                ["off", "strict", "always"].contains($0)
            } ?? false
        default:
            return false
        }
    }

    private static func validRulePatch(_ body: Data?) -> Bool {
        guard let object = jsonObject(body), !object.isEmpty else { return false }
        return object.allSatisfy { key, value in
            Int(key).map { $0 >= 0 } == true && isJSONBoolean(value)
        }
    }

    private static func jsonObject(_ body: Data?) -> [String: Any]? {
        guard let body, !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}
