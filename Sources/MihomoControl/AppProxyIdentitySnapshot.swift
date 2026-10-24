import Foundation
import Darwin
import Security

/// Shared host / sandbox broker / provider wire contract. Never contains traffic or credentials.
public enum AppProxyIdentityFailure: String, Error, Codable, Sendable {
    case malformed, permission, signature, changedFile, escapedPath, missingFile, staleAuthorization
    case wrongUser, generationMismatch, capacity, needsAuthorization, unavailable, runtimeIdentity, undiscoveredTarget
}

public struct AppProxyFileStamp: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modified: Int64
    public let modifiedNS: Int64
    public let changed: Int64
    public let changedNS: Int64

    public static func isCanonicalPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")
            && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    /// Reject links in every component without requiring access to parent directories.
    public static func read(_ path: String) throws -> Self {
        guard Self.isCanonicalPath(path) else { throw AppProxyIdentityFailure.escapedPath }
        // Opening ancestor directory FDs requires extra sandbox privileges even with O_EVTONLY.
        // Darwin's public O_NOFOLLOW_ANY rejects links in *all* path components in one open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: throw AppProxyIdentityFailure.missingFile
            case ELOOP, ENOTDIR: throw AppProxyIdentityFailure.escapedPath
            default: throw AppProxyIdentityFailure.permission
            }
        }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { throw AppProxyIdentityFailure.escapedPath }
        return Self(device: s.st_dev, inode: s.st_ino, size: s.st_size,
                    modified: Int64(s.st_mtimespec.tv_sec), modifiedNS: Int64(s.st_mtimespec.tv_nsec),
                    changed: Int64(s.st_ctimespec.tv_sec), changedNS: Int64(s.st_ctimespec.tv_nsec))
    }
}

public struct AppProxyCodeIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let category: String
    public let requirement: String
    public let team: String?
    public let cdHash: Data
    public let stamp: AppProxyFileStamp

    /// Security.framework treats a bundle executable as its enclosing code package.
    /// Grant the nearest package, never an updater's version tree or user-data directory.
    public static func accessURL(for path: String) throws -> URL {
        guard AppProxyFileStamp.isCanonicalPath(path) else { throw AppProxyIdentityFailure.escapedPath }
        let executable = URL(fileURLWithPath: path)
        var parent = executable.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app" {
                guard path.hasPrefix(parent.path + "/Contents/") else { throw AppProxyIdentityFailure.escapedPath }
                return parent
            }
            parent.deleteLastPathComponent()
        }
        return executable
    }

    public func validateAccessScope() throws {
        let root = try Self.accessURL(for: path)
        if root.path != path {
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw AppProxyIdentityFailure.escapedPath }
            close(fd)
        }
        // A capability must not give effective write access to the executable or its metadata.
        var checked = [path]
        if root.path != path {
            checked += ["Contents/Info.plist", "Contents/CodeResources", "Contents/_CodeSignature/CodeResources"].map {
                root.appendingPathComponent($0).path
            }
            guard access(root.path, W_OK) != 0 else { throw AppProxyIdentityFailure.permission }
        }
        for file in checked {
            let fd = open(file, O_WRONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
            if fd >= 0 { close(fd); throw AppProxyIdentityFailure.permission }
        }
    }

    public static func inspect(path: String, category: String, team: String? = nil, identifier: String? = nil) throws -> Self {
        let before = try AppProxyFileStamp.read(path)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw AppProxyIdentityFailure.signature
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let v = info as? [String: Any], let id = v[kSecCodeInfoIdentifier as String] as? String,
              let hash = v[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { throw AppProxyIdentityFailure.signature }
        let actualTeam = v[kSecCodeInfoTeamIdentifier as String] as? String
        if let identifier, identifier != id { throw AppProxyIdentityFailure.signature }
        if let team {
            var anchor: SecRequirement?
            guard actualTeam == team,
                  SecRequirementCreateWithString("anchor apple generic" as CFString, [], &anchor) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, [], anchor) == errSecSuccess else { throw AppProxyIdentityFailure.signature }
        }
        var req: SecRequirement?; var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { throw AppProxyIdentityFailure.signature }
        guard try AppProxyFileStamp.read(path) == before else { throw AppProxyIdentityFailure.changedFile }
        return Self(id: id, path: path, category: category, requirement: text as String, team: actualTeam, cdHash: hash, stamp: before)
    }

    public func validateFile() throws {
        guard try Self.inspect(path: path, category: category, team: team, identifier: id) == self else {
            throw AppProxyIdentityFailure.changedFile
        }
    }
}

