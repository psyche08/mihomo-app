import Foundation

/// A profile-editor operation, not a second runtime or a controller hot patch.
/// The resulting YAML still goes through the bundled validator and the daemon's
/// existing profile activation/readback/rollback transaction.
public struct NetworkProfileSettings: Codable, Equatable, Sendable {
    public enum ApplicationMode: String, Codable, CaseIterable, Sendable {
        case profileRules, selectedOnly, bypassSelected
    }

    public var mixedPort: Int
    public var tunStack: String
    public var applicationMode: ApplicationMode
    public var applicationRoutingEnabled: Bool
    public var applicationPaths: [String]
    public var policy: String

    public init(mixedPort: Int = 7897, tunStack: String = "mixed",
                applicationMode: ApplicationMode = .profileRules,
                applicationPaths: [String] = [], policy: String = "PROXY",
                applicationRoutingEnabled: Bool? = nil) {
        self.mixedPort = mixedPort
        self.tunStack = tunStack
        self.applicationMode = applicationMode
        self.applicationRoutingEnabled = applicationRoutingEnabled ?? (applicationMode != .profileRules)
        self.applicationPaths = applicationPaths
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case mixedPort, tunStack, applicationMode, applicationRoutingEnabled, applicationPaths, policy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mixedPort = try values.decode(Int.self, forKey: .mixedPort)
        tunStack = try values.decode(String.self, forKey: .tunStack)
        applicationMode = try values.decode(ApplicationMode.self, forKey: .applicationMode)
        applicationRoutingEnabled = try values.decodeIfPresent(Bool.self, forKey: .applicationRoutingEnabled)
            ?? (applicationMode != .profileRules)
        applicationPaths = try values.decode([String].self, forKey: .applicationPaths)
        policy = try values.decode(String.self, forKey: .policy)
    }

    public var usesApplicationRules: Bool {
        applicationRoutingEnabled && applicationMode != .profileRules
    }

    public struct InvalidSettings: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let metadata = "# mihomobox-network: "
    private static let begin = "  # mihomobox-app-rules-begin"
    private static let end = "  # mihomobox-app-rules-end"

