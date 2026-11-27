import Darwin
import Foundation

/// Deletes one stored profile from the daemon's profile directory.
///
/// The active profile is refused: the running configuration was rendered from
/// it, and profile reload and App Proxy routing read it again.
public enum StoredProfileDeletion {
    public enum Failure: Error, Equatable, LocalizedError {
        case active
        case missing
        case notRegularFile
        case removeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .active: "the active profile cannot be deleted; switch to another profile first"
            case .missing: "profile does not exist"
            case .notRegularFile: "stored profile is not a regular file"
            case .removeFailed(let code): "profile could not be deleted: \(String(cString: strerror(code)))"
            }
        }
    }

    /// `name` must already be a validated profile filename. It has to match a
    /// directory entry exactly: on a case-insensitive volume a differently
    /// cased name would otherwise reach another profile's file, including the
    /// active one.
    public static func delete(name: String, in directory: URL, activeProfile: String?) throws {
        if let activeProfile, activeProfile.compare(name, options: .caseInsensitive) == .orderedSame {
            throw Failure.active
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard entries.contains(name) else { throw Failure.missing }
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        var status = stat()
        guard lstat(path, &status) == 0 else { throw Failure.missing }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegularFile }
        guard unlink(path) == 0 else { throw Failure.removeFailed(errno) }
    }
}
