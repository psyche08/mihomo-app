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
}
