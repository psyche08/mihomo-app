import Foundation

public enum ServiceLog {
    private static let lock = NSLock()

    public static func info(_ message: String) {
        write(level: "info", message: message)
    }

    public static func error(_ message: String) {
        write(level: "error", message: message)
    }

    private static func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(timestamp) level=\(level) \(message)\n".utf8))
    }
}
