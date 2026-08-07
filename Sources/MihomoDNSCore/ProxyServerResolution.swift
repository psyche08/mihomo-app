import CMihomoDNSSystem
import Darwin
import Foundation

/// Detects the configuration fault where the address a proxy server resolves to
/// is routed back into the tunnel.
///
/// The kernel must dial its proxy server over the physical network. With
/// auto-route installing a default route through the tunnel, that only works if
/// the server's own address is excluded from it. When it is not, the dial is
/// sent into the tunnel that the dial exists to establish, and every proxied
/// connection hangs while the machine looks perfectly healthy: the interface is
/// up, DNS answers, direct traffic works, and only the traffic that matters
/// silently stops.
///
/// Both layers can produce that address, so both are checked from the outcome
/// rather than by reimplementing the kernel's rules: the name is resolved the
/// way the kernel resolves proxy servers, and the routing table is asked where
/// that address goes.
public enum ProxyServerResolution {
    public struct Finding: Equatable, Sendable {
        public let host: String
        public let address: String
        /// The interface the dial would take — the tunnel, which is the fault.
        public let interface: String
    }

    /// Hostnames under `proxies:` in a Mihomo configuration.
    ///
    /// Line-scanned to match how the rest of this file is read, and because
    /// only the `server:` keys inside that one block matter here.
    public static func serverHosts(configPath: String) -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        var inProxies = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), trimmed.hasSuffix(":") {
                inProxies = trimmed == "proxies:"
                continue
            }
            guard inProxies, trimmed.hasPrefix("server:") else { continue }
            let value = trimmed
                .dropFirst("server:".count)
                .split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
            guard !value.isEmpty, value.contains(".") else { continue }
            if !hosts.contains(value) { hosts.append(value) }
        }
        return hosts
    }

    /// Servers whose dial address routes into `tunnelInterface`.
    ///
    /// - Parameter resolver: the escape resolver, which answers with real
    ///   addresses rather than Fake-IP ones — the same path the kernel uses to
    ///   resolve its own proxy servers.
    public static func loopingServers(
        configPath: String,
        resolver: Endpoint,
        tunnelInterface: String?,
        timeoutMilliseconds: Int = 2_000
    ) -> [Finding] {
        guard let tunnelInterface, !tunnelInterface.isEmpty else { return [] }
        var findings: [Finding] = []
        for host in serverHosts(configPath: configPath) {
            guard let address = dialAddress(
                host: host,
                resolver: resolver,
                timeoutMilliseconds: timeoutMilliseconds
            ) else { continue }
            guard let interface = routeInterface(for: address), interface == tunnelInterface else {
                continue
            }
            findings.append(Finding(host: host, address: address, interface: interface))
        }
        return findings
    }

    /// The address the kernel would dial: the literal one when the server is
    /// already an address, otherwise whatever the escape resolver answers.
    private static func dialAddress(
        host: String,
        resolver: Endpoint,
        timeoutMilliseconds: Int
    ) -> String? {
        if isIPv4(host) { return host }
        guard let query = DNSMessage.addressQuery(for: host),
              let response = try? SocketDNSClient.query(
                  query,
                  endpoint: resolver,
                  timeoutMilliseconds: timeoutMilliseconds,
                  interfaceName: nil
              ) else {
            return nil
        }
        return DNSMessage.firstIPv4Answer(response)
    }

    static func routeInterface(for address: String) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard mihomo_dns_route_interface(address, &name, name.count) == 0 else { return nil }
        let interface = String(cString: name)
        return interface.isEmpty ? nil : interface
    }

    static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { Int($0).map { (0 ... 255).contains($0) } ?? false }
    }
}
