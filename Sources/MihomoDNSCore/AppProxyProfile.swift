import Foundation
import MihomoControl

/// Root-owned runtime overlay. Raw subscription/profile bytes are never changed.
public enum AppProxyProfile {
    public static func applying(_ settings: AppProxySettings, to source: String) throws -> String {
        try settings.validate()
        guard !settings.routes.isEmpty else { return source }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Custom Fake-IP ranges must never become direct network destinations.
        // Check before the daemon commits the profile/settings transaction.
        var inDNS = false
        for line in lines {
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") {
                inDNS = line.hasPrefix("dns:") || line.hasPrefix("'dns':") || line.hasPrefix("\"dns\":")
            }
            guard inDNS, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if ["fake-ip-range", "fake-ip-range6"].contains(key),
               settings.bypass.overlaps(MihomoConfigurator.parseScalar(String(line[line.index(after: colon)...]))) {
                throw AppProxySettingsError.overlappingFakeIP
            }
        }
        guard lines.filter({ $0 == "---" }).count <= 1, !lines.contains("..."),
              !lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.contains("mihomobox-app-") }),
              !lines.contains(where: { line in
                  guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                        let colon = line.firstIndex(of: ":") else { return false }
                  let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                  return key == "listeners" || key == "<<" || line.hasPrefix("{")
              }),
              // Deliberately conservative for custom ports/ranges. The core
              // validator remains authoritative for the complete YAML.
              !lines.contains(where: { line in
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && line.contains("port") && settings.applications.contains { line.contains(String($0.port)) }
              }) else { throw AppProxySettingsError.unsupportedProfile }
        // Listener `proxy` is an unconditional core override, even in Direct
        // mode. Rule-only sub-rules leave Global/Direct to Mihomo itself.
        var subRules: [String] = []
        var groups: [String] = []
        var result = lines.joined(separator: "\n")
        let ruleOverlay = try AppProxyRuleOverlay(source: result)
        for app in settings.applications {
            let name = "mihomobox-app-\(app.id)"
            let quoted = String(decoding: try JSONEncoder().encode(settings.routes[app.id]!), as: UTF8.self)
            // A private selector keeps commas and other rule delimiters in a
            // user node name out of Mihomo's comma-delimited rule grammar.
            groups += ["  - name: \(name)", "    type: select", "    hidden: true", "    proxies: [\(quoted)]"]
            subRules += try ruleOverlay.entries(for: name)
        }
        result = try inserting(groups, into: "proxy-groups", emptyValue: "[]", source: result)
        result = try inserting(subRules, into: "sub-rules", emptyValue: "{}", source: result)
        // Verified executables of each app also follow its sub-rules when they reach Mihomo
        // outside App Proxy (system proxy, TUN). The paths live in a file provider so they
        // change without restarting Mihomo; a provider holds at most one app's paths.
        result = try inserting(settings.applications.flatMap { app in
            ["  \(processProviderName(app.id)):", "    type: file", "    behavior: classical", "    format: yaml",
             "    path: ./\(processProviderPath(app.id))"]
        }, into: "rule-providers", emptyValue: "{}", source: result)
        result = try prepending(settings.applications.map { app in
            "  - SUB-RULE,(AND,((RULE-SET,\(processProviderName(app.id))))),mihomobox-app-\(app.id)"
        }, intoRules: result)
        result += "\n# MihomoBox App Proxy runtime overlay\nlisteners:\n"
        for app in settings.applications {
            result += "  - name: mihomobox-app-\(app.id)\n    type: mixed\n    listen: 127.0.0.1\n    port: \(app.port)\n    udp: true\n    rule: mihomobox-app-\(app.id)\n"
        }
        return result
    }

    public static func processProviderName(_ id: String) -> String { "mihomobox-app-\(id)-processes" }
    /// Relative to Mihomo's home directory.
    public static func processProviderPath(_ id: String) -> String { "mihomobox/app-\(id)-processes.yaml" }
    public static func processProviderContents(_ paths: [String]) throws -> String {
        guard paths.allSatisfy(AppProxyProcessRoutes.isRoutable) else { throw AppProxySettingsError.invalidExecutables }
        guard !paths.isEmpty else { return "payload: []\n" }
        // JSON string literals are valid YAML double-quoted scalars.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let lines = try paths.sorted().map { path in
            "  - " + String(decoding: try encoder.encode("PROCESS-PATH," + path), as: UTF8.self)
        }
        return (["payload:"] + lines).joined(separator: "\n") + "\n"
    }

    /// Inserts rules first, ahead of the profile's own rules.
    private static func prepending(_ entries: [String], intoRules source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let indices = lines.indices.filter { index in
            let line = lines[index]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) == "rules"
        }
        guard indices.count <= 1 else { throw AppProxySettingsError.unsupportedProfile }
        guard let index = indices.first else { return source + "\nrules:\n" + entries.joined(separator: "\n") + "\n" }
        let suffix = String(lines[index][lines[index].index(after: lines[index].firstIndex(of: ":")!)...])
            .trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") || suffix == "[]" else { throw AppProxySettingsError.unsupportedProfile }
        lines[index] = "rules:"
        let content = lines[(index + 1)...].first { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !value.hasPrefix("#")
        }
        let indentation = content.flatMap { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") ? String($0.prefix(while: { $0 == " " })) : nil } ?? "  "
        lines.insert(contentsOf: entries.map { indentation + $0.dropFirst(2) }, at: index + 1)
        return lines.joined(separator: "\n")
    }

    private static func inserting(_ entries: [String], into key: String, emptyValue: String, source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let indices = lines.indices.filter { index in
            let line = lines[index]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) == key
        }
        guard indices.count <= 1 else { throw AppProxySettingsError.unsupportedProfile }
        if let index = indices.first {
            let line = lines[index]
            let suffix = String(line[line.index(after: line.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces)
            guard suffix.isEmpty || suffix.hasPrefix("#") || suffix == emptyValue else { throw AppProxySettingsError.unsupportedProfile }
            lines[index] = "\(key):"
            // Support both indented and indentationless block sequences.
            var end = index + 1
            while end < lines.count {
                let next = lines[end]
                if !next.isEmpty, !next.hasPrefix(" "), !next.hasPrefix("\t"), !next.hasPrefix("#"), !next.hasPrefix("-") { break }
                end += 1
            }
            let content = lines[(index + 1)..<end].first { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                return !value.isEmpty && !value.hasPrefix("#")
            }
            let indentation = content.map { String($0.prefix(while: { $0 == " " })) } ?? "  "
            lines.insert(contentsOf: entries.map { indentation + $0.dropFirst(2) }, at: end)
            return lines.joined(separator: "\n")
        }
        return source + "\n\(key):\n" + entries.joined(separator: "\n") + "\n"
    }
}
