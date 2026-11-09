import Darwin
import Foundation
import MihomoDNSCore

/// Removes what the retired LocalHttpDns feature installed: its split-DNS
/// configuration profile (which would otherwise keep pointing matched domains
/// at a listener that no longer exists), the System keychain trust anchor, and
/// the root-owned identity files. Every command and path is fixed; nothing
/// from profile or certificate contents reaches a log.
final class LegacyLocalDoHCleanup: @unchecked Sendable {
    private let support: URL
    private let lock = NSLock()
    private var profileConfirmedAbsent = false

    init(support: URL = URL(fileURLWithPath: "/Library/Application Support/Mihomo App")) {
        self.support = support
    }

    /// Whether a previous run proved the legacy profile absent.
    var profileRemoved: Bool {
        lock.lock(); defer { lock.unlock() }
        return profileConfirmedAbsent
    }

    /// Idempotent. Returns whether the legacy profile is confirmed absent.
    @discardableResult
    func run() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if profileConfirmedAbsent, !legacyFilesPresent() { return true }
        let profile = removeProfile()
        profileConfirmedAbsent = profile == "absent" || profile == "removed"
        if profile == "removed" { DNSCacheMaintenance.flushSystemCaches() }
        let trust = removeTrust()
        let files = removeFiles()
        if profile != "absent" || trust != "absent" || files != "absent" {
            let line = "event=legacy_local_doh_cleanup profile=\(profile) " +
                "trust=\(trust) files=\(files)"
            if profileConfirmedAbsent { ServiceLog.info(line) } else { ServiceLog.error(line) }
        }
        return profileConfirmedAbsent
    }

    private func legacyFilesPresent() -> Bool {
        [LegacyLocalDoH.identityDirectory, LegacyLocalDoH.preparedProfile, LegacyLocalDoH.ipcDirectory]
            .contains { FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path) }
    }

    private func profilePresence() -> Bool? {
        guard let output = try? FixedCommand.output("/usr/bin/profiles", [
            "show", "-type", "configuration",
            "-identifier", LegacyLocalDoH.profileIdentifier,
            "-output", "stdout-xml",
        ]) else { return nil }
        return LegacyLocalDoH.profilePresence(in: output)
    }

    private func removeProfile() -> String {
        switch profilePresence() {
        case false?:
            return "absent"
        case nil:
            return "unknown"
        case true?:
            _ = try? FixedCommand.output("/usr/bin/profiles", [
                "remove", "-type", "configuration",
                "-identifier", LegacyLocalDoH.profileIdentifier, "-forced",
            ])
            return profilePresence() == false ? "removed" : "removal_required"
        }
    }

    private func removeTrust() -> String {
        let directory = support.appendingPathComponent(LegacyLocalDoH.identityDirectory)
        let anchor = [directory.appendingPathComponent("ca.crt"),
                      directory.appendingPathComponent("server.crt")]
            .first { Self.isRegularRootFile($0) }
        let fingerprint = Self.isRegularRootFile(directory.appendingPathComponent("certificate.sha1"))
            ? (try? Data(contentsOf: directory.appendingPathComponent("certificate.sha1")))
                .flatMap(LegacyLocalDoH.storedFingerprint)
            : nil
        guard anchor != nil || fingerprint != nil else { return "absent" }
        var removed = true
        if let anchor {
            removed = (try? FixedCommand.output(
                "/usr/bin/security", ["remove-trusted-cert", "-d", anchor.path]
            )) != nil && removed
        }
        if let fingerprint {
            removed = (try? FixedCommand.output("/usr/bin/security", [
                "delete-certificate", "-Z", fingerprint, "/Library/Keychains/System.keychain",
            ])) != nil && removed
        }
        // Either command fails harmlessly when the user already removed the
        // anchor. Files are deleted afterwards, so this runs at most once.
        return removed ? "removed" : "partially_removed"
    }

    private func removeFiles() -> String {
        var found = false
        var failed = false
        for relative in [LegacyLocalDoH.identityDirectory, LegacyLocalDoH.preparedProfile,
                         LegacyLocalDoH.ipcDirectory] {
            let url = support.appendingPathComponent(relative)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            found = true
            do { try FileManager.default.removeItem(at: url) } catch { failed = true }
        }
        return !found ? "absent" : (failed ? "failed" : "removed")
    }

    private static func isRegularRootFile(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == 0
            && metadata.st_size <= 65_536
    }
}

/// Runs one fixed system tool with a bounded wait and no inherited input.
enum FixedCommand {
    struct Failed: Error {}

    static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard process.terminationStatus == 0 else { throw Failed() }
        return data
    }
}
