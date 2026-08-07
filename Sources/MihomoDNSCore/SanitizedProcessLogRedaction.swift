import Foundation

/// Strips credentials from proxy-kernel error text that is about to be written
/// to disk.
///
/// Error lines are retained in full otherwise. What identifies a failure is the
/// host, the address, the reason and the proxy that was carrying the traffic,
/// and holding those back left an outage represented by a count and nothing
/// else. Secrets are a different matter: a subscription URL grants access to a
/// whole node list, and a proxy password or the controller secret grants
/// control outright, so those are removed even though the surrounding text
/// stays.
public enum SanitizedProcessLogRedaction {
    private static let placeholder = "<redacted>"

    /// Query and header names whose value is a credential. Matched
    /// case-insensitively, and only the value is replaced.
    private static let secretKeys = [
        "token", "secret", "password", "passwd", "pwd", "apikey", "api_key",
        "auth", "authorization", "access_key", "sign", "signature", "uuid",
    ]

    private static let patterns: [(NSRegularExpression, String)] = {
        var built: [(NSRegularExpression, String)] = []
        func add(_ pattern: String, _ template: String) {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { return }
            built.append((expression, template))
        }
        // user:password@host — the password, and the user with it, since a
        // proxy username is half a credential.
        add("//[^/@\\s:]+:[^/@\\s]+@", "//\(placeholder)@")
        // key=value and "key": "value" for anything credential-shaped. The
        // optional quote after the key is what makes the JSON form match.
        let keys = secretKeys.joined(separator: "|")
        add("(?<![A-Za-z0-9_])(\(keys))\"?\\s*[=:]\\s*\"?[^\\s\"&,}]+\"?", "$1=\(placeholder)")
        // Subscription URLs: any http(s) URL carrying a query string, which is
        // how node lists are handed out. A bare URL keeps its path.
        add("(https?://[^\\s?]+)\\?[^\\s]*", "$1?\(placeholder)")
        // Long opaque tokens that survived the above.
        add("(?<![A-Za-z0-9+/=])[A-Za-z0-9+/=]{40,}(?![A-Za-z0-9+/=])", placeholder)
        return built
    }()

    public static func redact(_ line: String) -> String {
        var result = line
        for (expression, template) in patterns {
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        // Keep a single pathological line from dominating a window.
        if result.count > 1_024 {
            result = String(result.prefix(1_024)) + "…"
        }
        return result
    }
}
