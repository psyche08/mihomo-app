import Darwin
import Foundation
import MihomoControl

final class ProfileBroker: @unchecked Sendable {
    private let agent: AgentSupervisor
    private let validateStartedRuntime: () throws -> Void
    private let root = URL(fileURLWithPath: "/Library/Application Support/Mihomo App", isDirectory: true)
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.profile")

    var activationRequired: Bool {
        queue.sync {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("provisioning").path)
        }
    }

    init(agent: AgentSupervisor, validateStartedRuntime: @escaping () throws -> Void) {
        self.agent = agent
        self.validateStartedRuntime = validateStartedRuntime
    }

    func list() throws -> Data {
        try queue.sync { try listUnlocked() }
    }

    func perform(_ request: ControlRequest) throws -> Data {
        try queue.sync {
            switch request.operation {
            case .importProfile:
                guard let name = request.arguments["name"], let payload = request.payload else {
                    throw profileError("profile name and bytes are required")
                }
                let activate = request.arguments["activate"] == "true"
                try importProfile(name: name, data: payload, activate: activate)
                return try listUnlocked()
            case .switchProfile:
                guard let name = request.arguments["name"] else {
                    throw profileError("profile name is required")
                }
                try validateName(name)
                let source = root.appendingPathComponent("profiles").appendingPathComponent(name)
                try activateProfile(name: name, data: try readStoredProfile(source))
                return try listUnlocked()
            case .reloadProfile:
                let active = try activeProfileName()
                let source = root.appendingPathComponent("profiles").appendingPathComponent(active)
                let data = try readStoredProfile(source)
                try validate(name: active, data: data)
                try reloadActiveRuntime()
                return try listUnlocked()
            default:
                throw profileError("operation is not a profile operation")
            }
        }
    }

    /// Reloading an already-active profile does not mutate its files. Keep the
    /// agent, DNS listeners, alias, and Global DNS ownership alive and replace
    /// only the Mihomo child. Profile import/switch still uses the full atomic
    /// activation transaction below because those operations change files and
    /// controller credentials.
    private func reloadActiveRuntime() throws {
        do {
            if agent.isRunning {
                try agent.restartMihomoChild()
            } else {
                try agent.start()
            }
            try validateStartedRuntime()
        } catch {
            guard agent.stopAndRestoreVerified() else {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            }
            throw profileError("profile reload failed; the managed runtime was stopped safely")
        }
    }

    private func importProfile(name: String, data: Data, activate: Bool) throws {
        try validate(name: name, data: data)
        if activate {
            try activateProfile(name: name, data: data)
            return
        }
        let temporary = try preparedProfile(data: data, publishController: false)
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        try validateMihomo(path: temporary)
        try storeRawProfile(name: name, data: data)
    }

    private func activateProfile(name: String, data: Data) throws {
        try validate(name: name, data: data)
        let transaction = root.appendingPathComponent(".profile-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transaction,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: transaction) }

        let protected = [
            "daemon.json", "controller.json", "controller-secret", "active-profile",
            "provisioning", "mihomo-data/config.yaml", "profiles/\(name)",
        ]
        var backupDigests: [String: String] = [:]
        for relative in protected {
            let source = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: source.path) {
                let backup = transaction.appendingPathComponent("backup").appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: backup)
                backupDigests[relative] = ComponentUpdatePackage.digest(
                    try Data(contentsOf: backup, options: [.mappedIfSafe])
                )
            }
        }
        let wasRunning = agent.isRunning
        do {
            let configured = try preparedProfile(data: data, publishController: true)
            defer { try? FileManager.default.removeItem(at: configured.deletingLastPathComponent()) }
            try validateMihomo(path: configured)
            guard agent.stopAndRestoreVerified() else {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            }
            let activeConfig = root.appendingPathComponent("mihomo-data/config.yaml")
            try FileManager.default.createDirectory(
                at: activeConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try replace(configured, activeConfig, permissions: 0o600)
            try storeRawProfile(name: name, data: data)
            try writePrivate(Data("\(name)\n".utf8), to: root.appendingPathComponent("active-profile"), permissions: 0o644)
            let provisioning = root.appendingPathComponent("provisioning")
            if FileManager.default.fileExists(atPath: provisioning.path) {
                try FileManager.default.removeItem(at: provisioning)
            }
            try agent.start()
            try validateStartedRuntime()
        } catch {
            let activationError = error
            _ = agent.stopAndRestoreVerified()
            do {
                try restoreProtected(
                    protected,
                    transaction: transaction,
                    backupDigests: backupDigests
                )
            } catch {
                _ = agent.stopAndRestoreVerified()
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            }
            if wasRunning {
                do {
                    try agent.start()
                    try validateStartedRuntime()
                } catch {
                    _ = agent.stopAndRestoreVerified()
                    throw ControllerBrokerCriticalError.unsafeGlobalRuntime
                }
            }
            if activationError is ControllerBrokerCriticalError {
                throw profileError("profile activation failed and the previous profile was restored")
            }
            throw activationError
        }
    }

    private func restoreProtected(
        _ protected: [String],
        transaction: URL,
        backupDigests: [String: String]
    ) throws {
        for relative in protected {
            let destination = root.appendingPathComponent(relative)
            let backup = transaction.appendingPathComponent("backup").appendingPathComponent(relative)
            guard let expectedDigest = backupDigests[relative] else {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: backup.path),
                  ComponentUpdatePackage.digest(
                      try Data(contentsOf: backup, options: [.mappedIfSafe])
                  ) == expectedDigest else {
                throw profileError("profile rollback backup is incomplete")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".profile-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: backup, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            guard ComponentUpdatePackage.digest(
                try Data(contentsOf: destination, options: [.mappedIfSafe])
            ) == expectedDigest else {
                throw profileError("profile rollback verification failed")
            }
        }
    }

    private func preparedProfile(data: Data, publishController: Bool) throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("mihomobox-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let config = directory.appendingPathComponent("config.yaml")
        let backup = directory.appendingPathComponent("original.yaml")
        try writePrivate(data, to: config, permissions: 0o600)
        var arguments = [
            "--configure-profile",
            "--profile", config.path,
            "--profile-backup", backup.path,
        ]
        if publishController {
            arguments += [
                "--secret-file", root.appendingPathComponent("controller-secret").path,
                "--controller-metadata", root.appendingPathComponent("controller.json").path,
                "--daemon-config", root.appendingPathComponent("daemon.json").path,
            ]
        }
        guard try run(root.appendingPathComponent("mihomo-agent").path, arguments) == 0 else {
            throw profileError("profile configuration failed")
        }
        return config
    }

    private func validateMihomo(path: URL) throws {
        let arguments = [
            "-t", "-d", root.appendingPathComponent("mihomo-data").path,
            "-f", path.path,
        ]
        guard try run(root.appendingPathComponent("mihomo").path, arguments) == 0 else {
            throw profileError("Mihomo rejected the profile")
        }
    }

    private func storeRawProfile(name: String, data: Data) throws {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try writePrivate(data, to: profiles.appendingPathComponent(name), permissions: 0o600)
    }

    private func activeProfileName() throws -> String {
        let value = try String(
            contentsOf: root.appendingPathComponent("active-profile"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try validateName(value)
        return value
    }

    private func validate(name: String, data: Data) throws {
        try validateName(name)
        guard !data.isEmpty, data.count <= 16 * 1_024 * 1_024 else {
            throw profileError("profile must be between 1 byte and 16 MiB")
        }
    }

    private func validateName(_ name: String) throws {
        let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("."),
              !name.contains("/"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              suffix == "yaml" || suffix == "yml" else {
            throw profileError("invalid profile filename")
        }
    }

    private func readStoredProfile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw profileError("stored profile is missing or unsafe")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0, status.st_size <= 16 * 1_024 * 1_024 else {
            throw profileError("stored profile changed while opening")
        }
        guard let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1),
              !data.isEmpty, data.count <= 16 * 1_024 * 1_024 else {
            throw profileError("stored profile exceeds the size limit")
        }
        return data
    }

    private func listUnlocked() throws -> Data {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [])
            .filter { ["yaml", "yml"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
        let active = try? activeProfileName()
        let activeValue: Any = active == nil ? NSNull() : active!
        return try JSONSerialization.data(withJSONObject: [
            "profiles": names,
            "active_profile": activeValue,
        ])
    }

    private func replace(_ source: URL, _ destination: URL, permissions: Int) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private func writePrivate(_ data: Data, to destination: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: staged, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminateDeadline {
                usleep(50_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline {
                usleep(50_000)
            }
        }
        guard !process.isRunning else {
            throw profileError("profile validator did not stop")
        }
        return process.terminationStatus
    }

    private func profileError(_ message: String) -> Error {
        NSError(domain: "MihomoProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
