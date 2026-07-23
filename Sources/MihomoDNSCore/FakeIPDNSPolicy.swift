import Foundation

/// Decides whether a failed Mihomo lookup may be retried through the original
/// network DNS. The policy is intentionally fail-closed: if a Fake-IP rule
/// cannot be evaluated locally, the query remains owned by Mihomo.
struct FakeIPDNSPolicy: Sendable {
    private enum Mode: Sendable {
        case originalDNS
        case blacklist(patterns: [DomainPattern])
        case whitelist(patterns: [DomainPattern], hasOpaquePatterns: Bool)
        case rule(rules: [FakeIPRule])
        case denyOriginalDNS
    }

    private let mode: Mode

    init(configPath: String?) {
        if let configPath {
            if let yaml = try? String(contentsOfFile: configPath, encoding: .utf8) {
                mode = Self.resolveMode(yaml: yaml)
            } else {
                mode = .denyOriginalDNS
            }
        } else {
            mode = .originalDNS
        }
    }

    init(yaml: String) {
        mode = Self.resolveMode(yaml: yaml)
    }

    private static func resolveMode(yaml: String) -> Mode {
        guard let configuration = DNSYAMLConfiguration.parse(yaml) else {
            return .originalDNS
        }
        guard configuration.enhancedMode == "fake-ip" else {
            return .originalDNS
        }

        switch configuration.filterMode {
        case "blacklist":
            return .blacklist(patterns: configuration.filters.compactMap(DomainPattern.init))
        case "whitelist":
            let patterns = configuration.filters.compactMap(DomainPattern.init)
            return .whitelist(
                patterns: patterns,
                hasOpaquePatterns: patterns.count != configuration.filters.count
            )
        case "rule":
            return .rule(rules: configuration.filters.map(FakeIPRule.init))
        default:
            return .denyOriginalDNS
        }
    }

    func allowsOriginalDNSFallback(for query: Data) -> Bool {
        guard let domain = try? DNSMessage.questionName(query) else { return false }
        return allowsOriginalDNSFallback(forDomain: domain)
    }

    func allowsOriginalDNSFallback(forDomain domain: String) -> Bool {
        switch mode {
        case .originalDNS:
            return true
        case .blacklist(let patterns):
            // In blacklist mode, a matched filter is explicitly excluded from
            // Fake-IP and is therefore safe to resolve through original DNS.
            return patterns.contains { $0.matches(domain) }
        case .whitelist(let patterns, let hasOpaquePatterns):
            // Only matched entries receive Fake-IP. An imported domain set
            // cannot be evaluated here, so its presence makes a non-match
            // ambiguous and must remain fail-closed.
            if patterns.contains(where: { $0.matches(domain) }) {
                return false
            }
            return !hasOpaquePatterns
        case .rule(let rules):
            for rule in rules {
                switch rule.evaluate(domain) {
                case .noMatch:
                    continue
                case .fakeIP, .opaque:
                    return false
                case .realIP:
                    return true
                }
            }
            return false
        case .denyOriginalDNS:
            return false
        }
    }
}

private struct DNSYAMLConfiguration {
    var enhancedMode = "redir-host"
    var filterMode = "blacklist"
    var filters: [String] = []

