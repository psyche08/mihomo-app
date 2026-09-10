import Darwin
import Foundation
import MihomoControl
import MihomoDNSCore

/// Owns the fixed Local DoH privileged mutation behind authenticated XPC.
///
/// This deliberately exposes no paths, certificate material, hostnames,
/// ports, domains, or arbitrary commands. The daemon stays alive throughout;
/// ProfileBroker stops only the supervised network agent and rolls its runtime
/// configuration back before returning an error.
final class LocalDoHManager: @unchecked Sendable {
    private struct IdentitySnapshot {
        let directory: URL
        let hadIdentityDirectory: Bool
        let wasTrusted: Bool
    }

    private let agent: AgentSupervisor
    private let controller: ControllerBroker
    private let profiles: ProfileBroker
    private let root: URL
    private let identityDirectory: URL
    private let caCertificate: URL
    private let serverCertificate: URL
    private let serverKey: URL
    private let fingerprintFile: URL
    private let command = FixedLocalDoHCommandRunner()

    init(
        agent: AgentSupervisor,
        controller: ControllerBroker,
        profiles: ProfileBroker,
        root: URL = URL(
            fileURLWithPath: "/Library/Application Support/Mihomo App",
            isDirectory: true
        )
    ) {
        self.agent = agent
        self.controller = controller
        self.profiles = profiles
        self.root = root
        identityDirectory = root.appendingPathComponent("local-doh", isDirectory: true)
        caCertificate = identityDirectory.appendingPathComponent("ca.crt")
        serverCertificate = identityDirectory.appendingPathComponent("server.crt")
        serverKey = identityDirectory.appendingPathComponent("server.key")
        fingerprintFile = identityDirectory.appendingPathComponent("certificate.sha1")
    }

    func install() throws -> LocalDoHPlanSummary {
        guard agent.isRunning else {
            throw localDoHError("Mihomo agent is not running")
        }
        let summary = try controller.prepareLocalDoHProfile()
        guard LocalDoHStatusProvider.inspectPreparedProfile().installed else {
            throw localDoHError("the fixed root-owned Local DoH profile is invalid")
        }

        let snapshot = try captureIdentitySnapshot()
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        try profiles.transitionLocalDoH(
            enabled: true,
            afterNetworkStopped: { try self.prepareIdentity() },
            rollbackAfterNetworkStopped: { try self.restoreIdentity(snapshot) }
        )
        ServiceLog.info("event=local_doh_install result=prepared_for_profile_approval")
        return summary
    }

    func remove() throws {
        let installed = LocalDoHStatusProvider.inspectInstalledProfile()
        guard installed.succeeded else {
            throw localDoHError("macOS could not inspect the Local DoH profile")
        }
        if installed.inspection.installed {
            try command.run(
                "/usr/bin/profiles",
                [
                    "remove", "-type", "configuration",
                    "-identifier", LocalDoHStatus.profileIdentifier,
                    "-forced",
                ],
                timeout: 30
            )
            let verified = LocalDoHStatusProvider.inspectInstalledProfile()
            guard verified.succeeded, !verified.inspection.installed else {
                throw localDoHError("macOS did not confirm Local DoH profile removal")
            }
        }

        try profiles.transitionLocalDoH(
            enabled: false,
            afterNetworkStopped: {},
            rollbackAfterNetworkStopped: {}
        )
        try removeCurrentTrust()
        if FileManager.default.fileExists(atPath: identityDirectory.path) {
            try validateIdentityDirectory()
            try FileManager.default.removeItem(at: identityDirectory)
        }
        let profile = URL(fileURLWithPath: LocalDoHProfileDocument.managedProfilePath)
        if FileManager.default.fileExists(atPath: profile.path) {
            try FileManager.default.removeItem(at: profile)
        }
        ServiceLog.info("event=local_doh_remove result=success")
    }

    private func captureIdentitySnapshot() throws -> IdentitySnapshot {
        let snapshot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("mihomobox-local-doh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let exists = FileManager.default.fileExists(atPath: identityDirectory.path)
            if exists {
                try validateIdentityDirectory()
                try FileManager.default.copyItem(
                    at: identityDirectory,
                    to: snapshot.appendingPathComponent("identity", isDirectory: true)
                )
            }
            return IdentitySnapshot(
                directory: snapshot,
                hadIdentityDirectory: exists,
                wasTrusted: identityIsSystemTrusted()
            )
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }

    private func restoreIdentity(_ snapshot: IdentitySnapshot) throws {
        try removeCurrentTrust()
        if FileManager.default.fileExists(atPath: identityDirectory.path) {
            try validateIdentityDirectory()
            try FileManager.default.removeItem(at: identityDirectory)
        }
        guard snapshot.hadIdentityDirectory else { return }
        let backup = snapshot.directory.appendingPathComponent("identity", isDirectory: true)
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw localDoHError("the Local DoH identity rollback snapshot is incomplete")
        }
        try FileManager.default.copyItem(at: backup, to: identityDirectory)
        try validateIdentityDirectory()
        if snapshot.wasTrusted {
            try addCurrentTrust()
            guard identityIsSystemTrusted() else {
                throw localDoHError("the previous Local DoH trust could not be restored")
            }
        }
    }

