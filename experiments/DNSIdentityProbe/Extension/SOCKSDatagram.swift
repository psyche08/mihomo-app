import Foundation
import Darwin

enum SOCKSDatagram {
    struct Packet { let host: String; let port: UInt16; let payload: Data }
    static func encode(host: String, port: UInt16, payload: Data) -> Data? {
        guard let request = SOCKSConnect.request(host: host, port: port), payload.count <= 65000 else { return nil }
        return Data([0, 0, 0]) + request.dropFirst(3) + payload
    }
    static func decode(_ data: Data) -> Packet? {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes[0...2] == [0, 0, 0] else { return nil }
        var cursor = 4
        let host: String
        switch bytes[3] {
        case 1, 4:
            let length = bytes[3] == 1 ? 4 : 16
            guard bytes.count >= cursor + length + 2 else { return nil }
            let address = Array(bytes[cursor..<cursor+length])
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let result = address.withUnsafeBytes { inet_ntop(length == 4 ? AF_INET : AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
            guard result != nil else { return nil }
            host = String(cString: buffer); cursor += length
        case 3:
            guard bytes.count >= 5 else { return nil }
            let length = Int(bytes[4]); cursor = 5
            guard length > 0, bytes.count >= cursor + length + 2,
                  let name = String(bytes: bytes[cursor..<cursor+length], encoding: .utf8),
                  SOCKSConnect.request(host: name, port: 1) != nil else { return nil }
            host = name; cursor += length
        default: return nil
        }
        let port = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor+1])
        guard port > 0 else { return nil }
        return Packet(host: host, port: port, payload: Data(bytes.dropFirst(cursor + 2)))
    }
}