public struct AppProxyIdentitySnapshot: Codable, Equatable, Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let version: Int
    public let generation: UUID
    public let ownerUID: UInt32
    public let records: [AppProxyCodeIdentity]
    public let grants: [Data]
    public init(ownerUID: UInt32, records: [AppProxyCodeIdentity], grants: [Data], generation: UUID = UUID()) {
        version = 2; self.generation = generation; self.ownerUID = ownerUID; self.records = records; self.grants = grants
    }
    public func validate() throws {
        guard version == 2, ownerUID > 0, !records.isEmpty, records.count <= 512,
              records.count == grants.count, Set(records.map(\.path)).count == records.count,
              grants.allSatisfy({ !$0.isEmpty && $0.count <= 65536 }) else { throw AppProxyIdentityFailure.malformed }
        for r in records {
            guard r.path.hasPrefix("/"), !r.path.contains("\0"), r.path.utf8.count <= 4096,
                  AppProxyFileStamp.isCanonicalPath(r.path),
                  !r.id.isEmpty, r.id.utf8.count <= 512, r.requirement.utf8.count <= 8192,
                  !r.cdHash.isEmpty, r.cdHash.count <= 64 else { throw AppProxyIdentityFailure.malformed }
        }
    }
    /// Automatic refresh may change vendor code, never the previously approved publisher/identity.
    public func validateRefresh(_ next: [AppProxyCodeIdentity]) throws {
        let priorByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        for candidate in next {
            if let prior = priorByPath[candidate.path] {
                guard candidate.category == prior.category, candidate.id == prior.id,
                      candidate.team == prior.team, candidate.requirement == prior.requirement,
                      prior.team != nil || candidate == prior else { throw AppProxyIdentityFailure.needsAuthorization }
            } else if candidate.category.hasPrefix("app_") {
                // New helpers under a custom app must share an already approved publisher.
                guard let team = candidate.team,
                      records.contains(where: { $0.category == candidate.category && $0.team == team }) else {
                    throw AppProxyIdentityFailure.needsAuthorization
                }
            }
        }
    }
    public func encoded() throws -> Data {
        try validate()
        let d = try JSONEncoder().encode(self)
        guard d.count <= Self.maximumBytes else { throw AppProxyIdentityFailure.capacity }
        return d
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AppProxyIdentityFailure.capacity }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

/// Only the read-only sandbox broker may mint grants; the unsandboxed host must not.
/// Public implicit bookmarks are ephemeral (at most one boot), never durable consent.
public final class AppProxyAccessLease {
    private var urls: [URL] = []
    public let snapshot: AppProxyIdentitySnapshot
    public init(_ snapshot: AppProxyIdentitySnapshot) throws {
        try snapshot.validate(); self.snapshot = snapshot
        do {
            for (record, data) in zip(snapshot.records, snapshot.grants) {
                var stale = false
                let url: URL
                do {
                    url = try URL(resolvingBookmarkData: data,
                                  options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                                  bookmarkDataIsStale: &stale)
                } catch { throw AppProxyIdentityFailure.staleAuthorization }
                guard !stale, url.path == (try AppProxyCodeIdentity.accessURL(for: record.path)).path else {
                    throw AppProxyIdentityFailure.staleAuthorization
                }
                if url.startAccessingSecurityScopedResource() { urls.append(url) }
                // Static sandbox access may require no dynamic scope; actual file validation is authoritative.
                try record.validateFile()
                try record.validateAccessScope()
            }
        } catch {
            release(); throw error
        }
    }
    public func revalidate() throws {
        for record in snapshot.records { try record.validateFile(); try record.validateAccessScope() }
    }
    private func release() { for url in urls.reversed() { url.stopAccessingSecurityScopedResource() }; urls.removeAll() }
    deinit { release() }
}

/// No filesystem API, root service, arbitrary command, or network endpoint is exposed.
@objc(MihomoAppProxyCodeAccessService) public protocol AppProxyCodeAccessService {
    func authorize(_ request: Data, interactive: Bool, reply: @escaping (Data?, String?) -> Void)
}

