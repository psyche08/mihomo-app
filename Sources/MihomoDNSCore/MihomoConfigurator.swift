import Foundation

/// Rewrites the managed keys of a Mihomo profile.
///
/// This was a Python script staged beside the daemon, which meant it sat
/// outside the set of components an update replaces: a release could ship a fix
/// here and no existing installation would ever receive it, because only the
/// three signed binaries are updated in place. Living inside the agent puts it
/// on the same delivery path as everything else and removes the interpreter
/// from a root-owned code path at the same time.
///
/// Only the keys listed here are touched. A profile is otherwise the user's
/// document, and the backup taken on first apply is what `restore` puts back.
public enum MihomoConfigurator {
    public enum ConfiguratorError: Error, LocalizedError, Equatable {
        case blockNotFound(String)
        case tunDisabled
        case invalidController(String)
        case invalidSecret
        case backupMissing
        case daemonConfigUnreadable

        public var errorDescription: String? {
            switch self {
            case .blockNotFound(let name): return "top-level \(name): block not found"
            case .tunDisabled: return "managed system DNS requires tun.enable: true"
            case .invalidController(let reason): return "external-controller \(reason)"
            case .invalidSecret: return "controller secret is invalid"
            case .backupMissing: return "no backup to restore"
            case .daemonConfigUnreadable: return "daemon configuration is missing or unreadable"
            }
        }
    }

    static let managedScalars: [(String, String)] = [
        ("listen", "127.0.0.1:1153"),
        ("respect-rules", "false"),
        ("fake-ip-ttl", "1"),
    ]

    static let managedLists: [(String, String)] = [
        ("nameserver", "tcp://127.0.0.1:1054"),
        ("direct-nameserver", "tcp://127.0.0.1:1054"),
        ("proxy-server-nameserver", "tcp://127.0.0.1:1054"),
    ]

    public struct Paths {
        public var config: String
        public var backup: String
        public var secretFile: String?
        public var controllerMetadata: String?
        public var daemonConfig: String?

        public init(
            config: String,
            backup: String,
            secretFile: String? = nil,
            controllerMetadata: String? = nil,
            daemonConfig: String? = nil
        ) {
            self.config = config
            self.backup = backup
            self.secretFile = secretFile
            self.controllerMetadata = controllerMetadata
            self.daemonConfig = daemonConfig
        }
    }

