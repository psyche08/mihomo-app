import Foundation
import Darwin

/// Shared by the signed client and extension. This matches numeric destinations
/// only; it never resolves a hostname or learns routes from a default gateway.
public struct AppProxyBypassPolicy: Codable, Equatable, Sendable {
    public static let defaultCIDRs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                     "169.254.0.0/16", "fc00::/7", "fe80::/10"]
    public var cidrs: [String]
    public init(cidrs: [String] = Self.defaultCIDRs) { self.cidrs = cidrs }
    public struct Invalid: LocalizedError {
        public var errorDescription: String? {
            "Enter up to 64 unique IPv4/IPv6 CIDRs. Default routes and the Mihomo Fake-IP range cannot be bypassed."
        }
    }
    public func validate() throws {
        guard cidrs.count <= 64, Set(cidrs).count == cidrs.count,
              cidrs.allSatisfy({ text in
                  guard let range = Range(text), range.prefix > 0 else { return false }
                  return !range.overlaps(Range("198.18.0.0/15")!)
              }) else { throw Invalid() }
    }
    public func contains(_ host: String) -> Bool {
        guard let address = Self.address(host, allowScope: true) else { return false }
        // The built-in Fake-IP/DNS range must always stay with Mihomo.
        guard !Range("198.18.0.0/15")!.contains(address) else { return false }
        return cidrs.contains { Range($0)?.contains(address) == true }
    }
    public func overlaps(_ cidr: String) -> Bool {
        guard let range = Range(cidr) else { return false }
        return cidrs.contains { Range($0)?.overlaps(range) == true }
    }
    private struct Range {
        let bytes: [UInt8]
        let prefix: Int
        init?(_ text: String) {
            let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, text.utf8.count <= 64,
                  pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let prefix = Int(pieces[1]),
                  let bytes = AppProxyBypassPolicy.address(String(pieces[0]), allowScope: false),
                  prefix >= 0, prefix <= bytes.count * 8 else { return nil }
            // IPv4-mapped IPv6 ranges are ambiguous after normalization.
            guard !pieces[0].contains(":") || bytes.count == 16 else { return nil }
            self.bytes = bytes; self.prefix = prefix
        }
        func contains(_ address: [UInt8]) -> Bool {
            guard bytes.count == address.count else { return false }
            for i in 0..<bytes.count {
                let bits = min(8, max(0, prefix - i * 8))
                let mask: UInt8 = bits == 0 ? 0 : UInt8(255 << (8 - bits) & 255)
                if bytes[i] & mask != address[i] & mask { return false }
            }
            return true
        }
        func overlaps(_ other: Range) -> Bool {
            prefix <= other.prefix ? contains(other.bytes) : other.contains(bytes)
        }
    }
    private static func address(_ text: String, allowScope: Bool) -> [UInt8]? {
        guard !text.isEmpty, text.utf8.count <= 128 else { return nil }
        var host = text
        if allowScope, let percent = host.firstIndex(of: "%") {
            let scope = host[host.index(after: percent)...]
            guard host.contains(":"), !scope.isEmpty,
                  scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            host = String(host[..<percent])
        }
        guard host.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF:.".unicodeScalars.contains($0) }) else { return nil }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return Array(bytes.suffix(4))
        }
        return bytes
    }
}
