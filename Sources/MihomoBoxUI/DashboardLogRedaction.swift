import Foundation

/// Removes credential-shaped values before controller log frames enter UI
/// state. The native dashboard keeps only a bounded in-memory sample and never
/// writes these messages to disk or unified logging.
enum DashboardLogRedaction {
  private static let placeholder = "<redacted>"

  private static let patterns: [(NSRegularExpression, String)] = {
    var built: [(NSRegularExpression, String)] = []
    func add(_ pattern: String, _ template: String) {
      guard
        let expression = try? NSRegularExpression(
          pattern: pattern,
          options: [.caseInsensitive]
        )
      else { return }
      built.append((expression, template))
    }

    add("//[^/@\\s:]+:[^/@\\s]+@", "//\(placeholder)@")
    let keys = [
      "token", "secret", "password", "passwd", "pwd", "apikey", "api_key",
      "auth", "authorization", "access_key", "sign", "signature", "uuid",
    ].joined(separator: "|")
    add(
      "(?<![A-Za-z0-9_])((?:proxy-)?authorization|cookie|set-cookie)\\s*:\\s*"
        + "(?:basic|bearer|digest)?\\s*[^\\s,;]+",
      "$1: \(placeholder)"
    )
    add(
      "(?<![A-Za-z0-9_])(\(keys))\"?\\s*[=:]\\s*\"?"
        + "(?:basic|bearer|digest)\\s+[^\\s\"&,};]+\"?",
      "$1=\(placeholder)"
    )
    add(
      "(?<![A-Za-z0-9_])(\(keys))\"?\\s*[=:]\\s*\"?[^\\s\"&,}]+\"?",
      "$1=\(placeholder)"
    )
    add("(https?://)(?:[^/@\\s]+@)?([^/\\s?#]+)(?:[/\\s?#][^\\s]*)?", "$1$2/\(placeholder)")
    add("(?<![A-Za-z0-9+/=])[A-Za-z0-9+/=]{40,}(?![A-Za-z0-9+/=])", placeholder)
    return built
  }()

  static func redact(_ line: String) -> String {
    var result = line
    for (expression, template) in patterns {
      result = expression.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: template
      )
    }
    if result.count > 1_024 {
      result = String(result.prefix(1_024)) + "…"
    }
    return result
  }
}
