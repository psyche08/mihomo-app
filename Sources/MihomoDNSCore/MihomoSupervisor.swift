import CMihomoDNSSystem
import Darwin
import Foundation

public enum MihomoSupervisorError: Error, CustomStringConvertible {
    case binaryMissing(String)
    case configMissing(String)

    public var description: String {
        switch self {
        case .binaryMissing(let path): return "mihomo binary is missing: \(path)"
        case .configMissing(let path): return "mihomo config is missing: \(path)"
        }
    }
}

public final class MihomoSupervisor: @unchecked Sendable {
    private let configuration: MihomoProcessConfiguration
    private let logWriter: RotatingFileWriter
    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "dev.linsheng.mihomo-app.restart")
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var startedAt: Date?
    private var stopping = false

    public init(configuration: MihomoProcessConfiguration) {
        self.configuration = configuration
        logWriter = RotatingFileWriter(path: configuration.logPath)
    }

    public func start() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.binaryPath) else {
            throw MihomoSupervisorError.binaryMissing(configuration.binaryPath)
        }
        guard FileManager.default.fileExists(atPath: configuration.configPath) else {
            throw MihomoSupervisorError.configMissing(configuration.configPath)
        }
        try stopStaleOwnedProcess()
        lock.lock()
        stopping = false
        lock.unlock()
        try launch()
    }

    public func stop() {
        lock.lock()
        stopping = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        let active = process
        lock.unlock()

        if let active, active.isRunning {
            active.terminate()
            let deadline = Date().addingTimeInterval(3)
            while active.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if active.isRunning {
                kill(active.processIdentifier, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(atPath: configuration.pidPath)
    }

    public func requestRecovery() {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        let active = process
        let restartPending = restartWorkItem != nil
        lock.unlock()

        if let active, active.isRunning {
            ServiceLog.info("event=mihomo_recovery_requested action=restart pid=\(active.processIdentifier)")
            active.terminate()
        } else if !restartPending {
            ServiceLog.info("event=mihomo_recovery_requested action=start")
            scheduleRestart()
        }
    }

    private func launch() throws {
        let pipe = Pipe()
        let logWriter = self.logWriter

        let child = Process()
        child.executableURL = URL(fileURLWithPath: configuration.binaryPath)
        child.arguments = ["-d", configuration.configDirectory, "-f", configuration.configPath]
        child.standardOutput = pipe.fileHandleForWriting
        child.standardError = pipe.fileHandleForWriting
        child.terminationHandler = { [weak self] terminated in
            self?.processTerminated(
                pid: terminated.processIdentifier,
                status: terminated.terminationStatus,
                reason: terminated.terminationReason
            )
        }
        do {
            try child.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            var writeFailed = false
            while true {
                guard let data = try? pipe.fileHandleForReading.read(upToCount: 64 * 1_024),
                      !data.isEmpty else {
                    break
                }
                if !logWriter.append(data) { writeFailed = true }
            }
            try? pipe.fileHandleForReading.close()
            if writeFailed {
                ServiceLog.error("event=mihomo_log_write_failed")
            }
        }

        lock.lock()
        process = child
        startedAt = Date()
        lock.unlock()
        try writePID(child.processIdentifier)
        ServiceLog.info("event=mihomo_started pid=\(child.processIdentifier)")
        if !child.isRunning {
            processTerminated(
                pid: child.processIdentifier,
                status: child.terminationStatus,
                reason: child.terminationReason
            )
        }
    }

    private func processTerminated(pid: Int32, status: Int32, reason: Process.TerminationReason) {
        lock.lock()
        guard process?.processIdentifier == pid else {
            lock.unlock()
            return
        }
        process = nil
        let runtimeMilliseconds = startedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) }
        startedAt = nil
        let shouldRestart = !stopping
        lock.unlock()
        try? FileManager.default.removeItem(atPath: configuration.pidPath)
        let reasonName = reason == .uncaughtSignal ? "signal" : "exit"
        let runtime = runtimeMilliseconds.map(String.init) ?? "unknown"
        ServiceLog.error(
            "event=mihomo_exited pid=\(pid) reason=\(reasonName) status=\(status) " +
            "runtime_ms=\(runtime) restart=\(shouldRestart)"
        )
        if shouldRestart { scheduleRestart() }
    }

    private func scheduleRestart() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.restartWorkItem = nil
            let mayRestart = !self.stopping && self.process == nil
            self.lock.unlock()
            guard mayRestart else { return }
            do {
                try self.launch()
            } catch {
                ServiceLog.error("event=mihomo_restart_failed error=\(String(describing: error))")
                self.scheduleRestart()
            }
        }
        lock.lock()
        guard !stopping, process == nil, restartWorkItem == nil else {
            lock.unlock()
            return
        }
        restartWorkItem = item
        lock.unlock()
        ServiceLog.info(
            "event=mihomo_restart_scheduled delay_ms=\(configuration.restartDelayMilliseconds)"
        )
        restartQueue.asyncAfter(
            deadline: .now() + .milliseconds(configuration.restartDelayMilliseconds),
            execute: item
        )
    }

    private func stopStaleOwnedProcess() throws {
        guard let value = try? String(contentsOfFile: configuration.pidPath, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              mihomo_dns_pid_executable_matches(pid, configuration.binaryPath) == 1 else {
            try? FileManager.default.removeItem(atPath: configuration.pidPath)
            return
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline {
            usleep(50_000)
        }
        if mihomo_dns_pid_executable_matches(pid, configuration.binaryPath) == 1 {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(atPath: configuration.pidPath)
        ServiceLog.info("event=mihomo_stale_process_removed pid=\(pid)")
    }

    private func writePID(_ pid: Int32) throws {
        let url = URL(fileURLWithPath: configuration.pidPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }
}
