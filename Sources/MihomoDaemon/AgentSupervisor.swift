import Foundation
import MihomoDNSCore

final class AgentSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.agent")
    private let agentPath: String
    private let configPath: String
    private var process: Process?
    private var startedAt: Date?
    private var desiredRunning = false

    init(
        agentPath: String = "/Library/Application Support/Mihomo App/mihomo-agent",
        configPath: String = "/Library/Application Support/Mihomo App/daemon.json"
    ) {
        self.agentPath = agentPath
        self.configPath = configPath
    }

    var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    func start() throws {
        try queue.sync {
            desiredRunning = true
            if process?.isRunning == true {
                ServiceLog.info("event=agent_start_skipped reason=already_running")
                return
            }
            try launchLocked()
        }
    }

    func stop() {
        queue.sync {
            desiredRunning = false
            guard let process, process.isRunning else {
                self.process = nil
                startedAt = nil
                ServiceLog.info("event=agent_stop_completed running=false")
                return
            }
            ServiceLog.info("event=agent_stop_started pid=\(process.processIdentifier)")
            process.terminate()
            process.waitUntilExit()
            self.process = nil
            startedAt = nil
            ServiceLog.info("event=agent_stop_completed running=false")
        }
    }

    func restart() throws {
        ServiceLog.info("event=agent_restart_started")
        stop()
        try start()
    }

    func health() throws -> Data {
        try queue.sync {
            guard FileManager.default.isExecutableFile(atPath: agentPath) else {
                throw supervisorError("installed mihomo-agent is missing")
            }
            let child = Process()
            let output = Pipe()
            child.executableURL = URL(fileURLWithPath: agentPath)
            child.arguments = ["--config", configPath, "--health"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0 else {
                throw supervisorError("mihomo-agent health check failed")
            }
            return data
        }
    }

    private func launchLocked() throws {
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw supervisorError("installed mihomo-agent is missing")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: agentPath)
        child.arguments = ["--config", configPath]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                guard let self else { return }
                guard self.process === terminated else { return }
                let runtime = self.startedAt.map {
                    max(0, Int(Date().timeIntervalSince($0) * 1_000))
                } ?? 0
                self.process = nil
                self.startedAt = nil
                let reason = terminated.terminationReason == .uncaughtSignal ? "signal" : "exit"
                ServiceLog.error(
                    "event=agent_exited pid=\(terminated.processIdentifier) reason=\(reason) " +
                    "status=\(terminated.terminationStatus) runtime_ms=\(runtime) " +
                    "restart=\(self.desiredRunning)"
                )
                guard self.desiredRunning else { return }
                self.scheduleRestartLocked()
            }
        }
        try child.run()
        process = child
        startedAt = Date()
        ServiceLog.info("event=agent_process_started pid=\(child.processIdentifier)")
    }

    private func scheduleRestartLocked() {
        guard desiredRunning, process == nil else { return }
        ServiceLog.info("event=agent_restart_scheduled delay_ms=1000")
        queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self, self.desiredRunning, self.process == nil else { return }
            do {
                try self.launchLocked()
            } catch {
                ServiceLog.error("event=agent_restart_failed retry=true")
                self.scheduleRestartLocked()
            }
        }
    }

    private func supervisorError(_ message: String) -> Error {
        NSError(domain: "MihomoAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
