import Foundation
import MihomoDNSCore

final class AgentSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.agent")
    private let agentPath: String
    private let configPath: String
    private var process: Process?
    private var startedAt: Date?
    private var desiredRunning = false
    private var circuitOpen = false
    private var restartBackoff = RestartBackoffPolicy()

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
            circuitOpen = false
            restartBackoff.reset()
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
            circuitOpen = false
            restartBackoff.reset()
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
        let configuration = try ProxyConfiguration.load(path: configPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ProxyService.networkHealth(configuration: configuration))
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
                let decision = self.desiredRunning
                    ? self.restartBackoff.recordFailure(runtimeMilliseconds: runtime)
                    : nil
                if case .some(.open) = decision {
                    self.circuitOpen = true
                    self.desiredRunning = false
                }
                ServiceLog.error(
                    "event=agent_exited pid=\(terminated.processIdentifier) reason=\(reason) " +
                    "status=\(terminated.terminationStatus) runtime_ms=\(runtime) " +
                    "restart=\(self.desiredRunning)"
                )
                switch decision {
                case let .retry(delayMilliseconds, failures):
                    self.scheduleRestartLocked(
                        delayMilliseconds: delayMilliseconds,
                        failures: failures
                    )
                case let .open(failures):
                    ServiceLog.error("event=agent_circuit_open failures=\(failures)")
                    self.restoreSafeNetworkAfterCircuitOpen()
                case nil:
                    break
                }
            }
        }
        try child.run()
        process = child
        startedAt = Date()
        ServiceLog.info("event=agent_process_started pid=\(child.processIdentifier)")
    }

    private func scheduleRestartLocked(delayMilliseconds: Int, failures: Int) {
        guard desiredRunning, !circuitOpen, process == nil else { return }
        ServiceLog.info(
            "event=agent_restart_scheduled delay_ms=\(delayMilliseconds) failures=\(failures)"
        )
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self, self.desiredRunning, !self.circuitOpen, self.process == nil else { return }
            do {
                try self.launchLocked()
            } catch {
                ServiceLog.error("event=agent_restart_failed reason=launch_failed")
                switch self.restartBackoff.recordFailure(runtimeMilliseconds: 0) {
                case let .retry(nextDelayMilliseconds, nextFailures):
                    self.scheduleRestartLocked(
                        delayMilliseconds: nextDelayMilliseconds,
                        failures: nextFailures
                    )
                case let .open(nextFailures):
                    self.circuitOpen = true
                    self.desiredRunning = false
                    ServiceLog.error("event=agent_circuit_open failures=\(nextFailures)")
                    self.restoreSafeNetworkAfterCircuitOpen()
                }
            }
        }
    }

    private func restoreSafeNetworkAfterCircuitOpen() {
        let configPath = self.configPath
        DispatchQueue.global(qos: .utility).async {
            guard let configuration = try? ProxyConfiguration.load(path: configPath) else {
                ServiceLog.error("event=agent_circuit_restore result=config_unavailable")
                return
            }
            do {
                try ProxyService.restoreSystemDNS(configuration: configuration)
                ServiceLog.info("event=agent_circuit_restore result=success")
            } catch {
                ServiceLog.error("event=agent_circuit_restore result=failed")
            }
        }
    }

    private func supervisorError(_ message: String) -> Error {
        NSError(domain: "MihomoAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
