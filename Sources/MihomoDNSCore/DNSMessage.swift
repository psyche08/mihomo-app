import Foundation

public enum DNSMessageError: Error, Equatable {
    case invalidLength
    case invalidQuestion
}

public enum DNSMessage {
    public static let maximumWireLength = 65_535

    public static func validate(_ data: Data) throws {
        guard data.count >= 12, data.count <= maximumWireLength else {
            throw DNSMessageError.invalidLength
        }
    }

    public static func isTruncated(_ data: Data) -> Bool {
        data.count >= 4 && (data[data.startIndex + 2] & 0x02) != 0
    }

    public static func questionName(_ data: Data) throws -> String {
        try validate(data)
        guard readUInt16(data, at: 4) > 0 else { throw DNSMessageError.invalidQuestion }
        var labels: [String] = []
        var offset = 12
        var visited = Set<Int>()
        var steps = 0
        while steps < 128 {
            steps += 1
            guard offset < data.count else { throw DNSMessageError.invalidQuestion }
            let length = Int(data[offset])
            if length == 0 {
                return labels.joined(separator: ".").lowercased()
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < data.count else { throw DNSMessageError.invalidQuestion }
                let pointer = ((length & 0x3F) << 8) | Int(data[offset + 1])
                guard pointer < data.count, visited.insert(pointer).inserted else {
                    throw DNSMessageError.invalidQuestion
                }
                offset = pointer
                continue
            }
            guard length <= 63, offset + 1 + length <= data.count else {
                throw DNSMessageError.invalidQuestion
            }
            let bytes = data[(offset + 1)..<(offset + 1 + length)]
            guard let label = String(bytes: bytes, encoding: .utf8), !label.isEmpty else {
                throw DNSMessageError.invalidQuestion
            }
            labels.append(label)
            offset += 1 + length
        }
        throw DNSMessageError.invalidQuestion
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
}