    public static func apply(_ paths: Paths, resolver: ProxyServerAddressResolving? = nil) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: paths.backup) {
            try manager.createDirectory(
                at: URL(fileURLWithPath: paths.backup).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.copyItem(atPath: paths.config, toPath: paths.backup)
        }

        var lines = try String(contentsOfFile: paths.config, encoding: .utf8).keepingLines()
        let controller = try normalizeController(topLevelScalar(lines, "external-controller"))
        let secret = try resolveSecret(topLevelScalar(lines, "secret"), secretFile: paths.secretFile)

        let (dnsStart, dnsEnd) = try block(lines, named: "dns")
        var dns = Array(lines[(dnsStart + 1) ..< dnsEnd])
        for (key, value) in managedScalars { dns = replaceScalar(dns, key: key, value: value) }
        for (key, value) in managedLists { dns = replaceList(dns, key: key, values: [value]) }
        lines = Array(lines[...dnsStart]) + dns + Array(lines[dnsEnd...])

        lines = replaceTopLevelScalar(lines, key: "external-controller", value: "\(controller.host):\(controller.port)")
        lines = replaceTopLevelScalar(lines, key: "secret", value: jsonQuoted(secret))
        // The kernel emits an enormous amount at warning — a week of field logs
        // held 1.82M warning lines against 8.5K errors — which buried the
        // errors and cost continuous disk writes for output nobody reads.
        lines = replaceTopLevelScalar(lines, key: "log-level", value: "error")

        guard directScalar(lines, section: "tun", key: "enable") == "true" else {
            throw ConfiguratorError.tunDisabled
        }
        lines = excludeProxyServersFromTunnel(lines, resolver: resolver)

        try lines.joined().write(toFile: paths.config, atomically: true, encoding: .utf8)
        try persistController(controller, secret: secret, paths: paths)
    }

    public static func restore(config: String, backup: String) throws {
        guard FileManager.default.fileExists(atPath: backup) else {
            throw ConfiguratorError.backupMissing
        }
        let contents = try String(contentsOfFile: backup, encoding: .utf8)
        try contents.write(toFile: config, atomically: true, encoding: .utf8)
    }

    // MARK: - Tunnel exclusion

    /// Keeps the tunnel from swallowing the kernel's own outbound dials.
    ///
    /// `auto-route` installs a default route through the tunnel, and the kernel
    /// still has to reach its proxy server over the physical network. When the
    /// server's address is inside that route, the dial is sent into the tunnel
    /// it exists to establish and every proxied connection hangs, while the
    /// interface stays up, DNS answers and direct traffic works.
    ///
    /// The hostname stays in `server:` — TLS uses it for SNI and certificate
    /// validation — and the addresses are re-resolved on every apply, because
    /// these servers are often DDNS-backed and a pinned address goes stale as
    /// exactly the outage it was meant to prevent.
    static func excludeProxyServersFromTunnel(
        _ lines: [String],
        resolver: ProxyServerAddressResolving?
    ) -> [String] {
        let hosts = serverHosts(lines)
        guard !hosts.isEmpty else { return lines }
        let resolver = resolver ?? EscapeResolver()
        let excluded = fakeIPPrefix(lines)
        var addresses: [String] = []
        for host in hosts {
            for address in resolver.addresses(for: host) {
                if let excluded, address.hasPrefix(excluded) { continue }
                if !addresses.contains(address) { addresses.append(address) }
            }
        }
        // Resolution fails transiently. A stale but correct exclusion from a
        // previous apply is worth more than an empty one.
        guard !addresses.isEmpty else { return lines }
        let entries = addresses.map { "    - \($0)/32\n" }
        return replaceTunList(lines, key: "route-exclude-address", entries: entries)
    }

    static func serverHosts(_ lines: [String]) -> [String] {
        var hosts: [String] = []
        var inProxies = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = line.first, first != " ", first != "\t", trimmed.hasSuffix(":") {
                inProxies = trimmed == "proxies:"
                continue
            }
            guard inProxies, trimmed.hasPrefix("server:") else { continue }
            let value = parseScalar(String(trimmed.dropFirst("server:".count)))
            if !value.isEmpty, !hosts.contains(value) { hosts.append(value) }
        }
        return hosts
    }

    /// Leading octets of the Fake-IP range, for rejecting synthetic answers.
    static func fakeIPPrefix(_ lines: [String]) -> String? {
        let value = directScalar(lines, section: "dns", key: "fake-ip-range") ?? "198.18.0.1/16"
        let parts = value.split(separator: "/")
        guard let address = parts.first else { return nil }
        let octets = address.split(separator: ".")
        guard octets.count == 4 else { return nil }
        let bits = parts.count == 2 ? Int(parts[1]) ?? 16 : 16
        switch bits {
        case 8: return "\(octets[0])."
        case 24: return "\(octets[0]).\(octets[1]).\(octets[2])."
        default: return "\(octets[0]).\(octets[1])."
        }
    }

    static func replaceTunList(_ lines: [String], key: String, entries: [String]) -> [String] {
        guard let (start, end) = try? block(lines, named: "tun") else { return lines }
        var tun = Array(lines[(start + 1) ..< end])
        let replacement = ["  \(key):\n"] + entries
        if let range = keyRange(tun, key: key) {
            tun = Array(tun[..<range.lowerBound]) + replacement + Array(tun[range.upperBound...])
        } else {
            tun = terminated(tun) + replacement
        }
        return Array(lines[...start]) + tun + Array(lines[end...])
    }

    // MARK: - Controller

    static func normalizeController(_ value: String?) throws -> (host: String, port: Int) {
        var candidate = (value ?? "127.0.0.1:9090").trimmingCharacters(in: .whitespaces)
        if let separator = candidate.range(of: "://") {
            candidate = String(candidate[separator.upperBound...])
        }
        while candidate.hasSuffix("/") { candidate.removeLast() }
        guard let colon = candidate.lastIndex(of: ":") else {
            throw ConfiguratorError.invalidController("must include a valid TCP port")
        }
        guard let port = Int(candidate[candidate.index(after: colon)...]), (1 ... 65_535).contains(port) else {
            throw ConfiguratorError.invalidController("port must be in 1...65535")
        }
        let host = String(candidate[..<colon]).lowercased()
        guard ["127.0.0.1", "localhost", "0.0.0.0"].contains(host) else {
            throw ConfiguratorError.invalidController("must be bound to loopback")
        }
        return ("127.0.0.1", port)
    }

    static func resolveSecret(_ profileSecret: String?, secretFile: String?) throws -> String {
        var secret = profileSecret ?? ""
        if secret.isEmpty, let secretFile,
           let stored = try? String(contentsOfFile: secretFile, encoding: .utf8) {
            secret = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if secret.isEmpty {
            secret = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
        }
        guard secret.count <= 256, secret.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfiguratorError.invalidSecret
        }
        return secret
    }

    private static func persistController(
        _ controller: (host: String, port: Int),
        secret: String,
        paths: Paths
    ) throws {
        if let secretFile = paths.secretFile {
            try write("\(secret)\n", to: secretFile, mode: 0o600)
        }
        if let metadataPath = paths.controllerMetadata {
            let metadata: [String: Any] = [
                "url": "http://\(controller.host):\(controller.port)",
                "secret": secret,
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try write(String(decoding: data, as: UTF8.self) + "\n", to: metadataPath, mode: 0o600)
        }
        if let daemonConfigPath = paths.daemonConfig {
            // Skipping this silently would leave the daemon authenticating with
            // the previous secret while the profile carries a new one, which
            // presents as an unreachable controller with nothing logged.
            guard let existing = FileManager.default.contents(atPath: daemonConfigPath),
                  var object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw ConfiguratorError.daemonConfigUnreadable
            }
            object["controllerEndpoint"] = ["host": controller.host, "port": controller.port]
            object["controllerSecret"] = secret
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try write(String(decoding: data, as: UTF8.self) + "\n", to: daemonConfigPath, mode: 0o600)
        }
    }

    private static func write(_ contents: String, to path: String, mode: Int) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    // MARK: - YAML line editing

    static func block(_ lines: [String], named name: String) throws -> (Int, Int) {
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A commented-out header is not a block. Stripping the comment
            // first would turn "# dns:" into "dns:" and hijack the real block —
            // profiles carrying a commented DNS example above the live one are
            // common, and the managed keys would land inside the comment.
            guard !trimmed.hasPrefix("#") else { return false }
            let withoutComment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
            return withoutComment.trimmingCharacters(in: .whitespaces) == "\(name):"
                && !line.hasPrefix(" ") && !line.hasPrefix("\t")
        }) else {
            throw ConfiguratorError.blockNotFound(name)
        }
        var end = lines.count
        for index in (start + 1) ..< lines.count {
            let line = lines[index]
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") {
                end = index
                break
            }
        }
        return (start, end)
    }

    static func keyRange(_ block: [String], key: String) -> Range<Int>? {
        guard let start = block.firstIndex(where: { $0.hasPrefix("  \(key):") || $0.hasPrefix("  \(key) :") })
        else { return nil }
        var end = start + 1
        while end < block.count {
            let line = block[end]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = line.prefix(while: { $0 == " " }).count
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent <= 2 { break }
            end += 1
        }
        return start ..< end
    }

    /// A document whose last line has no newline would otherwise have the
    /// appended key glued onto it, producing invalid YAML.
    static func terminated(_ block: [String]) -> [String] {
        guard let last = block.last, !last.hasSuffix("\n"), !last.hasSuffix("\r") else { return block }
        return block.dropLast() + [last + "\n"]
    }

    static func replaceScalar(_ block: [String], key: String, value: String) -> [String] {
        let replacement = ["  \(key): \(value)\n"]
        guard let range = keyRange(block, key: key) else { return terminated(block) + replacement }
        return Array(block[..<range.lowerBound]) + replacement + Array(block[range.upperBound...])
    }

    static func replaceList(_ block: [String], key: String, values: [String]) -> [String] {
        let replacement = ["  \(key):\n"] + values.map { "    - \($0)\n" }
        guard let range = keyRange(block, key: key) else { return terminated(block) + replacement }
        return Array(block[..<range.lowerBound]) + replacement + Array(block[range.upperBound...])
    }

    static func replaceTopLevelScalar(_ lines: [String], key: String, value: String) -> [String] {
        let replacement = "\(key): \(value)\n"
        guard let index = lines.firstIndex(where: { $0.hasPrefix("\(key):") || $0.hasPrefix("\(key) :") })
        else { return [replacement] + lines }
        return Array(lines[..<index]) + [replacement] + Array(lines[(index + 1)...])
    }

    static func topLevelScalar(_ lines: [String], _ key: String) -> String? {
        for line in lines where line.hasPrefix("\(key):") || line.hasPrefix("\(key) :") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            return parseScalar(String(line[line.index(after: colon)...]))
        }
        return nil
    }

    static func directScalar(_ lines: [String], section: String, key: String) -> String? {
        guard let (start, end) = try? block(lines, named: section) else { return nil }
        for line in lines[(start + 1) ..< end] {
            guard line.hasPrefix("  \(key):") || line.hasPrefix("  \(key) :"),
                  let colon = line.firstIndex(of: ":") else { continue }
            return parseScalar(String(line[line.index(after: colon)...])).lowercased()
        }
        return nil
    }

    /// A YAML scalar, stripped of quotes and any trailing comment.
    ///
    /// This must be the exact inverse of `jsonQuoted`. It is what reads back a
    /// value this code previously wrote — most importantly the controller
    /// secret, which `apply` re-reads and re-writes on every run. A reader that
    /// does not round-trip silently rewrites the secret each time, so anything
    /// already authenticating with it stops working, and the damage compounds:
    /// a truncating reader kept doubling the backslashes until the value blew
    /// past the length limit and the installer refused to run at all.
    static func parseScalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("#") { return "" }
        if value.hasPrefix("\"") {
            if let decoded = decodeDoubleQuoted(value) { return decoded }
        }
        if value.hasPrefix("'") {
            if let decoded = decodeSingleQuoted(value) { return decoded }
        }
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes a double-quoted scalar as JSON, the way it was encoded. Handles
    /// the escapes YAML shares with JSON and stops at the closing quote, so a
    /// trailing comment is ignored rather than swallowed.
    private static func decodeDoubleQuoted(_ value: String) -> String? {
        var scalars = Array(value)
        var index = 1
        var escaped = false
        while index < scalars.count {
            let character = scalars[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { break }
            index += 1
        }
        guard index < scalars.count else { return nil }
        let token = String(scalars[0 ... index])
        guard let data = "[\(token)]".data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let text = array.first as? String else {
            return nil
        }
        return text
    }

    /// Decodes a single-quoted scalar, where a doubled quote is a literal one.
    private static func decodeSingleQuoted(_ value: String) -> String? {
        var result = ""
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if character == "'" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == "'" {
                    result.append("'")
                    index = value.index(after: next)
                    continue
                }
                return result
            }
            result.append(character)
            index = value.index(after: index)
        }
        return nil
    }

    private static func jsonQuoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
        return String(text.dropFirst().dropLast())
    }
}

