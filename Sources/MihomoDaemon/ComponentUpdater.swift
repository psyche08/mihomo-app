import Darwin
import Foundation
import MihomoControl
import MihomoDNSCore

private let componentMutationLockPath = "/Library/Application Support/.mihomobox-install.lock"

enum ComponentMutationLockError: LocalizedError {
    case busy
    case unsafe
    case unavailable

    var errorDescription: String? {
        switch self {
        case .busy:
            "another privileged MihomoBox mutation is running"
        case .unsafe:
            "privileged mutation lock is unsafe"
        case .unavailable:
            "privileged mutation lock could not be opened"
        }
    }
}

final class ComponentMutationFileLock {
    private let descriptor: Int32

    init() throws {
        descriptor = try Self.openVerifiedDescriptor()
    }

    deinit {
        Darwin.close(descriptor)
    }

    private static func openVerifiedDescriptor() throws -> Int32 {
        for attempt in 0..<3 {
            var pathMetadata = stat()
            if lstat(componentMutationLockPath, &pathMetadata) == 0 {
                guard isSafeLockMetadata(pathMetadata) else {
                    throw ComponentMutationLockError.unsafe
                }
                let descriptor = Darwin.open(
                    componentMutationLockPath,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
                )
                if descriptor < 0 {
                    let openError = errno
                    if openError == ENOENT, attempt < 2 { continue }
                    if openError == EWOULDBLOCK || openError == EAGAIN {
                        throw ComponentMutationLockError.busy
                    }
                    throw ComponentMutationLockError.unavailable
                }
                do {
                    try validateOpenDescriptor(descriptor)
                    return descriptor
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }

            guard errno == ENOENT else {
                throw ComponentMutationLockError.unavailable
            }
            let descriptor = Darwin.open(
                componentMutationLockPath,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
                mode_t(0o600)
            )
            if descriptor < 0 {
                let openError = errno
                if openError == EEXIST, attempt < 2 { continue }
                if openError == EWOULDBLOCK || openError == EAGAIN {
                    throw ComponentMutationLockError.busy
                }
                throw ComponentMutationLockError.unavailable
            }
            do {
                guard fchown(descriptor, 0, 0) == 0,
                      fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw ComponentMutationLockError.unavailable
                }
                try validateOpenDescriptor(descriptor)
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        throw ComponentMutationLockError.unavailable
    }

    private static func validateOpenDescriptor(_ descriptor: Int32) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              lstat(componentMutationLockPath, &pathMetadata) == 0,
              isSafeLockMetadata(descriptorMetadata),
              isSafeLockMetadata(pathMetadata),
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino else {
            throw ComponentMutationLockError.unsafe
        }
    }

    private static func isSafeLockMetadata(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & 0o7777 == 0o600
            && metadata.st_uid == 0
            && metadata.st_gid == 0
    }
}

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
    // Optional only for decoding an in-flight 0.8.0 transaction. Every 0.8.1+
    // writer records it; an old-schema rollback derives it from the still
    // uncommitted, strictly validated component-version marker.
    var previousVersion: String?
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
    private var pendingBootValidationLock: ComponentMutationFileLock?
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
        } catch ComponentMutationLockError.busy {
            // A competing installer/update owns the transaction boundary.
            // Keep networking stopped and let ControlDispatcher perform its
            // existing controlled restart so launchd retries after unlock.
            requiresDaemonRestart = true
            ServiceLog.error("event=component_update result=recovery_deferred_busy")
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

    var ownsPendingMutationFileLock: Bool {
        queue.sync { pendingBootValidationLock != nil }
    }

    func commitPendingBootValidation() throws {
        try queue.sync {
            guard try readPending()?.phase == .awaitingBootValidation else {
                pendingBootValidationLock = nil
                return
            }
            let fileLock: ComponentMutationFileLock
            do {
                fileLock = try mutationLockForTransaction()
            } catch ComponentMutationLockError.busy {
                requiresDaemonRestart = true
                ServiceLog.error("event=component_update result=commit_deferred_busy")
                throw ComponentMutationLockError.busy
            }
            defer { withExtendedLifetime(fileLock) {} }
            guard let pending = try readPending(), pending.phase == .awaitingBootValidation else {
                pendingBootValidationLock = nil
                return
            }
            try verifyCurrentComponents(pending.replacementDigests)
            try writeInstalledVersion(pending.appVersion)
            try clearPending(pending)
            pendingBootValidationLock = nil
            ServiceLog.info("event=component_update result=committed")
        }
    }

    func rollbackPendingBootValidation() -> Bool {
        queue.sync {
            do {
                guard try readPending()?.phase == .awaitingBootValidation else {
                    pendingBootValidationLock = nil
                    return true
                }
                let fileLock = try mutationLockForTransaction()
                defer { withExtendedLifetime(fileLock) {} }
                guard let pending = try readPending(), pending.phase == .awaitingBootValidation else {
                    pendingBootValidationLock = nil
                    return true
                }
                try restore(pending)
                try clearPending(pending)
                pendingBootValidationLock = nil
                ServiceLog.error("event=component_update result=rolled_back")
                return true
            } catch ComponentMutationLockError.busy {
                pendingBootValidationLock = nil
                requiresDaemonRestart = true
                ServiceLog.error("event=component_update result=rollback_deferred_busy")
                // Both startup callers interpret true as safe to perform their
                // existing controlled daemon restart. No rollback is claimed
                // complete on disk; the pending record remains the authority.
                return true
            } catch {
                pendingBootValidationLock = nil
                recoveryRequired = true
                ServiceLog.error("event=component_update result=rollback_failed")
                return false
            }
        }
    }

    func perform(_ payload: Data) throws -> ComponentUpdateResult {
        try queue.sync {
            let fileLock = try mutationLockForTransaction()
            defer { withExtendedLifetime(fileLock) {} }
            guard (try readPending()) == nil else {
                throw updateError("a component update is already awaiting recovery")
            }
            guard !payload.isEmpty, payload.count <= mihomoControlMaximumPayloadBytes else {
                throw updateError("component update payload exceeds the size limit")
            }
            let package = try ComponentUpdatePackage.decode(payload)
            let previousVersion = try validate(package)

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
                previousVersion: previousVersion,
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
                    // Keep the flock until this daemon exits. The replacement
                    // daemon reacquires it during startup and holds it through
                    // boot health validation plus commit or rollback.
                    pendingBootValidationLock = fileLock
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

    private func validate(_ package: ComponentUpdatePackage) throws -> String {
        guard package.formatVersion == ComponentUpdatePackage.currentFormatVersion,
              let proposed = semanticVersion(package.appVersion) else {
            throw updateError("invalid component update package version")
        }
        guard let installed = installedVersion(), let current = semanticVersion(installed) else {
            throw updateError("installed component version state is missing or invalid")
        }
        if semanticVersionPrecedes(proposed, current) {
            throw updateError("component downgrade requires an explicit signed repair")
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
        return installed
    }

    private func recoverInterruptedReplacementIfNeeded() throws {
        // A clean daemon launched by the signed installer must be able to start
        // while that installer holds the lock for its own end-to-end health
        // transaction. Only an actual pending component transaction requires
        // startup recovery and therefore lock participation.
        guard (try readPending()) != nil else { return }
        let fileLock = try ComponentMutationFileLock()
        defer { withExtendedLifetime(fileLock) {} }
        guard var pending = try readPending() else { return }
        switch pending.phase {
        case .replacing:
            try restore(pending)
            try clearPending(pending)
            requiresDaemonRestart = true
            ServiceLog.error("event=component_update result=recovered_interrupted_replacement")
        case .awaitingBootValidation:
            if pending.previousVersion == nil {
                // A daemon replaced by 0.8.0 can leave the old pending schema.
                // Freeze its still-uncommitted marker before boot validation:
                // commit writes the new marker before clearing pending, so a
                // later crash must never reinterpret that new value as the
                // rollback version.
                guard let previousVersion = installedVersion() else {
                    throw updateError("legacy pending component version state is unsafe")
                }
                pending.previousVersion = previousVersion
                try writePending(pending)
            }
            // Retaining the descriptor avoids a reentrant acquire when
            // ControlDispatcher later commits or rolls back after health.
            pendingBootValidationLock = fileLock
        }
    }

    private func mutationLockForTransaction() throws -> ComponentMutationFileLock {
        if let pendingBootValidationLock {
            return pendingBootValidationLock
        }
        return try ComponentMutationFileLock()
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
        guard let proposedVersion = semanticVersion(pending.appVersion) else {
            throw updateError("pending component update version is invalid")
        }
        let rollbackVersion: [String]
        if let previousVersion = pending.previousVersion {
            guard let parsed = semanticVersion(previousVersion) else {
                throw updateError("pending previous component version is invalid")
            }
            rollbackVersion = parsed
        } else {
            // 0.8.0 did not encode previousVersion. It never committed the new
            // version before boot validation, so the current strict marker is
            // the authoritative rollback floor for that old schema.
            guard let installed = installedVersion(),
                  let parsed = semanticVersion(installed) else {
                throw updateError("legacy pending component version state is unsafe")
            }
            rollbackVersion = parsed
        }
        guard pending.transactionName.hasPrefix(".component-update-"),
              !pending.transactionName.contains("/"),
              !semanticVersionPrecedes(proposedVersion, rollbackVersion),
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
        guard pending.previousVersion != nil else {
            throw updateError("new pending component update is missing its previous version")
        }
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
        let rollbackVersion: String
        if let previousVersion = pending.previousVersion {
            rollbackVersion = previousVersion
        } else {
            guard let installed = installedVersion() else {
                throw updateError("legacy pending component version state is unsafe")
            }
            rollbackVersion = installed
        }
        try writeInstalledVersion(rollbackVersion)
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
        let descriptor = Darwin.open(versionURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              lstat(versionURL.path, &pathMetadata) == 0,
              isSafeInstalledVersionMetadata(descriptorMetadata),
              isSafeInstalledVersionMetadata(pathMetadata),
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 65)
        var count = 0
        while count < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: count),
                    buffer.count - count
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if result == 0 { break }
            count += result
        }
        guard count <= 64 else { return nil }

        var finalDescriptorMetadata = stat()
        var finalPathMetadata = stat()
        guard fstat(descriptor, &finalDescriptorMetadata) == 0,
              lstat(versionURL.path, &finalPathMetadata) == 0,
              isSafeInstalledVersionMetadata(finalDescriptorMetadata),
              isSafeInstalledVersionMetadata(finalPathMetadata),
              finalDescriptorMetadata.st_dev == descriptorMetadata.st_dev,
              finalDescriptorMetadata.st_ino == descriptorMetadata.st_ino,
              finalPathMetadata.st_dev == descriptorMetadata.st_dev,
              finalPathMetadata.st_ino == descriptorMetadata.st_ino,
              finalDescriptorMetadata.st_size == off_t(count) else {
            return nil
        }
        return parseInstalledVersionData(Data(bytes.prefix(count)))
    }

    private func writeInstalledVersion(_ version: String) throws {
        let data = Data("\(version)\n".utf8)
        guard semanticVersion(version) != nil,
              parseInstalledVersionData(data) == version else {
            throw updateError("invalid installed component version")
        }
        var existingMetadata = stat()
        if lstat(versionURL.path, &existingMetadata) == 0 {
            guard installedVersion() != nil else {
                throw updateError("installed component version state is unsafe")
            }
        } else if errno != ENOENT {
            throw updateError("installed component version state is unavailable")
        }

        try data.write(to: versionURL, options: [.atomic])
        let descriptor = Darwin.open(versionURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw updateError("installed component version state could not be secured")
        }
        defer { Darwin.close(descriptor) }
        guard fchown(descriptor, 0, 0) == 0,
              fchmod(descriptor, mode_t(0o600)) == 0,
              installedVersion() == version else {
            throw updateError("installed component version state failed readback")
        }
    }

    private func semanticVersion(_ value: String) -> [String]? {
        guard !value.isEmpty, value.utf8.count <= 63 else { return nil }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var result: [String] = []
        for field in fields {
            guard !field.isEmpty,
                  field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  field == "0" || field.first != "0" else { return nil }
            result.append(String(field))
        }
        return result
    }

    private func semanticVersionPrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            if left.utf8.count != right.utf8.count {
                return left.utf8.count < right.utf8.count
            }
            return left.lexicographicallyPrecedes(right)
        }
        return false
    }

    private func isSafeInstalledVersionMetadata(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & 0o7777 == 0o600
            && metadata.st_uid == 0
            && metadata.st_gid == 0
            && metadata.st_size > 0
            && metadata.st_size <= 64
    }

    private func parseInstalledVersionData(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 64, data.last == 0x0A else { return nil }
        let versionBytes = data.dropLast()
        guard !versionBytes.isEmpty, !versionBytes.contains(0x0A),
              let version = String(bytes: versionBytes, encoding: .ascii),
              semanticVersion(version) != nil else {
            return nil
        }
        return version
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
