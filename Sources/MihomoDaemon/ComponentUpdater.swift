import Foundation
import MihomoControl
import MihomoDNSCore

struct ComponentUpdateResult: Sendable {
    let updated: [String]
    let restartDaemon: Bool
}

private struct PendingComponentUpdate: Codable {
    enum Phase: String, Codable {
        case replacing
        case awaitingBootValidation = "awaiting_boot_validation"
    }

    var phase: Phase
    var transactionName: String
    var appVersion: String
    var changed: [String]
    var previousDigests: [String: String]
    var replacementDigests: [String: String]
}

final class ComponentUpdater: @unchecked Sendable {
    private let root: URL
    private let agent: AgentSupervisor
    private let requirement: String
    private let validateStartedRuntime: () throws -> Void
    private let pendingURL: URL
    private let versionURL: URL
    private(set) var requiresDaemonRestart = false
    private(set) var recoveryRequired = false
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.components")
    private let maximumSizes: [ManagedComponent: Int] = [
        .daemon: 64 * 1_024 * 1_024,
        .agent: 64 * 1_024 * 1_024,
        .mihomo: 128 * 1_024 * 1_024,
    ]

    init(
        agent: AgentSupervisor,
        validateStartedRuntime: @escaping () throws -> Void,
        root: URL = URL(
            fileURLWithPath: "/Library/Application Support/Mihomo App",
            isDirectory: true
        )
    ) throws {
        self.agent = agent
        self.root = root
        self.validateStartedRuntime = validateStartedRuntime
        pendingURL = root.appendingPathComponent("component-update-pending.plist")
        versionURL = root.appendingPathComponent("component-version")
        requirement = try SigningCertificateRequirement.currentProcess()
        do {
            try recoverInterruptedReplacementIfNeeded()
        } catch {
            recoveryRequired = true
            ServiceLog.error("event=component_update result=recovery_required")
        }
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
            let pending: Bool
            do {
                pending = (try readPending()) != nil
            } catch {
                recoveryRequired = true
                pending = true
            }
            return try encoder.encode(ComponentStatus(
                components: hashes,
                installedVersion: installedVersion(),
                updatePending: pending
            ))
        }
    }

    var hasPendingBootValidation: Bool {
        queue.sync {
            if recoveryRequired { return true }
            do {
                return try readPending()?.phase == .awaitingBootValidation
            } catch {
                recoveryRequired = true
                return true
            }
        }
    }

    func commitPendingBootValidation() throws {
        try queue.sync {
            guard let pending = try readPending(), pending.phase == .awaitingBootValidation else {
                return
            }
            try verifyCurrentComponents(pending.replacementDigests)
            try writeInstalledVersion(pending.appVersion)
            try clearPending(pending)
            ServiceLog.info("event=component_update result=committed")
        }
    }

    func rollbackPendingBootValidation() -> Bool {
        queue.sync {
            do {
                guard let pending = try readPending(), pending.phase == .awaitingBootValidation else {
                    return true
                }
                try restore(pending)
                try clearPending(pending)
                ServiceLog.error("event=component_update result=rolled_back")
                return true
            } catch {
                recoveryRequired = true
                ServiceLog.error("event=component_update result=rollback_failed")
                return false
            }
        }
    }

    func perform(_ payload: Data) throws -> ComponentUpdateResult {
        try queue.sync {
            guard (try readPending()) == nil else {
                throw updateError("a component update is already awaiting recovery")
            }
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
            var preserveTransactionForRestart = false
            defer {
                if !preserveTransactionForRestart {
                    try? FileManager.default.removeItem(at: transaction)
                }
            }

            var changed: [ManagedComponent] = []
            var previousDigests: [String: String] = [:]
            var replacementDigests: [String: String] = [:]
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
                let previousDigest = try digest(destination)
                let replacementDigest = ComponentUpdatePackage.digest(data)
                replacementDigests[component.rawValue] = replacementDigest
                if previousDigest != replacementDigest {
                    changed.append(component)
                    previousDigests[component.rawValue] = previousDigest
                    try FileManager.default.copyItem(
                        at: destination,
                        to: backup.appendingPathComponent(component.rawValue)
                    )
                }
            }

            guard !changed.isEmpty else {
                try writeInstalledVersion(package.appVersion)
                return ComponentUpdateResult(updated: [], restartDaemon: false)
            }

            let restartDaemon = changed.contains(.daemon)
            var pending = PendingComponentUpdate(
                phase: .replacing,
                transactionName: transaction.lastPathComponent,
                appVersion: package.appVersion,
                changed: changed.map(\.rawValue).sorted(),
                previousDigests: previousDigests,
                replacementDigests: replacementDigests
            )
            try writePending(pending)
            let wasRunning = agent.isRunning
            guard agent.stopAndRestoreVerified() else {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            }
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
                // When this process replaces itself, leave the agent stopped.
                // launchd starts the new daemon, which restores the single-agent
                // invariant and reapplies managed networking exactly once.
                if restartDaemon {
                    pending.phase = .awaitingBootValidation
                    try writePending(pending)
                    preserveTransactionForRestart = true
                } else {
                    if wasRunning {
                        try agent.start()
                        try validateStartedRuntime()
                    }
                    try writeInstalledVersion(package.appVersion)
                    try clearPending(pending)
                }
            } catch {
                _ = agent.stopAndRestoreVerified()
                do {
                    try restore(pending)
                    try clearPending(pending)
                } catch {
                    preserveTransactionForRestart = true
                    recoveryRequired = true
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
                if error is ControllerBrokerCriticalError {
                    throw updateError(
                        "component update failed and the previous runtime was restored"
                    )
                }
                throw error
            }

            return ComponentUpdateResult(
                updated: changed.map(\.rawValue).sorted(),
                restartDaemon: restartDaemon
            )
        }
    }

    private var replacementOrder: [ManagedComponent] {
        [.mihomo, .agent, .daemon]
    }

    private func validate(_ package: ComponentUpdatePackage) throws {
        guard package.formatVersion == ComponentUpdatePackage.currentFormatVersion,
              let proposed = semanticVersion(package.appVersion) else {
            throw updateError("invalid component update package version")
        }
        if FileManager.default.fileExists(atPath: versionURL.path) {
            guard let installed = installedVersion(), let current = semanticVersion(installed) else {
                throw updateError("installed component version state is invalid")
            }
            if proposed.lexicographicallyPrecedes(current) {
                throw updateError("component downgrade requires an explicit signed repair")
            }
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

    private func recoverInterruptedReplacementIfNeeded() throws {
        guard let pending = try readPending() else { return }
        switch pending.phase {
        case .replacing:
            try restore(pending)
            try clearPending(pending)
            requiresDaemonRestart = true
            ServiceLog.error("event=component_update result=recovered_interrupted_replacement")
        case .awaitingBootValidation:
            break
        }
    }

    private func readPending() throws -> PendingComponentUpdate? {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return nil }
        let values = try pendingURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64 * 1_024 else {
            throw updateError("pending component update state is unsafe")
        }
        let data = try Data(contentsOf: pendingURL)
        let pending = try PropertyListDecoder().decode(PendingComponentUpdate.self, from: data)
        try validatePending(pending)
        return pending
    }

    private func validatePending(_ pending: PendingComponentUpdate) throws {
        let expectedNames = Set(ManagedComponent.allCases.map(\.rawValue))
        guard pending.transactionName.hasPrefix(".component-update-"),
              !pending.transactionName.contains("/"),
              semanticVersion(pending.appVersion) != nil,
              !pending.changed.isEmpty,
              Set(pending.changed).isSubset(of: expectedNames),
              Set(pending.previousDigests.keys) == Set(pending.changed),
              Set(pending.replacementDigests.keys) == expectedNames,
              (Array(pending.previousDigests.values) + Array(pending.replacementDigests.values))
                  .allSatisfy(validDigest) else {
            throw updateError("pending component update state is invalid")
        }
    }

    private func writePending(_ pending: PendingComponentUpdate) throws {
        try validatePending(pending)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(pending).write(to: pendingURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pendingURL.path
        )
    }

    private func restore(_ pending: PendingComponentUpdate) throws {
        try validatePending(pending)
        let transaction = root.appendingPathComponent(pending.transactionName, isDirectory: true)
        let backup = transaction.appendingPathComponent("backup", isDirectory: true)
        let changed = Set(pending.changed)
        for component in replacementOrder where changed.contains(component.rawValue) {
            let rawName = component.rawValue
            guard let expectedDigest = pending.previousDigests[rawName] else {
                throw updateError("component rollback state is incomplete")
            }
            let saved = backup.appendingPathComponent(component.rawValue)
            try validateInstalledFile(saved)
            guard try digest(saved) == expectedDigest else {
                throw updateError("component rollback digest did not match")
            }
            try SigningCertificateRequirement.validateStaticCode(
                at: saved,
                requirement: requirement
            )
            let destination = root.appendingPathComponent(component.rawValue)
            let staged = root.appendingPathComponent(
                ".component-restore-\(component.rawValue)-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: saved, to: staged)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: staged.path
            )
            try SigningCertificateRequirement.validateStaticCode(
                at: staged,
                requirement: requirement
            )
            guard try digest(staged) == expectedDigest else {
                throw updateError("restored component digest did not match")
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            guard try digest(destination) == expectedDigest else {
                throw updateError("installed rollback component digest did not match")
            }
        }
    }

    private func verifyCurrentComponents(_ expected: [String: String]) throws {
        guard Set(expected.keys) == Set(ManagedComponent.allCases.map(\.rawValue)) else {
            throw updateError("component validation set is incomplete")
        }
        for component in ManagedComponent.allCases {
            let url = root.appendingPathComponent(component.rawValue)
            try validateInstalledFile(url)
            try SigningCertificateRequirement.validateStaticCode(
                at: url,
                requirement: requirement
            )
            guard let expectedDigest = expected[component.rawValue],
                  try digest(url) == expectedDigest else {
                throw updateError("installed component digest did not match")
            }
        }
    }

    private func clearPending(_ pending: PendingComponentUpdate) throws {
        try FileManager.default.removeItem(at: pendingURL)
        guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
            throw updateError("pending component update state could not be cleared")
        }
        let transaction = root.appendingPathComponent(pending.transactionName, isDirectory: true)
        if FileManager.default.fileExists(atPath: transaction.path) {
            // The commit marker is already gone, so a cleanup failure can only
            // leave root-owned garbage; it must not turn a committed update
            // back into an apparent rollback candidate.
            try? FileManager.default.removeItem(at: transaction)
        }
    }

    private func installedVersion() -> String? {
        guard let values = try? versionURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64,
              let value = try? String(contentsOf: versionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              semanticVersion(value) != nil else {
            return nil
        }
        return value
    }

    private func writeInstalledVersion(_ version: String) throws {
        guard semanticVersion(version) != nil else {
            throw updateError("invalid installed component version")
        }
        try Data("\(version)\n".utf8).write(to: versionURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: versionURL.path
        )
    }

    private func semanticVersion(_ value: String) -> [Int]? {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var result: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.allSatisfy({ $0.isNumber }),
                  let number = Int(field), number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }

    private func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
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