/// Resolves a proxy server hostname to the addresses the kernel would dial.
public protocol ProxyServerAddressResolving {
    func addresses(for host: String) -> [String]
}

/// Resolves through the agent's original-DNS escape, falling back to the system
/// resolver only when that is not listening.
///
/// The system resolver is the wrong tool by default: once the agent owns system
/// DNS it answers from Fake-IP, and a Fake-IP address in the tunnel's exclusion
/// list is worse than none — it excludes an address the kernel never dials
/// while leaving the real one captured. During a first install the escape is
/// not listening, but nothing owns system DNS then either, so the fallback is
/// safe exactly when it is used.
public struct EscapeResolver: ProxyServerAddressResolving {
    public let endpoint: Endpoint
    public let timeoutMilliseconds: Int

    public init(
        endpoint: Endpoint = Endpoint(host: "127.0.0.1", port: 1054),
        timeoutMilliseconds: Int = 2_000
    ) {
        self.endpoint = endpoint
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func addresses(for host: String) -> [String] {
        if ProxyServerResolution.isIPv4(host) { return [host] }
        if let query = DNSMessage.addressQuery(for: host),
           let response = try? SocketDNSClient.query(
               query,
               endpoint: endpoint,
               timeoutMilliseconds: timeoutMilliseconds,
               interfaceName: nil
           ),
           case let answers = DNSMessage.ipv4Answers(response), !answers.isEmpty {
            return answers
        }
        return systemAddresses(for: host)
    }

    private func systemAddresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(head) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                entry.pointee.ai_addr,
                entry.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: buffer)
                if !address.isEmpty, !addresses.contains(address) { addresses.append(address) }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}

private extension String {
    /// Splits into lines while keeping the terminators, so rewriting preserves
    /// the rest of the document byte for byte.
    ///
    /// Iterates unicode scalars rather than Characters: Swift treats "\r\n" as a
    /// single grapheme, so a Character loop never sees the newline and a CRLF
    /// profile collapses into one enormous line that parses as nothing at all.
    func keepingLines() -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var scalars = Array(unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            current.append(scalar)
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "\r" {
                // A lone CR also terminates; CRLF keeps both bytes together.
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    current.append(scalars[index + 1])
                    index += 1
                }
                lines.append(String(current))
                current = String.UnicodeScalarView()
            }
            index += 1
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }
}
