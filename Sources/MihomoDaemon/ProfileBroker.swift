import Foundation
import MihomoControl

final class ProfileBroker: @unchecked Sendable {
    private let agent: AgentSupervisor
    private let root = URL(fileURLWithPath: "/Library/Application Support/Mihomo App", isDirectory: true)
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.profile")

    init(agent: AgentSupervisor) {
        self.agent = agent
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
                let source = root.appendingPathComponent("profiles").appendingPathComponent(name)
                try activateProfile(name: name, data: Data(contentsOf: source))
                return try listUnlocked()
            case .reloadProfile:
                let active = try activeProfileName()
                let source = root.appendingPathComponent("profiles").appendingPathComponent(active)
                try activateProfile(name: active, data: Data(contentsOf: source))
                return try listUnlocked()
            default:
                throw profileError("operation is not a profile operation")
            }
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
            "mihomo-data/config.yaml",
        ]
        for relative in protected {
            let source = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: source.path) {
                let backup = transaction.appendingPathComponent("backup").appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: backup)
            }
        }
        let wasRunning = agent.isRunning
        do {
            let configured = try preparedProfile(data: data, publishController: true)
            defer { try? FileManager.default.removeItem(at: configured.deletingLastPathComponent()) }
            try validateMihomo(path: configured)
            agent.stop()
            let activeConfig = root.appendingPathComponent("mihomo-data/config.yaml")
            try FileManager.default.createDirectory(
                at: activeConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try replace(configured, activeConfig, permissions: 0o600)
            try storeRawProfile(name: name, data: data)
            try writePrivate(Data("\(name)\n".utf8), to: root.appendingPathComponent("active-profile"), permissions: 0o644)
            try agent.start()
        } catch {
            agent.stop()
            for relative in protected {
                let destination = root.appendingPathComponent(relative)
                let backup = transaction.appendingPathComponent("backup").appendingPathComponent(relative)
                try? FileManager.default.removeItem(at: destination)
                if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.copyItem(at: backup, to: destination)
                }
            }
            if wasRunning { try? agent.start() }
            throw error
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
            root.appendingPathComponent("configure_mihomo.py").path,
            "--config", config.path,
            "--backup", backup.path,
        ]
        if publishController {
            arguments += [
                "--secret-file", root.appendingPathComponent("controller-secret").path,
                "--controller-metadata", root.appendingPathComponent("controller.json").path,
                "--daemon-config", root.appendingPathComponent("daemon.json").path,
            ]
        }
        guard try run("/usr/bin/python3", arguments) == 0 else {
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
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func profileError(_ message: String) -> Error {
        NSError(domain: "MihomoProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
