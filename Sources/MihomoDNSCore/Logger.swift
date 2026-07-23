import CMihomoDNSSystem
import Foundation

public final class RotatingFileWriter: @unchecked Sendable {
    public static let maximumFileBytes: UInt64 = 100 * 1_024 * 1_024
    public static let retainedFiles = 3
    public static let defaultFlushThresholdBytes = 64 * 1_024

    private let path: String
    private let maximumFileBytes: UInt64
    private let retainedFiles: Int
    private let flushThresholdBytes: Int
    private let lock = NSLock()
    private var pending = Data()
    private var timer: DispatchSourceTimer?

    public init(
        path: String,
        maximumFileBytes: UInt64 = RotatingFileWriter.maximumFileBytes,
        retainedFiles: Int = RotatingFileWriter.retainedFiles,
        flushThresholdBytes: Int = RotatingFileWriter.defaultFlushThresholdBytes,
        flushIntervalSeconds: TimeInterval = 1
    ) {
        self.path = path
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.retainedFiles = max(1, retainedFiles)
        self.flushThresholdBytes = max(1, flushThresholdBytes)

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.linsheng.mihomo-app.log.\(UUID().uuidString)")
        )
        timer.schedule(
            deadline: .now() + flushIntervalSeconds,
            repeating: flushIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            _ = self?.flush()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        _ = flush()
    }

    @discardableResult
    public func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        guard pending.count >= flushThresholdBytes else { return true }
        return flushLocked()
    }

    @discardableResult
    public func flush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flushLocked()
    }

    public func rotateIfNeeded(reservingBytes: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard flushLocked() else { return }
            try prepareDirectory()
            if currentSize() > maximumFileBytes.saturatingSubtract(reservingBytes) { try rotate() }
        } catch {}
    }

    private func flushLocked() -> Bool {
        guard !pending.isEmpty else { return true }
        let data = pending
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
            pending.removeAll(keepingCapacity: true)
            return true
        } catch {
            return false
        }
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

public final class SanitizedProcessLogAccumulator: @unchecked Sendable {
    private let maximumLines: Int
    private let maximumBytes: Int
    private var partial = Data()
    private var lines = 0
    private var bytes = 0
    private var infos = 0
    private var warnings = 0
    private var errors = 0

    public init(maximumLines: Int = 512, maximumBytes: Int = 256 * 1_024) {
        self.maximumLines = max(1, maximumLines)
        self.maximumBytes = max(1, maximumBytes)
    }

    public func ingest(_ data: Data) -> Data? {
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0a) {
            let line = Data(partial[..<newline])
            partial.removeSubrange(...newline)
            consume(line)
        }
        if partial.count > 64 * 1_024 {
            consume(partial)
            partial.removeAll(keepingCapacity: true)
        }
        return shouldEmit ? emit()
            : nil
    }

    public func finish() -> Data? {
        if !partial.isEmpty {
            consume(partial)
            partial.removeAll(keepingCapacity: true)
        }
        return lines > 0 ? emit() : nil
    }

    private var shouldEmit: Bool {
        lines >= maximumLines || bytes >= maximumBytes
    }

    private func consume(_ line: Data) {
        lines += 1
        bytes += line.count + 1
        if line.range(of: Data("level=error".utf8)) != nil {
            errors += 1
        } else if line.range(of: Data("level=warning".utf8)) != nil {
            warnings += 1
        } else {
            infos += 1
        }
    }

    private func emit() -> Data {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let message =
            "\(timestamp) level=info event=mihomo_output_summary " +
            "lines=\(lines) bytes=\(bytes) info=\(infos) warning=\(warnings) error=\(errors)\n"
        let record = Data(message.utf8)
        lines = 0
        bytes = 0
        infos = 0
        warnings = 0
        errors = 0
        return record
    }
}

public enum SanitizedProcessLogMigration {
    public static func prepare(logPath: String, retainedFiles: Int = 3) throws {
        let markerPath = "\(logPath).sanitized-v1"
        let manager = FileManager.default
        guard !manager.fileExists(atPath: markerPath) else { return }

        let directory = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for generation in 0...max(0, retainedFiles) {
            let candidate = generation == 0 ? logPath : "\(logPath).\(generation)"
            if manager.fileExists(atPath: candidate) {
                try manager.removeItem(atPath: candidate)
            }
        }
        guard manager.createFile(
            atPath: markerPath,
            contents: Data("sanitized process logging enabled\n".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
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

    public static func flush() {
        lock.lock()
        _ = writer.flush()
        lock.unlock()
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
