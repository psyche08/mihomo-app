import Darwin
import Foundation
import MihomoControl
import MihomoDNSCore

/// Owns the fixed Local DoH privileged mutation behind authenticated XPC.
///
/// This deliberately exposes no paths, certificate material, hostnames,
/// ports, domains, or arbitrary commands. It updates only the daemon-owned TLS
/// identity and prepared profile; the standby Mihomo/controller stays alive so
/// the domain plan can be generated before Enhanced TUN is enabled.
final class LocalDoHManager: @unchecked Sendable {
    private struct IdentitySnapshot {
        let directory: URL
        let hadIdentityDirectory: Bool
        let hadPreparedProfile: Bool
    }

    private let agent: AgentSupervisor
    private let controller: ControllerBroker
    private let server: IndependentLocalDoHServer
    private let root: URL
    private let identityDirectory: URL
    private let caCertificate: URL
    private let caCertificateDER: URL
    private let serverCertificate: URL
    private let serverKey: URL
    private let fingerprintFile: URL
    private let command = FixedLocalDoHCommandRunner()

    init(
        agent: AgentSupervisor,
        controller: ControllerBroker,
        server: IndependentLocalDoHServer,
        root: URL = URL(
            fileURLWithPath: "/Library/Application Support/Mihomo App",
            isDirectory: true
        )
    ) {
        self.agent = agent
        self.controller = controller
        self.server = server
        self.root = root
        identityDirectory = root.appendingPathComponent("local-doh", isDirectory: true)
        caCertificate = identityDirectory.appendingPathComponent("ca.crt")
        caCertificateDER = identityDirectory.appendingPathComponent("ca.der")
        serverCertificate = identityDirectory.appendingPathComponent("server.crt")
        serverKey = identityDirectory.appendingPathComponent("server.key")
        fingerprintFile = identityDirectory.appendingPathComponent("certificate.sha1")
    }

    func install() throws -> LocalDoHPlanSummary {
        guard agent.isRunning else {
            throw localDoHError("Mihomo agent is not running")
        }
        guard agent.usesLocalDoH, !agent.managesSystemDNS else {
            throw localDoHError("Install or repair the root helper before preparing LocalHttpDns")
        }
        // No rule/geosite expansion is needed for the default global resolver.
        // Empty suffix denotes global scope internally; the document omits
        // SupplementalMatchDomains, as required by the macOS DNS payload.
        let plan = LocalDoHDomainPlan(domains: [""])

        let snapshot = try captureIdentitySnapshot()
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        do {
            // Reload the in-memory TLS identity when regeneration replaces an
            // expired certificate at the same fixed paths.
            if !identityIsValid() {
                server.stopServing()
            }
            try prepareIdentity()
            let rootCertificate = try readRootCertificateDER()
            try controller.writeLocalDoHProfile(plan: plan, rootCertificate: rootCertificate)
            guard LocalDoHStatusProvider.inspectPreparedProfile().installed else {
                throw localDoHError("the fixed root-owned Local DoH profile is invalid")
            }
            guard try server.startIfPrepared() else {
                throw localDoHError("the independent Local DoH server did not start")
            }
            // A prior fallback cancels supervision as well as the listener.
            // Successful preparation explicitly re-enables both.
            guard server.startSupervising() else {
                throw localDoHError("the independent Local DoH server could not be supervised")
            }
        } catch {
            server.stopServing()
            try restoreIdentity(snapshot)
            _ = try server.startIfPrepared()
            throw error
        }
        ServiceLog.info("event=local_doh_install result=prepared_for_profile_approval")
        return plan.summary
    }

    /// Explicit authenticated user action only: never called by startup,
    /// status polling, listener recovery, or profile preparation. macOS owns
    /// any authorization UI; cancellation/timeout is not a reason to weaken
    /// authorization policy or unlock a keychain.
    func trustCertificate() throws {
        guard root.path == "/Library/Application Support/Mihomo App" else {
            throw localDoHError("certificate trust requires the fixed installed identity")
        }
        try validateIdentityDirectory()
        guard identityIsValid(), LocalDoHStatusProvider.inspectPreparedProfile().installed else {
            throw localDoHError("prepare the current Local DoH identity and profile before trusting it")
        }
        if LocalDoHStatusProvider.certificateTrusted() { return }
        do {
            try command.run(
                LocalDoHTrustCommand.executable,
                LocalDoHTrustCommand.arguments,
                timeout: LocalDoHTrustCommand.timeout
            )
        } catch {
            // Import and trust are separate system operations. Do not erase a
            // successfully imported certificate or retry a cancelled prompt.
            throw localDoHError(
                "SSL trust was not completed (authorization may have been cancelled, denied, or timed out). " +
                "Retry Trust Certificate, or approve the current MihomoBox Local DoH Root CA for SSL in Keychain Access."
            )
        }
        guard LocalDoHStatusProvider.certificateTrusted() else {
            throw localDoHError(
                "the certificate was installed but system SSL verification still failed; " +
                "review the current MihomoBox Local DoH Root CA in Keychain Access"
            )
        }
        ServiceLog.info("event=local_doh_trust result=ssl_verified")
    }

