import Foundation

public enum DNSMessageError: Error, Equatable {
    case invalidLength
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
}
