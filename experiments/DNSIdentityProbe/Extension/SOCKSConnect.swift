import Foundation

// Pure framing used by the bounded App Proxy bridge. DNS stays at the proxy.
enum SOCKSConnect {
    static func request(host: String, port: UInt16) -> Data? {
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 253, port > 0,
              bytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
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
