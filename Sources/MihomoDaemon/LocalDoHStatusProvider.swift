import Darwin
import Foundation
import MihomoControl

struct LocalDoHStatusProvider {
    private static let profilesExecutable = "/usr/bin/profiles"

    static func inspectInstalledProfile() -> (
        succeeded: Bool,
        inspection: LocalDoHProfileInspection,
        present: Bool?
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: profilesExecutable)
        process.arguments = [
            "show",
            "-type", "configuration",
            "-identifier", LocalDoHStatus.profileIdentifier,
            "-output", "stdout-xml",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        do {
            try process.run()
            // This inspection also runs under lifecycle serialization. A
            // stuck profiles service must not block stop/repair indefinitely.
            let timeout = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return (false, .init(installed: false), nil)
            }
            // `profiles` exits successfully with a short plain-text message
            // when the fixed identifier is absent. Only plist output can prove
            // installation; absence is still a successful inspection.
            let certificatePath = URL(
                fileURLWithPath: LocalDoHProfileDocument.managedProfilePath
            ).deletingLastPathComponent().appendingPathComponent("local-doh/ca.der")
            let rootCertificate = secureRootCertificate(at: certificatePath)
            let inspection = rootCertificate.flatMap {
                LocalDoHProfileInspection.validatedInstalled(
                    propertyList: data,
                    expectedRootCertificate: $0,
                    expectedPreparedProfile: securePreparedProfile()
                )
            } ?? .init(installed: false)
            let present = LocalDoHProfileInspection.presence(in: data)
            return (present != nil, inspection, present)
        } catch {
            return (false, .init(installed: false), nil)
        }
    }

    static func certificateTrusted() -> Bool {
        let directory = URL(fileURLWithPath: LocalDoHProfileDocument.managedProfilePath)
            .deletingLastPathComponent().appendingPathComponent("local-doh")
        guard let root = secureRootCertificate(at: directory.appendingPathComponent("ca.der")),
              let server = secureRootCertificate(at: directory.appendingPathComponent("server.crt"))
        else { return false }
        return LocalDoHTLSValidation.systemTrusts(serverPEM: server, rootDER: root)
    }

    private static func securePreparedProfile() -> Data? {
        let path = LocalDoHProfileDocument.managedProfilePath
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0, metadata.st_gid == 0,
              metadata.st_mode & 0o777 == 0o644,
              metadata.st_size > 0, metadata.st_size <= 64 * 1_024 * 1_024 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func inspectPreparedProfile() -> LocalDoHProfileInspection {
        let path = LocalDoHProfileDocument.managedProfilePath
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_gid == 0,
              metadata.st_mode & 0o777 == 0o644,
              metadata.st_size > 0,
              metadata.st_size <= 64 * 1_024 * 1_024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .init(installed: false)
        }
        let certificatePath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("local-doh/ca.der")
        var certificateMetadata = stat()
        guard lstat(certificatePath.path, &certificateMetadata) == 0,
              certificateMetadata.st_mode & S_IFMT == S_IFREG,
              certificateMetadata.st_uid == 0,
              certificateMetadata.st_gid == 0,
              certificateMetadata.st_mode & 0o777 == 0o644,
              certificateMetadata.st_size > 0,
              certificateMetadata.st_size <= 128 * 1_024,
              let rootCertificate = try? Data(
                  contentsOf: certificatePath,
                  options: [.mappedIfSafe]
              ),
              let domainCount = LocalDoHProfileDocument.validatedDomainCount(
                  in: data,
                  expectedRootCertificate: rootCertificate
              ) else {
            return .init(installed: false)
        }
        return .init(installed: true, domainCount: domainCount)
    }

    private static func secureRootCertificate(at url: URL) -> Data? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_gid == 0,
              metadata.st_mode & 0o777 == 0o644,
              metadata.st_size > 0,
              metadata.st_size <= 128 * 1_024 else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
