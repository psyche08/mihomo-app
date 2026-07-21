import Foundation

final class AgentSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.agent")
    private let agentPath: String
    private let configPath: String
    private var process: Process?
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
            if process?.isRunning == true { return }
            try launchLocked()
        }
    }

    func stop() {
        queue.sync {
            desiredRunning = false
            guard let process, process.isRunning else {
                self.process = nil
                return
            }
            process.terminate()
            process.waitUntilExit()
            self.process = nil
        }
    }

    func restart() throws {
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
            self?.queue.asyncAfter(deadline: .now() + .seconds(1)) {
                guard let self else { return }
                if self.process === terminated { self.process = nil }
                guard self.desiredRunning else { return }
                try? self.launchLocked()
            }
        }
        try child.run()
        process = child
    }

    private func supervisorError(_ message: String) -> Error {
        NSError(domain: "MihomoAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
