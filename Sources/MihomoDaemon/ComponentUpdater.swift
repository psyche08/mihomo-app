import Foundation
import MihomoControl

struct ComponentUpdateResult: Sendable {
    let updated: [String]
    let restartDaemon: Bool
}

final class ComponentUpdater: @unchecked Sendable {
    private let root: URL
    private let agent: AgentSupervisor
    private let requirement: String
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.components")
    private let maximumSizes: [ManagedComponent: Int] = [
        .daemon: 64 * 1_024 * 1_024,
        .agent: 64 * 1_024 * 1_024,
        .mihomo: 128 * 1_024 * 1_024,
    ]

    init(
        agent: AgentSupervisor,
        root: URL = URL(
            fileURLWithPath: "/Library/Application Support/Mihomo App",
            isDirectory: true
        )
    ) throws {
        self.agent = agent
        self.root = root
        requirement = try SigningCertificateRequirement.currentProcess()
    }

    func status() throws -> Data {
        try queue.sync {
            var hashes: [String: String] = [:]
            for component in ManagedComponent.allCases {
                let url = root.appendingPathComponent(component.rawValue)
                guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
                hashes[component.rawValue] = try digest(url)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(ComponentStatus(components: hashes))
        }
    }

    func perform(_ payload: Data) throws -> ComponentUpdateResult {
        try queue.sync {
            guard !payload.isEmpty, payload.count <= mihomoControlMaximumPayloadBytes else {
                throw updateError("component update payload exceeds the size limit")
            }
            let package = try ComponentUpdatePackage.decode(payload)
            try validate(package)

            let transaction = root.appendingPathComponent(
                ".component-update-\(UUID().uuidString)",
                isDirectory: true
            )
            let staged = transaction.appendingPathComponent("staged", isDirectory: true)
            let backup = transaction.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(
                at: staged,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: backup,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: transaction) }

            var changed: [ManagedComponent] = []
            for component in ManagedComponent.allCases {
                guard let data = package.components[component.rawValue] else {
                    throw updateError("component update package is incomplete")
                }
                let stagedURL = staged.appendingPathComponent(component.rawValue)
                try data.write(to: stagedURL, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: stagedURL.path
                )
                try SigningCertificateRequirement.validateStaticCode(
                    at: stagedURL,
                    requirement: requirement
                )

                let destination = root.appendingPathComponent(component.rawValue)
                try validateInstalledFile(destination)
                if try digest(destination) != ComponentUpdatePackage.digest(data) {
                    changed.append(component)
                    try FileManager.default.copyItem(
                        at: destination,
                        to: backup.appendingPathComponent(component.rawValue)
                    )
                }
            }

            guard !changed.isEmpty else {
                return ComponentUpdateResult(updated: [], restartDaemon: false)
            }

            let wasRunning = agent.isRunning
            agent.stop()
            do {
                for component in replacementOrder where changed.contains(component) {
                    let destination = root.appendingPathComponent(component.rawValue)
                    let source = staged.appendingPathComponent(component.rawValue)
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: destination.path
                    )
                    try SigningCertificateRequirement.validateStaticCode(
                        at: destination,
                        requirement: requirement
                    )
                }
                if wasRunning {
                    try agent.start()
                    _ = try agent.health()
                }
            } catch {
                agent.stop()
                for component in changed {
                    let destination = root.appendingPathComponent(component.rawValue)
                    let saved = backup.appendingPathComponent(component.rawValue)
                    try? FileManager.default.removeItem(at: destination)
                    if FileManager.default.fileExists(atPath: saved.path) {
                        try? FileManager.default.copyItem(at: saved, to: destination)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o755],
                            ofItemAtPath: destination.path
                        )
                    }
                }
                if wasRunning { try? agent.start() }
                throw error
            }

            return ComponentUpdateResult(
                updated: changed.map(\.rawValue).sorted(),
                restartDaemon: changed.contains(.daemon)
            )
        }
    }

    private var replacementOrder: [ManagedComponent] {
        [.mihomo, .agent, .daemon]
    }

    private func validate(_ package: ComponentUpdatePackage) throws {
        guard package.formatVersion == ComponentUpdatePackage.currentFormatVersion,
              !package.appVersion.isEmpty,
              package.appVersion.utf8.count <= 64,
              package.appVersion.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-")
                      .contains($0)
              }) else {
            throw updateError("invalid component update package version")
        }
        let expected = Set(ManagedComponent.allCases.map(\.rawValue))
        guard Set(package.components.keys) == expected else {
            throw updateError("component update package contains an invalid component set")
        }
        for component in ManagedComponent.allCases {
            guard let data = package.components[component.rawValue],
                  let maximum = maximumSizes[component],
                  !data.isEmpty, data.count <= maximum else {
                throw updateError("managed component size is invalid")
            }
        }
    }

    private func validateInstalledFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw updateError("installed managed component is missing or unsafe")
        }
    }

    private func digest(_ url: URL) throws -> String {
        ComponentUpdatePackage.digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private func updateError(_ message: String) -> Error {
        NSError(domain: "MihomoComponentUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