    public static func read(from source: String) throws -> Self {
        let lines = split(source)
        let metadataLines = lines.filter { $0.hasPrefix(metadata) }
        guard metadataLines.count <= 1 else {
            throw InvalidSettings("Duplicate MihomoBox network settings marker.")
        }
        var settings = Self()
        if let line = metadataLines.first {
            guard let data = String(line.dropFirst(metadata.count)).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
                throw InvalidSettings("Invalid MihomoBox network settings marker.")
            }
            settings = decoded
        }
        // YAML is authoritative for values users may have edited by hand.
        settings.mixedPort = ["mixed-port", "port", "socks-port"]
            .compactMap { scalar(lines, key: $0).flatMap(Int.init) }
            .first(where: { $0 > 0 }) ?? 7897
        if let range = try section(lines, key: "tun"),
           let line = lines[range].first(where: { $0.hasPrefix("  stack:") }) {
            settings.tunStack = MihomoConfigurator.parseScalar(String(line.dropFirst("  stack:".count))).lowercased()
        }
        return settings
    }

    public func applying(to source: String) throws -> String {
        guard (1024...65535).contains(mixedPort), ![1054, 1153].contains(mixedPort) else {
            throw InvalidSettings("Mixed port must be 1024–65535 and must not use DNS ports 1054 or 1153.")
        }
        guard ["mixed", "system", "gvisor"].contains(tunStack) else {
            throw InvalidSettings("Choose a supported TUN stack: mixed, system or gvisor.")
        }
        var lines = Self.split(source)
        try Self.validateEditableKeys(lines)
        let controllerPort = Self.scalar(lines, key: "external-controller")?
            .split(separator: ":").last.flatMap { Int($0) } ?? 9090
        let reserved = [controllerPort] + ["redir-port", "tproxy-port"]
            .compactMap { Self.scalar(lines, key: $0).flatMap(Int.init) }
        guard !reserved.contains(mixedPort) else {
            throw InvalidSettings("Mixed port conflicts with another listener in this profile.")
        }
        // Custom inbound listeners have independent bind addresses/ports. Do
        // not silently claim to unify them or introduce a duplicate listener.
        if try Self.section(lines, key: "listeners") != nil {
            throw InvalidSettings("This profile uses custom listeners. Edit its ports in YAML instead.")
        }
        let paths = Array(Set(applicationPaths)).sorted()
        if usesApplicationRules {
            guard !paths.isEmpty, paths.count <= 128 else {
                throw InvalidSettings("Choose between 1 and 128 application bundles.")
            }
            for path in paths {
                guard path.hasPrefix("/"), path.hasSuffix(".app"),
                      (path as NSString).standardizingPath == path,
                      path.utf8.count <= 4096,
                      !path.contains(","),
                      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw InvalidSettings("Use absolute .app bundle paths without commas or control characters.")
                }
            }
            guard !policy.isEmpty, policy.utf8.count <= 256,
                  policy == policy.trimmingCharacters(in: .whitespacesAndNewlines),
                  !policy.contains(","),
                  !policy.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw InvalidSettings("Enter an existing proxy or policy group name without commas or control characters.")
            }
        }
        let starts = lines.indices.filter { lines[$0] == Self.begin }
        let ends = lines.indices.filter { lines[$0] == Self.end }
        guard starts.count == ends.count, starts.count <= 1 else {
            throw InvalidSettings("Incomplete or duplicate managed application rules block.")
        }
        if let start = starts.first, let end = ends.first {
            guard start < end, let rules = try Self.section(lines, key: "rules"),
                  rules.contains(start), rules.contains(end) else {
                throw InvalidSettings("Managed application rules must be inside rules:.")
            }
            lines.removeSubrange(start...end)
        }
        lines.removeAll { $0.hasPrefix(Self.metadata) }
        Self.setScalar(&lines, key: "mixed-port", value: String(mixedPort))
        Self.setScalar(&lines, key: "port", value: "0")
        Self.setScalar(&lines, key: "socks-port", value: "0")
        guard let tun = try Self.section(lines, key: "tun") else {
            throw InvalidSettings("A block-style tun: section is required.")
        }
        let stackIndices = tun.filter { lines[$0].hasPrefix("  stack:") }
        guard stackIndices.count <= 1 else { throw InvalidSettings("Duplicate TUN stack.") }
        if let index = stackIndices.first { lines[index] = "  stack: \(tunStack)" }
        else { lines.insert("  stack: \(tunStack)", at: tun.lowerBound + 1) }

        if usesApplicationRules {
            Self.setScalar(&lines, key: "find-process-mode", value: "always")
            Self.setScalar(&lines, key: "mode", value: "rule")
            guard let rules = try Self.section(lines, key: "rules") else {
                throw InvalidSettings("A block-style rules: section is required.")
            }
            var generated = [Self.begin]
            for path in paths {
                // Escape for Go/RE2, then quote the whole YAML scalar. Matching
                // a bundle prefix also includes its nested helper apps.
                let pattern = "^" + Self.escapeRegex(path) + "/"
                let target = applicationMode == .bypassSelected ? "DIRECT" : policy
                generated.append("  - " + Self.quote("PROCESS-PATH-REGEX,\(pattern),\(target)"))
                if applicationMode == .selectedOnly {
                    // Mihomo falls through when a proxy cannot relay UDP.
                    // Never let a selected app fall into MATCH,DIRECT then.
                    generated.append("  - " + Self.quote("PROCESS-PATH-REGEX,\(pattern),REJECT"))
                }
            }
            if applicationMode == .selectedOnly { generated.append("  - MATCH,DIRECT") }
            generated.append(Self.end)
            // Use the existing sequence indentation (YAML permits zero).
            let indent = lines[rules].dropFirst().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }?
                .prefix(while: { $0 == " " }).count ?? 2
            generated = generated.map { line in
                line.hasPrefix("  - ") ? String(repeating: " ", count: indent) + line.dropFirst(2) : line
            }
            lines.insert(contentsOf: generated, at: rules.lowerBound + 1)
        }
        var normalized = self
        normalized.applicationPaths = paths
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        lines.insert(Self.metadata + String(decoding: try encoder.encode(normalized), as: UTF8.self), at: 0)
        return lines.joined(separator: "\n")
    }

    private static func escapeRegex(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\.+*?()|[]{}^$".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func split(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    private static func scalar(_ lines: [String], key: String) -> String? {
        lines.first(where: { $0.hasPrefix(key + ":") })
            .map { MihomoConfigurator.parseScalar(String($0.dropFirst(key.count + 1))) }
    }

    private static func setScalar(_ lines: inout [String], key: String, value: String) {
        if let index = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[index] = "\(key): \(value)"
        } else {
            // A document start must remain before any mapping entries.
            let index = lines.firstIndex(of: "---").map { $0 + 1 } ?? 0
            lines.insert("\(key): \(value)", at: index)
        }
    }

    private static func section(_ lines: [String], key: String) throws -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let tail = lines[start].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else {
            throw InvalidSettings("Use block-style \(key): in the YAML editor before changing network settings.")
        }
        let end = lines.indices.dropFirst(start + 1).first { index in
            let line = lines[index]
            return !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.hasPrefix("#") && !line.hasPrefix("- ")
        } ?? lines.endIndex
        return start..<end
    }

    private static func validateEditableKeys(_ lines: [String]) throws {
        let keys: Set<String> = ["mixed-port", "port", "socks-port", "mode", "find-process-mode",
                                 "tun", "rules", "listeners", "external-controller", "redir-port", "tproxy-port"]
        var seen = Set<String>()
        for line in lines {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let raw = String(line[..<colon])
            let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if key == "<<" { throw InvalidSettings("Edit YAML merge-based profiles directly.") }
            guard keys.contains(key) else { continue }
            guard raw == key, seen.insert(key).inserted else {
                throw InvalidSettings("Use one unquoted \(key): key before changing network settings.")
            }
        }
        guard lines.filter({ $0 == "---" }).count <= 1, !lines.contains("...") else {
            throw InvalidSettings("Use a single YAML document without an explicit end marker.")
        }
        if let tun = try section(lines, key: "tun") {
            for line in lines[tun].dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if key == "<<" { throw InvalidSettings("Edit YAML merge-based TUN sections directly.") }
                guard key == "stack" else { continue }
                guard line.hasPrefix("  stack:"), scalarValueIsSimple(line) else {
                    throw InvalidSettings("Use a two-space indented stack: scalar in tun:.")
                }
            }
        }
    }

    private static func scalarValueIsSimple(_ line: String) -> Bool {
        !line.contains("&") && !line.contains("*") && !line.contains("|") && !line.contains(">")
    }
}
