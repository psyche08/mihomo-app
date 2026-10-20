import Foundation
import Darwin

// SOCKS5 CONNECT framing. Preserve numeric destinations without inventing DNS names.
enum SOCKSConnect {
    static func request(host: String, port: UInt16) -> Data? {
        guard port > 0 else { return nil }
        let suffix = [UInt8(port >> 8), UInt8(port & 255)]
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return Data([5, 1, 0, 1]) + withUnsafeBytes(of: &v4) { Data($0) } + Data(suffix)
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return Data([5, 1, 0, 4]) + withUnsafeBytes(of: &v6) { Data($0) } + Data(suffix)
        }
        let normalized = host.lowercased().hasSuffix(".") ? String(host.lowercased().dropLast()) : host.lowercased()
        let bytes = Array(normalized.utf8)
        guard !bytes.isEmpty, bytes.count <= 253, port > 0,
              bytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }),
              normalized.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
              }) else { return nil }
        return Data([5, 1, 0, 3, UInt8(bytes.count)] + bytes + [UInt8(port >> 8), UInt8(port & 255)])
    }

    static func replyAddressLength(_ header: Data) -> Int? {
        let bytes = Array(header)
        guard bytes.count == 4, bytes[0] == 5, bytes[1] == 0, bytes[2] == 0 else { return nil }
        switch bytes[3] {
        case 1: return 6
        case 4: return 18
        case 3: return 0 // Read the domain-length octet next.
        default: return nil
        }
    }
}