    private func prepareIdentity() throws {
        if FileManager.default.fileExists(atPath: identityDirectory.path) {
            try validateIdentityDirectory()
        } else {
            try FileManager.default.createDirectory(
                at: identityDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if !identityIsValid() {
            try removeCurrentTrust()
            try FileManager.default.removeItem(at: identityDirectory)
            try FileManager.default.createDirectory(
                at: identityDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try generateIdentity()
        }
        try applyIdentityMetadata()
        try command.run(
            "/usr/bin/security",
            [
                "verify-cert", "-c", serverCertificate.path,
                "-r", caCertificate.path, "-p", "ssl", "-s", "127.0.0.1",
            ]
        )
        let fingerprint = try currentFingerprint()
        try Data("\(fingerprint)\n".utf8).write(to: fingerprintFile, options: [.atomic])
        guard chown(fingerprintFile.path, 0, 0) == 0,
              chmod(fingerprintFile.path, 0o600) == 0 else {
            throw localDoHError("the Local DoH fingerprint metadata could not be secured")
        }
        if !identityIsSystemTrusted() {
            try addCurrentTrust()
        }
        guard identityIsSystemTrusted() else {
            throw localDoHError("macOS did not trust the Local DoH certificate authority")
        }
    }

    private func generateIdentity() throws {
        let caKey = identityDirectory.appendingPathComponent(".ca.key")
        let request = identityDirectory.appendingPathComponent(".server.csr")
        let extensions = identityDirectory.appendingPathComponent(".server.ext")
        let serial = identityDirectory.appendingPathComponent(".ca.srl")
        defer {
            for file in [caKey, request, extensions, serial] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try command.run(
            "/usr/bin/openssl",
            [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-days", "825", "-subj", "/CN=MihomoBox Local DoH Root CA",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout", caKey.path, "-out", caCertificate.path,
            ],
            timeout: 30
        )
        try command.run(
            "/usr/bin/openssl",
            [
                "req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-subj", "/CN=127.0.0.1", "-keyout", serverKey.path,
                "-out", request.path,
            ],
            timeout: 30
        )
        try Data(
            """
            subjectAltName=IP:127.0.0.1,DNS:localhost
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            """.utf8
        ).write(to: extensions, options: [.atomic])
        try command.run(
            "/usr/bin/openssl",
            [
                "x509", "-req", "-in", request.path,
                "-CA", caCertificate.path, "-CAkey", caKey.path,
                "-CAcreateserial", "-CAserial", serial.path,
                "-days", "825", "-sha256", "-extfile", extensions.path,
                "-out", serverCertificate.path,
            ],
            timeout: 30
        )
    }

    private func identityIsValid() -> Bool {
        guard isRegularRootFile(caCertificate, maximumBytes: 128 * 1_024),
              isRegularRootFile(serverCertificate, maximumBytes: 128 * 1_024),
              isRegularRootFile(serverKey, maximumBytes: 128 * 1_024),
              command.succeeds(
                  "/usr/bin/openssl",
                  ["x509", "-in", caCertificate.path, "-noout", "-checkend", "86400"]
              ),
              command.succeeds(
                  "/usr/bin/openssl",
                  ["x509", "-in", serverCertificate.path, "-noout", "-checkend", "86400"]
              ),
              command.succeeds(
                  "/usr/bin/openssl",
                  ["verify", "-CAfile", caCertificate.path, serverCertificate.path]
              ),
              let certificateModulus = try? command.output(
                  "/usr/bin/openssl",
                  ["x509", "-in", serverCertificate.path, "-noout", "-modulus"]
              ),
              let keyModulus = try? command.output(
                  "/usr/bin/openssl",
                  ["rsa", "-in", serverKey.path, "-noout", "-modulus"]
              ) else { return false }
        return !certificateModulus.isEmpty && certificateModulus == keyModulus
    }

    private func identityIsSystemTrusted() -> Bool {
        guard isRegularRootFile(serverCertificate, maximumBytes: 128 * 1_024) else {
            return false
        }
        return command.succeeds(
            "/usr/bin/security",
            [
                "verify-cert", "-c", serverCertificate.path,
                "-p", "ssl", "-s", "127.0.0.1",
            ]
        )
    }

    private func addCurrentTrust() throws {
        guard isRegularRootFile(caCertificate, maximumBytes: 128 * 1_024) else {
            throw localDoHError("the Local DoH certificate authority is unavailable")
        }
        try command.run(
            "/usr/bin/security",
            [
                "add-trusted-cert", "-d", "-r", "trustRoot",
                "-k", "/Library/Keychains/System.keychain", caCertificate.path,
            ]
        )
    }

    private func removeCurrentTrust() throws {
        let anchor = isRegularRootFile(caCertificate, maximumBytes: 128 * 1_024)
            ? caCertificate
            : serverCertificate
        if isRegularRootFile(anchor, maximumBytes: 128 * 1_024) {
            command.runAllowingFailure(
                "/usr/bin/security",
                ["remove-trusted-cert", "-d", anchor.path]
            )
        }
        if let fingerprint = try? currentFingerprint() {
            command.runAllowingFailure(
                "/usr/bin/security",
                [
                    "delete-certificate", "-Z", fingerprint,
                    "/Library/Keychains/System.keychain",
                ]
            )
        }
    }

    private func currentFingerprint() throws -> String {
        let anchor = isRegularRootFile(caCertificate, maximumBytes: 128 * 1_024)
            ? caCertificate
            : serverCertificate
        guard isRegularRootFile(anchor, maximumBytes: 128 * 1_024) else {
            throw localDoHError("the Local DoH trust anchor is unavailable")
        }
        let output = try command.output(
            "/usr/bin/openssl",
            ["x509", "-in", anchor.path, "-noout", "-fingerprint", "-sha1"]
        )
        guard let separator = output.lastIndex(of: "=") else {
            throw localDoHError("the Local DoH certificate fingerprint is invalid")
        }
        let value = output[output.index(after: separator)...]
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard value.count == 40,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
              }) else {
            throw localDoHError("the Local DoH certificate fingerprint is invalid")
        }
        return value
    }

    private func applyIdentityMetadata() throws {
        guard chmod(identityDirectory.path, 0o700) == 0,
              chown(identityDirectory.path, 0, 0) == 0 else {
            throw localDoHError("the Local DoH identity directory could not be secured")
        }
        for file in [caCertificate, serverCertificate] {
            guard chown(file.path, 0, 0) == 0, chmod(file.path, 0o644) == 0 else {
                throw localDoHError("the Local DoH certificate metadata could not be secured")
            }
        }
        guard chown(serverKey.path, 0, 0) == 0, chmod(serverKey.path, 0o600) == 0 else {
            throw localDoHError("the Local DoH private key metadata could not be secured")
        }
    }

    private func validateIdentityDirectory() throws {
        var metadata = stat()
        guard lstat(identityDirectory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == 0, metadata.st_gid == 0,
              metadata.st_mode & 0o777 == 0o700 else {
            throw localDoHError("the Local DoH identity directory is unsafe")
        }
    }

    private func isRegularRootFile(_ url: URL, maximumBytes: Int) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == 0 && metadata.st_gid == 0
            && metadata.st_size > 0 && metadata.st_size <= maximumBytes
    }

    private func localDoHError(_ message: String) -> Error {
        NSError(
            domain: "MihomoLocalDoH",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct FixedLocalDoHCommandRunner {
    func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) throws {
        _ = try execute(executable, arguments, captureOutput: false, timeout: timeout)
    }

    func output(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) throws -> String {
        String(
            decoding: try execute(
                executable,
                arguments,
                captureOutput: true,
                timeout: timeout
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func succeeds(_ executable: String, _ arguments: [String]) -> Bool {
        (try? execute(executable, arguments, captureOutput: false, timeout: 15)) != nil
    }

    func runAllowingFailure(_ executable: String, _ arguments: [String]) {
        _ = try? execute(executable, arguments, captureOutput: false, timeout: 15)
    }

    private func execute(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool,
        timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        let pipe = captureOutput ? Pipe() : nil
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminateDeadline { usleep(50_000) }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline { usleep(50_000) }
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw NSError(
                domain: "MihomoLocalDoHCommand",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "a fixed Local DoH system operation failed"]
            )
        }
        return pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    }
}