    static func parse(_ yaml: String) -> DNSYAMLConfiguration? {
        if let json = parseJSON(yaml) {
            return json
        }
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let dnsIndex = lines.firstIndex(where: { rawLine in
            let content = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            return indentation(rawLine) == 0 && content == "dns:"
        }) else {
            let hasUnsupportedDNSDeclaration = lines.contains { rawLine in
                let content = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
                guard indentation(rawLine) == 0,
                      let separator = content.firstIndex(of: ":") else {
                    return false
                }
                return content[..<separator].trimmingCharacters(in: .whitespaces) == "dns"
            }
            if hasUnsupportedDNSDeclaration || yaml.contains("\"dns\"") {
                return DNSYAMLConfiguration(
                    enhancedMode: "fake-ip",
                    filterMode: "unsupported",
                    filters: []
                )
            }
            return nil
        }

        var result = DNSYAMLConfiguration()
        var directIndent: Int?
        var readingFilters = false

        for rawLine in lines.dropFirst(dnsIndex + 1) {
            let withoutComment = stripComment(rawLine)
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let indent = indentation(rawLine)
            if indent == 0 { break }

            if readingFilters, trimmed.hasPrefix("-") {
                let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    result.filters.append(unquote(value))
                }
                continue
            }

            guard !trimmed.hasPrefix("-") else { continue }
            if directIndent == nil {
                directIndent = indent
            }
            guard indent == directIndent else { continue }
            readingFilters = false

            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "enhanced-mode":
                result.enhancedMode = unquote(value).lowercased()
            case "fake-ip-filter-mode":
                result.filterMode = unquote(value).lowercased()
            case "fake-ip-filter":
                readingFilters = true
                if value.hasPrefix("["), value.hasSuffix("]") {
                    result.filters.append(
                        contentsOf: splitInlineList(String(value.dropFirst().dropLast()))
                    )
                    readingFilters = false
                } else if !value.isEmpty {
                    // Aliases and other YAML structures are not safe to infer.
                    result.filters.append(value)
                    readingFilters = false
                }
            default:
                continue
            }
        }
        return result
    }

    private static func parseJSON(_ text: String) -> DNSYAMLConfiguration? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dns = root["dns"] as? [String: Any] else {
            return nil
        }
        return DNSYAMLConfiguration(
            enhancedMode: (dns["enhanced-mode"] as? String)?.lowercased() ?? "redir-host",
            filterMode: (dns["fake-ip-filter-mode"] as? String)?.lowercased() ?? "blacklist",
            filters: dns["fake-ip-filter"] as? [String] ?? []
        )
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if character == "'" || character == "\"" {
                if quote == nil {
                    quote = character
                } else if quote == character, previous != "\\" {
                    quote = nil
                }
            } else if character == "#", quote == nil,
                      previous == nil || previous?.isWhitespace == true {
                return String(line[..<index])
            }
            previous = character
        }
        return line
    }

    private static func splitInlineList(_ value: String) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var quote: Character?
        var previous: Character?
        for index in value.indices {
            let character = value[index]
            if character == "'" || character == "\"" {
                if quote == nil {
                    quote = character
                } else if quote == character, previous != "\\" {
                    quote = nil
                }
            } else if character == ",", quote == nil {
                let item = value[start..<index].trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { result.append(unquote(item)) }
                start = value.index(after: index)
            }
            previous = character
        }
        let item = value[start...].trimmingCharacters(in: .whitespaces)
        if !item.isEmpty { result.append(unquote(item)) }
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "'" && last == "'") || (first == "\"" && last == "\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

private struct DomainPattern: Sendable {
    private enum Kind: Sendable {
        case exact(String)
        case suffix(String, includesRoot: Bool)
        case labels([String])
        case singleLabel
    }

    private let kind: Kind

    init?(_ rawValue: String) {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !value.isEmpty,
              !value.hasPrefix("geosite:"),
              !value.hasPrefix("rule-set:"),
              !value.contains(",") else {
            return nil
        }

        if rawValue.lowercased().hasPrefix("+.") {
            let suffix = String(value.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { return nil }
            kind = .suffix(suffix, includesRoot: true)
        } else if rawValue.hasPrefix(".") {
            guard !value.contains("*") else { return nil }
            kind = .suffix(value, includesRoot: false)
        } else if value == "*" {
            kind = .singleLabel
        } else if value.contains("*") {
            let labels = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard labels.allSatisfy({ $0 == "*" || (!$0.isEmpty && !$0.contains("*")) }) else {
                return nil
            }
            kind = .labels(labels)
        } else {
            kind = .exact(value)
        }
    }

    func matches(_ rawDomain: String) -> Bool {
        let domain = rawDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch kind {
        case .exact(let value):
            return domain == value
        case .suffix(let suffix, let includesRoot):
            return (includesRoot && domain == suffix) || domain.hasSuffix(".\(suffix)")
        case .labels(let patternLabels):
            let domainLabels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard domainLabels.count == patternLabels.count else { return false }
            return zip(patternLabels, domainLabels).allSatisfy { pattern, label in
                pattern == "*" || pattern == label
            }
        case .singleLabel:
            return !domain.contains(".")
        }
    }
}

private struct FakeIPRule: Sendable {
    enum Result {
        case noMatch
        case fakeIP
        case realIP
        case opaque
    }

    private enum Matcher: Sendable {
        case domain(String)
        case suffix(String)
        case keyword(String)
        case match
        case opaque
    }

    private let matcher: Matcher
    private let usesFakeIP: Bool

    init(_ rawValue: String) {
        let fields = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let action = fields.last, action == "fake-ip" || action == "real-ip" else {
            matcher = .opaque
            usesFakeIP = true
            return
        }
        usesFakeIP = action == "fake-ip"
        switch fields.first {
        case "domain" where fields.count == 3:
            matcher = .domain(fields[1])
        case "domain-suffix" where fields.count == 3:
            matcher = .suffix(fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        case "domain-keyword" where fields.count == 3:
            matcher = .keyword(fields[1])
        case "match" where fields.count == 2:
            matcher = .match
        default:
            matcher = .opaque
        }
    }

    func evaluate(_ rawDomain: String) -> Result {
        let domain = rawDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let matched: Bool
        switch matcher {
        case .domain(let value):
            matched = domain == value
        case .suffix(let value):
            matched = domain == value || domain.hasSuffix(".\(value)")
        case .keyword(let value):
            matched = domain.contains(value)
        case .match:
            matched = true
        case .opaque:
            return .opaque
        }
        guard matched else { return .noMatch }
        return usesFakeIP ? .fakeIP : .realIP
    }
}