    /// A split encrypted-DNS payload overrides the plain Global resolver for
    /// its matched domains. Remove only our fixed profile before reporting a
    /// completed fallback. Identity and prepared profile remain for retry.
    func removeProfileForGlobalDNSFallback() -> Bool {
        let before = LocalDoHStatusProvider.inspectInstalledProfile()
        guard before.present != false else { return true }
        guard command.succeeds("/usr/bin/profiles", [
            "remove", "-type", "configuration",
            "-identifier", LocalDoHStatus.profileIdentifier, "-forced",
        ]) else { return false }
        let after = LocalDoHStatusProvider.inspectInstalledProfile()
        return after.succeeded && after.present == false
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
                hadPreparedProfile: try capturePreparedProfile(in: snapshot)
            )
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }

    private func restoreIdentity(_ snapshot: IdentitySnapshot) throws {
        if FileManager.default.fileExists(atPath: identityDirectory.path) {
            try validateIdentityDirectory()
            try FileManager.default.removeItem(at: identityDirectory)
        }
        if snapshot.hadIdentityDirectory {
            let backup = snapshot.directory.appendingPathComponent("identity", isDirectory: true)
            guard FileManager.default.fileExists(atPath: backup.path) else {
                throw localDoHError("the Local DoH identity rollback snapshot is incomplete")
            }
            try FileManager.default.copyItem(at: backup, to: identityDirectory)
            try validateIdentityDirectory()
        }
        try restorePreparedProfile(from: snapshot)
    }

    private func capturePreparedProfile(in snapshot: URL) throws -> Bool {
        let profile = URL(fileURLWithPath: LocalDoHProfileDocument.managedProfilePath)
        guard FileManager.default.fileExists(atPath: profile.path) else { return false }
        try FileManager.default.copyItem(
            at: profile,
            to: snapshot.appendingPathComponent("prepared.mobileconfig")
        )
        return true
    }

    private func restorePreparedProfile(from snapshot: IdentitySnapshot) throws {
        let profile = URL(fileURLWithPath: LocalDoHProfileDocument.managedProfilePath)
        if FileManager.default.fileExists(atPath: profile.path) {
            try FileManager.default.removeItem(at: profile)
        }
        guard snapshot.hadPreparedProfile else { return }
        let backup = snapshot.directory.appendingPathComponent("prepared.mobileconfig")
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw localDoHError("the Local DoH profile rollback snapshot is incomplete")
        }
        try FileManager.default.copyItem(at: backup, to: profile)
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
                "x509", "-in", caCertificate.path, "-outform", "DER",
                "-out", caCertificateDER.path,
            ]
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
              isRegularRootFile(caCertificateDER, maximumBytes: 128 * 1_024),
              isRegularRootFile(serverCertificate, maximumBytes: 128 * 1_024),
              isRegularRootFile(serverKey, maximumBytes: 128 * 1_024),
              command.succeeds(
                  "/usr/bin/openssl",
                  ["x509", "-in", caCertificate.path, "-noout", "-checkend", "86400"]
              ),
              command.succeeds(
                  "/usr/bin/openssl",
                  [
                      "x509", "-inform", "DER", "-in", caCertificateDER.path,
                      "-noout", "-checkend", "86400",
                  ]
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
              ),
              let pemFingerprint = try? command.output(
                  "/usr/bin/openssl",
                  ["x509", "-in", caCertificate.path, "-noout", "-fingerprint", "-sha256"]
              ),
              let derFingerprint = try? command.output(
                  "/usr/bin/openssl",
                  [
                      "x509", "-inform", "DER", "-in", caCertificateDER.path,
                      "-noout", "-fingerprint", "-sha256",
                  ]
              ) else { return false }
        return !certificateModulus.isEmpty && certificateModulus == keyModulus
            && !pemFingerprint.isEmpty && pemFingerprint == derFingerprint
    }

    private func readRootCertificateDER() throws -> Data {
        guard isRegularRootFile(caCertificateDER, maximumBytes: 128 * 1_024) else {
            throw localDoHError("the Local DoH root certificate is unavailable")
        }
        return try Data(contentsOf: caCertificateDER, options: [.mappedIfSafe])
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
        for file in [caCertificate, caCertificateDER, serverCertificate] {
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
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < terminateDeadline { usleep(50_000) }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { usleep(50_000) }
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw NSError(
                domain: "MihomoLocalDoHCommand",
                code: process.isRunning ? -1 : Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "a fixed Local DoH system operation failed"]
            )
        }
        return pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    }
}
