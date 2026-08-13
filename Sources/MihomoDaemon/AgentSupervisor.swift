import CMihomoDNSSystem
import Foundation
import MihomoDNSCore

final class AgentSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.agent")
    private let agentPath: String
    private let configPath: String
    private let agentPIDPath: String
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
        agentPIDPath = URL(fileURLWithPath: configPath)
            .deletingLastPathComponent()
            .appendingPathComponent("mihomo-agent.pid")
            .path
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

    @discardableResult
    func stop() -> Bool {
        queue.sync {
            desiredRunning = false
            circuitOpen = false
            restartBackoff.reset()
            guard let process, process.isRunning else {
                let orphanStopped = stopOwnedAgentFromPIDFile()
                self.process = nil
                startedAt = nil
                ServiceLog.info("event=agent_stop_completed running=false")
                return orphanStopped
            }
            ServiceLog.info("event=agent_stop_started pid=\(process.processIdentifier)")
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < terminateDeadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killDeadline {
                    usleep(50_000)
                }
            }
            guard !process.isRunning else {
                ServiceLog.error("event=agent_stop_completed running=true")
                return false
            }
            self.process = nil
            startedAt = nil
            removeAgentPIDIfMatching(process.processIdentifier)
            ServiceLog.info("event=agent_stop_completed running=false")
            return true
        }
    }

    /// Stops the supervised agent, removes an orphaned managed Mihomo process,
    /// restores system DNS from the root-owned backup, and inspects live state
    /// without consulting the agent's six-second health cache.
    func stopAndRestoreVerified() -> Bool {
        let agentStopped = stop()
        guard let configuration = try? ProxyConfiguration.load(path: configPath) else {
            return false
        }
        if let mihomo = configuration.mihomoProcess {
            MihomoSupervisor.stopOwnedProcess(configuration: mihomo)
        }
        HealthSnapshotStore.remove(at: configuration.healthSnapshotPath)
        do {
            try ProxyService.restoreSystemDNS(configuration: configuration)
        } catch {
            return false
        }
        let observed = ProxyService.networkHealth(configuration: configuration)
        return agentStopped
            && !isRunning
            && !observed.controllerReachable
            && !observed.tunEnabled
            && !observed.systemDNSManaged
            && observed.networkConsistent
    }

    func restart() throws {
        ServiceLog.info("event=agent_restart_started")
        guard stop() else {
            throw supervisorError("installed mihomo-agent did not stop")
        }
        try start()
    }

    func health() throws -> Data {
        let configuration = try ProxyConfiguration.load(path: configPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Prefer the reading the agent's observer just took. Inspecting here
        // repeats its most expensive work — two DNS probes with two-second
        // timeouts, a routing lookup and a full config parse — on every tray
        // poll. A missing or stale file means the observer is not running, and
        // then this must inspect rather than serve something out of date.
        if let published = HealthSnapshotStore.read(from: configuration.healthSnapshotPath) {
            return try encoder.encode(published)
        }
        return try encoder.encode(ProxyService.networkHealth(configuration: configuration))
    }

    func freshHealth() throws -> NetworkConsistencyHealth {
        let configuration = try ProxyConfiguration.load(path: configPath)
        return ProxyService.networkHealth(configuration: configuration)
    }

    private func launchLocked() throws {
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw supervisorError("installed mihomo-agent is missing")
        }
        guard stopOwnedAgentFromPIDFile() else {
            throw supervisorError("a previous mihomo-agent did not stop")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: agentPath)
        child.arguments = [
            "--config", configPath,
            "--parent-pid", String(getpid()),
        ]
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
                self.removeAgentPIDIfMatching(terminated.processIdentifier)
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
        do {
            try writeAgentPID(child.processIdentifier)
        } catch {
            child.terminate()
            let deadline = Date().addingTimeInterval(1)
            while child.isRunning, Date() < deadline { usleep(50_000) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            let killDeadline = Date().addingTimeInterval(1)
            while child.isRunning, Date() < killDeadline { usleep(50_000) }
            guard !child.isRunning else {
                throw supervisorError("mihomo-agent PID state failed and the child did not stop")
            }
            process = nil
            startedAt = nil
            throw error
        }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let restored = self.stopAndRestoreVerified()
            ServiceLog.info(
                "event=agent_circuit_restore result=" +
                (restored ? "success" : "restore_unconfirmed")
            )
        }
    }

    private func stopOwnedAgentFromPIDFile() -> Bool {
        guard let value = try? String(contentsOfFile: agentPIDPath, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            try? FileManager.default.removeItem(atPath: agentPIDPath)
            return true
        }
        guard mihomo_dns_pid_executable_matches(pid, agentPath) == 1 else {
            try? FileManager.default.removeItem(atPath: agentPIDPath)
            return true
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while mihomo_dns_pid_executable_matches(pid, agentPath) == 1, Date() < deadline {
            usleep(50_000)
        }
        if mihomo_dns_pid_executable_matches(pid, agentPath) == 1 {
            kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while mihomo_dns_pid_executable_matches(pid, agentPath) == 1,
                  Date() < killDeadline {
                usleep(50_000)
            }
        }
        guard mihomo_dns_pid_executable_matches(pid, agentPath) != 1 else { return false }
        try? FileManager.default.removeItem(atPath: agentPIDPath)
        return true
    }

    private func writeAgentPID(_ pid: Int32) throws {
        try Data("\(pid)\n".utf8).write(
            to: URL(fileURLWithPath: agentPIDPath),
            options: [.atomic]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: agentPIDPath
        )
    }

    private func removeAgentPIDIfMatching(_ pid: Int32) {
        guard let value = try? String(contentsOfFile: agentPIDPath, encoding: .utf8),
              Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else {
            return
        }
        try? FileManager.default.removeItem(atPath: agentPIDPath)
    }

    private func supervisorError(_ message: String) -> Error {
        NSError(domain: "MihomoAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
