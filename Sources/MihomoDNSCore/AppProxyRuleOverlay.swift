import Foundation
import MihomoControl

/// Reads only block-style rule lists. Unsupported YAML fails before activation;
/// the original profile and its rules remain intact for all other listeners.
struct AppProxyRuleOverlay {
    private let rules: [String]
    private let subRules: [(String, [String])]
    private let preservedTargets: Set<String>

    init(source: String) throws {
        let lines = source.components(separatedBy: "\n")
        preservedTargets = try Self.preservedTargets(lines: lines)
        rules = try Self.sequence(Self.section("rules", empty: "[]", lines: lines))
        let subLines = try Self.section("sub-rules", empty: "{}", lines: lines)
        var parsed: [(String, [String])] = []
        var index = 0
        let indentation = subLines.first.map(Self.indent)
        while index < subLines.count {
            let line = subLines[index]
            guard Self.indent(line) == indentation, let colon = Self.colon(in: line) else {
                throw AppProxySettingsError.unsupportedRules
            }
            let name = try Self.scalar(String(line[..<colon]))
            guard !name.isEmpty, name != "<<", !parsed.contains(where: { $0.0 == name }) else {
                throw AppProxySettingsError.unsupportedRules
            }
            let value = Self.withoutComment(String(line[line.index(after: colon)...]))
            guard value.isEmpty || value == "[]" else { throw AppProxySettingsError.unsupportedRules }
            let start = index + 1
            index = start
            while index < subLines.count,
                  Self.indent(subLines[index]) > indentation! || subLines[index].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                index += 1
            }
            guard value != "[]" || index == start else { throw AppProxySettingsError.unsupportedRules }
            parsed.append((name, try Self.sequence(Array(subLines[start..<index]))))
        }
        subRules = parsed
    }

    func entries(for app: String) throws -> [String] {
        let aliases = Dictionary(uniqueKeysWithValues: subRules.enumerated().map { ($0.element.0, "\(app)-sub-\($0.offset)") })
        func render(_ name: String, _ values: [String]) throws -> [String] {
            if values.isEmpty { return ["  \(name): []"] }
            return ["  \(name):"] + (try values.map {
                "    - " + Self.quoted(try Self.rewrite($0, target: app, aliases: aliases, preserved: preservedTargets))
            })
        }
        return try render(app, rules) + subRules.flatMap { try render(aliases[$0.0]!, $0.1) }
    }

    /// Target positions match pinned core rules/common/base.go ParseRulePayload.
    /// In particular regex/logic payloads may contain commas; their target is last.
    private static func rewrite(_ rule: String, target: String, aliases: [String: String], preserved: Set<String>) throws -> String {
        var fields = rule.components(separatedBy: ",")
        let kind = fields[0].trimmingCharacters(in: .whitespaces).uppercased()
        let lastTarget = ["NOT", "OR", "AND", "SUB-RULE", "DOMAIN-REGEX", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX"].contains(kind)
        let index = kind == "MATCH" ? 1 : lastTarget ? fields.count - 1 : 2
        guard fields.count >= (kind == "MATCH" ? 2 : 3), index < fields.count else {
            throw AppProxySettingsError.unsupportedRules
        }
        let original = fields[index].trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { throw AppProxySettingsError.unsupportedRules }
        if kind == "SUB-RULE" {
            guard let alias = aliases[original] else { throw AppProxySettingsError.unsupportedRules }
            fields[index] = alias
        } else if !preserved.contains(original) {
            fields[index] = target
        }
        return fields.joined(separator: ",")
    }

    /// Named direct/reject/DNS adapters must not accidentally become remote
    /// proxies. Read only name/type; leave all credentials and nested options alone.
    private static func preservedTargets(lines: [String]) throws -> Set<String> {
        var preserved: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE"]
        let body = try section("proxies", empty: "[]", lines: lines)
        guard let first = body.first else { return preserved }
        let indentation = indent(first)
        var current: [String: String] = [:]
        func finish() throws {
            guard let name = current["name"], let type = current["type"], !name.isEmpty, !type.isEmpty,
                  type != "rematch" else { throw AppProxySettingsError.unsupportedRules }
            if ["direct", "reject", "reject-drop", "pass", "pass-rule", "compatible", "dns"].contains(type) {
                preserved.insert(name)
            }
        }
        for line in body {
            var value = line.trimmingCharacters(in: .whitespaces)
            if indent(line) == indentation {
                if !current.isEmpty { try finish() }
                current = [:]
                guard value.hasPrefix("- ") else { throw AppProxySettingsError.unsupportedRules }
                value = String(value.dropFirst(2))
            } else if indent(line) != indentation + 2 || value.hasPrefix("- ") { continue }
            guard let colon = colon(in: value) else { throw AppProxySettingsError.unsupportedRules }
            let key = try scalar(String(value[..<colon]))
            guard key != "<<" else { throw AppProxySettingsError.unsupportedRules }
            if key == "name" || key == "type" {
                guard current[key] == nil else { throw AppProxySettingsError.unsupportedRules }
                current[key] = try scalar(String(value[value.index(after: colon)...]))
            }
        }
        try finish()
        return preserved
    }

    private static func section(_ key: String, empty: String, lines: [String]) throws -> [String] {
        let starts = try lines.indices.filter { index in
            let line = lines[index]
            guard indent(line) == 0, !line.hasPrefix("#"), let colon = colon(in: line) else { return false }
            return try scalar(String(line[..<colon])) == key
        }
        guard starts.count <= 1 else { throw AppProxySettingsError.unsupportedRules }
        guard let start = starts.first, let colon = colon(in: lines[start]) else { return [] }
        let suffix = withoutComment(String(lines[start][lines[start].index(after: colon)...]))
        guard suffix.isEmpty || suffix == empty else { throw AppProxySettingsError.unsupportedRules }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if indent(line) == 0, !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("- ") { break }
            end += 1
        }
        let body = lines[(start + 1)..<end].filter { !withoutComment($0).isEmpty }
        guard suffix != empty || body.isEmpty else { throw AppProxySettingsError.unsupportedRules }
        return Array(body)
    }

    private static func sequence(_ lines: [String]) throws -> [String] {
        let indentation = lines.first.map(indent)
        return try lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard indent(line) == indentation, trimmed.hasPrefix("- ") else { throw AppProxySettingsError.unsupportedRules }
            return try scalar(String(trimmed.dropFirst(2)))
        }
    }

    private static func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

    private static func withoutComment(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { return "" }
        return String(value.components(separatedBy: " #")[0]).trimmingCharacters(in: .whitespaces)
    }

    private static func colon(in value: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let c = value[index]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let current = quote { if c == current { quote = nil } }
            else if c == "'" || c == "\"" { quote = c }
            else if c == ":" { return index }
        }
        return nil
    }

    private static func scalar(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { throw AppProxySettingsError.unsupportedRules }
        if first == "'" || first == "\"" {
            var index = value.index(after: value.startIndex)
            while index < value.endIndex {
                let c = value[index]
                let next = value.index(after: index)
                if first == "\"", c == "\\" {
                    guard next < value.endIndex else { break }
                    index = value.index(after: next); continue
                }
                if c == first {
                    if first == "'", next < value.endIndex, value[next] == "'" {
                        index = value.index(after: next); continue
                    }
                    guard withoutComment(String(value[next...])).isEmpty else { break }
                    if first == "'" { return String(value[value.index(after: value.startIndex)..<index]).replacingOccurrences(of: "''", with: "'") }
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value[...index].utf8)) else { break }
                    return decoded
                }
                index = next
            }
            throw AppProxySettingsError.unsupportedRules
        }
        guard !"*&!|>{}[],#?".contains(first), !value.contains(": "), !value.contains("\t") else {
            throw AppProxySettingsError.unsupportedRules
        }
        return withoutComment(value)
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
