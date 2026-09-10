import Darwin
import Foundation
import MihomoControl

struct LocalDoHStatusProvider {
    private static let profilesExecutable = "/usr/bin/profiles"

    static func inspectInstalledProfile() -> (
        succeeded: Bool,
        inspection: LocalDoHProfileInspection
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

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return (false, .init(installed: false))
            }
            // `profiles` exits successfully with a short plain-text message
            // when the fixed identifier is absent. Only plist output can prove
            // installation; absence is still a successful inspection.
            let inspection = LocalDoHProfileInspection.inspect(propertyList: data)
                ?? .init(installed: false)
            return (true, inspection)
        } catch {
            return (false, .init(installed: false))
        }
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
}