public struct AppProxyAccessRequest: Codable, Sendable {
    public let ownerUID: UInt32
    public let records: [AppProxyCodeIdentity]
    public init(ownerUID: UInt32, records: [AppProxyCodeIdentity]) { self.ownerUID = ownerUID; self.records = records }
}

public enum AppProxyPeerRequirement {
    public static func sameLeaf(identifier: String) throws -> String {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let v = info as? [String: Any], let certs = v[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { throw AppProxyIdentityFailure.signature }
        // Existing app uses the same exact leaf boundary. Certificate DER -> SHA-1 is a requirement identity, not content hashing.
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined()
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(digest)\""
    }
}
import CryptoKit

public struct AppProxyRuntimeMessage: Codable {
    public enum Action: String, Codable { case status, prepare, commit, abort, renew }
    public let action: Action
    public let expected: UUID?
    public let configuration: Data?
    public init(_ action: Action, expected: UUID? = nil, configuration: Data? = nil) {
        self.action = action; self.expected = expected; self.configuration = configuration
    }
}
public struct AppProxyFlowEvidence: Codable, Equatable, Sendable {
    public let flow: UUID
    public let pid: UInt32
    public let pidVersion: UInt32
    public let generation: UUID?
    public let uptime: TimeInterval
    public let stage: String
    public init(flow: UUID, token: Data?, stage: String, generation: UUID? = nil) {
        self.flow = flow; self.stage = stage; self.generation = generation
        uptime = ProcessInfo.processInfo.systemUptime
        pid = Self.word(token, 5); pidVersion = Self.word(token, 7)
    }
    public static func word(_ token: Data?, _ index: Int) -> UInt32 {
        guard let token, token.count == 32 else { return 0 }
        return token.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
    }
}
public struct AppProxyRuntimeStatus: Codable, Equatable, Sendable {
    public var generation: UUID?
    public var ready: Bool
    public var verifiedTargets: Int
    public var failure: AppProxyIdentityFailure?
    public var counters: [String: Int]
    public var recentFlows: [AppProxyFlowEvidence]
    public init(generation: UUID?, ready: Bool, verifiedTargets: Int, failure: AppProxyIdentityFailure? = nil,
                counters: [String: Int] = [:], recentFlows: [AppProxyFlowEvidence] = []) {
        self.generation = generation; self.ready = ready; self.verifiedTargets = verifiedTargets
        self.failure = failure; self.counters = counters; self.recentFlows = recentFlows
    }
}

/// Compare-and-swap for live refresh; prepared grants are not active policy.
public struct AppProxyGenerationGate {
    public private(set) var current: UUID
    public private(set) var pending: UUID?
    private var preparedAt: TimeInterval = 0
    public init(_ current: UUID) { self.current = current }
    public mutating func prepare(_ next: UUID, expected: UUID, now: TimeInterval) throws {
        guard expected == current, next != current else { throw AppProxyIdentityFailure.generationMismatch }
        pending = next; preparedAt = now
    }
    public mutating func commit(_ next: UUID, now: TimeInterval) throws {
        guard pending == next, now >= preparedAt, now - preparedAt <= 30 else { throw AppProxyIdentityFailure.generationMismatch }
        current = next; pending = nil
    }
    public mutating func expirePrepared(now: TimeInterval) -> Bool {
        if pending != nil && (now < preparedAt || now - preparedAt > 30) { pending = nil; return true }
        return false
    }
    public mutating func abort() { pending = nil }
}

extension AppProxyIdentityFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permission: return "The sandbox could not obtain read-only access to the selected executable."
        case .signature: return "The executable does not satisfy its required signing identity."
        case .changedFile: return "The executable changed during identity validation. Retry discovery."
        case .escapedPath: return "An executable path crosses a symbolic link or is not a regular file."
        case .missingFile: return "A previously selected executable is no longer present."
        case .staleAuthorization, .needsAuthorization: return "Code access needs approval or renewal. Turn App Proxy off and on to authorize it."
        case .wrongUser: return "App Proxy identity authorization belongs to another login session."
        case .generationMismatch: return "The saved rules and active identity generation do not agree."
        case .capacity: return "The application identity snapshot exceeds its safety limits."
        case .malformed: return "The application identity snapshot is invalid."
        case .runtimeIdentity: return "The operating system could not validate the running process identity. Inspect framework validation diagnostics."
        case .undiscoveredTarget: return "The running executable is not in the current application identity snapshot."
        case .unavailable: return "The code authorization service or provider did not respond."
        }
    }
}
