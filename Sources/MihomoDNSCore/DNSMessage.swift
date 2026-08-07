import Foundation

public enum DNSMessageError: Error, Equatable {
    case invalidLength
    case invalidQuestion
}

public enum DNSMessage {
    public static let maximumWireLength = 65_535
    static let runtimeHealthQuery = Data([
        0x4d, 0x48, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
        0x03, 0x63, 0x6f, 0x6d,
        0x00, 0x00, 0x01, 0x00, 0x01,
    ])

    /// Builds an A query for `name`.
    public static func addressQuery(for name: String, identifier: UInt16 = 0x4d48) -> Data? {
        let labels = name.split(separator: ".", omittingEmptySubsequences: true)
        guard !labels.isEmpty, labels.allSatisfy({ (1 ... 63).contains($0.utf8.count) }) else {
            return nil
        }
        var message = Data([
            UInt8(identifier >> 8), UInt8(identifier & 0xff),
            0x01, 0x00, // recursion desired
            0x00, 0x01, // one question
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        for label in labels {
            message.append(UInt8(label.utf8.count))
            message.append(contentsOf: Array(label.utf8))
        }
        message.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01]) // root, A, IN
        return message
    }

    /// First IPv4 address in the answer section, in dotted-quad form.
    public static func firstIPv4Answer(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let base = data.startIndex
        let questions = Int(readUInt16(data, at: 4))
        let answers = Int(readUInt16(data, at: 6))
        guard answers > 0 else { return nil }

        var offset = 12
        // Questions carry a name then type and class.
        for _ in 0 ..< questions {
            guard let next = skipName(data, from: offset) else { return nil }
            offset = next + 4
        }
        for _ in 0 ..< answers {
            guard let afterName = skipName(data, from: offset) else { return nil }
            offset = afterName
            guard offset + 10 <= data.count else { return nil }
            let type = readUInt16(data, at: offset)
            let length = Int(readUInt16(data, at: offset + 8))
            offset += 10
            guard offset + length <= data.count else { return nil }
            if type == 1, length == 4 {
                let bytes = (0 ..< 4).map { data[base + offset + $0] }
                return bytes.map(String.init).joined(separator: ".")
            }
            offset += length
        }
        return nil
    }

    /// Advances past a name, following the one compression pointer a name may
    /// end with. Returns the offset just after it.
    private static func skipName(_ data: Data, from start: Int) -> Int? {
        var offset = start
        while offset < data.count {
            let length = Int(data[data.startIndex + offset])
            if length == 0 { return offset + 1 }
            if length & 0xc0 == 0xc0 { return offset + 2 }
            guard length < 64 else { return nil }
            offset += 1 + length
        }
        return nil
    }

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
