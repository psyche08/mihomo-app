import CMihomoDNSSystem
import Foundation

public final class RotatingFileWriter: @unchecked Sendable {
    public static let maximumFileBytes: UInt64 = 100 * 1_024 * 1_024
    public static let retainedFiles = 3

    private let path: String
    private let maximumFileBytes: UInt64
    private let retainedFiles: Int
    private let lock = NSLock()

    public init(
        path: String,
        maximumFileBytes: UInt64 = RotatingFileWriter.maximumFileBytes,
        retainedFiles: Int = RotatingFileWriter.retainedFiles
    ) {
        self.path = path
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.retainedFiles = max(1, retainedFiles)
    }

    @discardableResult
    public func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            var offset = 0
            while offset < data.count {
                var size = currentSize()
                if size >= maximumFileBytes {
                    try rotate()
                    size = 0
                }
                let available = Int(min(maximumFileBytes - size, UInt64(data.count - offset)))
                let end = offset + available
                try appendChunk(data.subdata(in: offset..<end))
                offset = end
            }
            return true
        } catch {
            return false
        }
    }

    public func rotateIfNeeded(reservingBytes: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            if currentSize() > maximumFileBytes.saturatingSubtract(reservingBytes) { try rotate() }
        } catch {}
    }

    private func prepareDirectory() throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func currentSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func appendChunk(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = "\(path).\(retainedFiles)"
        if manager.fileExists(atPath: oldest) { try manager.removeItem(atPath: oldest) }
        if retainedFiles > 1 {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let source = "\(path).\(index)"
                let destination = "\(path).\(index + 1)"
                if manager.fileExists(atPath: source) {
                    try manager.moveItem(atPath: source, toPath: destination)
                }
            }
        }
        if manager.fileExists(atPath: path) {
            try manager.moveItem(atPath: path, toPath: "\(path).1")
        }
    }
}

private extension UInt64 {
    func saturatingSubtract(_ value: UInt64) -> UInt64 {
        value > self ? 0 : self - value
    }
}

public enum ServiceLog {
    private static let lock = NSLock()
    private static var logPath = "/Library/Logs/Mihomo App/mihomo-daemon.log"
    private static var crashLogPath = "/Library/Logs/Mihomo App/mihomo-daemon-crash.log"
    private static var writer = RotatingFileWriter(path: logPath)
    private static var crashWriter = RotatingFileWriter(path: crashLogPath)

    public static func configure(logPath: String, crashLogPath: String) {
        lock.lock()
        self.logPath = logPath
        self.crashLogPath = crashLogPath
        writer = RotatingFileWriter(path: logPath)
        crashWriter = RotatingFileWriter(path: crashLogPath)
        lock.unlock()
    }

    public static func info(_ message: String) {
        write(level: "info", message: message)
    }

    public static func error(_ message: String) {
        write(level: "error", message: message)
    }

    public static func installCrashSignalHandlers() {
        lock.lock()
        crashWriter.rotateIfNeeded(reservingBytes: 1_024)
        let path = crashLogPath
        lock.unlock()
        path.withCString { path in
            mihomo_dns_install_crash_signal_handlers(path)
        }
    }

    private static func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(timestamp) level=\(level) \(message)\n".utf8)
        if !writer.append(data) {
            FileHandle.standardError.write(data)
        }
    }
}
