import Foundation
import Darwin
import Security
import CryptoKit

/// Shared host / sandbox broker / provider wire contract. Never contains traffic or credentials.
public enum AppProxyIdentityFailure: String, Error, Codable, Sendable {
    case malformed, permission, signature, changedFile, escapedPath, missingFile, staleAuthorization
    case wrongUser, generationMismatch, capacity, needsAuthorization, unavailable, runtimeIdentity, undiscoveredTarget
    case codeAccessTimeout, providerTimeout
}

/// Syntax of Team IDs, signing identifiers and code folders, shared by the settings, the host,
/// the code-access broker and the provider, and the code requirements built from them.
public enum AppProxyCode {
    public static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }
    /// Identifiers are embedded in requirement strings: printable ASCII without spaces, quotes or backslashes.
    public static func isSigningIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f && $0 != 0x22 && $0 != 0x5c }
    }
    public static func isCanonicalPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")
            && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public static func isFolder(_ value: String) -> Bool {
        value != "/" && isCanonicalPath(value)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    /// Code signed by one of `teams` through Apple's Developer ID or Mac App Store chain.
    public static func teamRequirement(_ teams: [String]) -> String {
        "anchor apple generic and " + teamClause(teams)
    }
    /// One vendor signing identifier signed by one of `teams`: a version-independent tool entry.
    public static func requirement(identifier: String, teams: [String]) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and " + teamClause(teams)
    }
    private static func teamClause(_ teams: [String]) -> String {
        let clauses = teams.map { "certificate leaf[subject.OU] = \"\($0)\"" }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " or ") + ")"
    }
    /// Opens `path` as a directory without following a link in any component.
    public static func requireReadableFolder(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ENOENT ? AppProxyIdentityFailure.missingFile
                : (errno == ELOOP || errno == ENOTDIR ? AppProxyIdentityFailure.escapedPath : AppProxyIdentityFailure.permission)
        }
        close(fd)
    }
    /// A grant must never give effective write access to code: open the folder, then require
    /// that this process cannot write to it.
    public static func requireReadOnlyFolder(_ path: String) throws {
        try requireReadableFolder(path)
        guard access(path, W_OK) != 0 else { throw AppProxyIdentityFailure.permission }
    }
}

/// The provider's whole authority for one generation: which publishers route to which
/// application listener, and read-only grants for the code folders its sandbox cannot read
/// otherwise. NetworkExtension must read a diverted process's code to validate it, so code
/// in the home directory or under Homebrew needs a grant; `/Applications` does not.
/// There is no executable list, hash or file stamp: the provider checks each flow's running
/// code against its route's Team requirement, so vendor updates need no new authority.
public struct AppProxyPolicy: Codable, Equatable, Sendable {
    public struct Route: Codable, Equatable, Sendable {
        public let category: String
        public let teams: [String]
        /// Signing identifiers this route accepts; the OS rules divert exactly these.
        public let identifiers: [String]
        public init(category: String, teams: [String], identifiers: [String]) {
            self.category = category; self.teams = teams; self.identifiers = identifiers
        }
        public var requirement: String { AppProxyCode.teamRequirement(teams) }
    }
    public static let currentVersion = 5
    public static let maximumBytes = 512 * 1024
    public let version: Int
    public let generation: UUID
    public let ownerUID: UInt32
    public let routes: [Route]
    /// Granted code folders, paired by index with `grants`.
    public let folders: [String]
    public let grants: [Data]
    /// Digest of the top-level executables and granted folders behind the OS rules. An update
    /// replaces them, which changes the digest and saves the rules again for the new binaries.
    public let codeStamp: String
    public init(ownerUID: UInt32, routes: [Route], folders: [String], grants: [Data], codeStamp: String,
                generation: UUID = UUID()) {
        version = Self.currentVersion; self.generation = generation; self.ownerUID = ownerUID
        self.routes = routes; self.folders = folders; self.grants = grants; self.codeStamp = codeStamp
    }
    public func validate() throws {
        // A running process must select exactly one route: no Team ID and identifier pair repeats.
        let pairs = routes.flatMap { route in route.teams.flatMap { team in route.identifiers.map { team + "\u{0}" + $0 } } }
        guard version == Self.currentVersion, ownerUID > 0, !routes.isEmpty, routes.count <= 32,
              Set(routes.map(\.category)).count == routes.count,
              routes.allSatisfy({ route in
                  !route.category.isEmpty && route.category.utf8.count <= 64
                    && (1...8).contains(route.teams.count) && route.teams.allSatisfy(AppProxyCode.isTeamIdentifier)
                    && (1...64).contains(route.identifiers.count) && Set(route.identifiers).count == route.identifiers.count
                    && route.identifiers.allSatisfy(AppProxyCode.isSigningIdentifier)
              }),
              Set(pairs).count == pairs.count,
              folders.count <= 64, Set(folders).count == folders.count, folders.allSatisfy(AppProxyCode.isFolder),
              grants.count == folders.count, grants.allSatisfy({ !$0.isEmpty && $0.count <= 65536 }),
              codeStamp.utf8.count == 64, codeStamp.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw AppProxyIdentityFailure.malformed }
    }
    /// The same routes, folders and code, ignoring the generation and the bytes of freshly minted grants.
    public func sameAuthority(as other: Self) -> Bool {
        ownerUID == other.ownerUID && routes == other.routes && folders == other.folders && codeStamp == other.codeStamp
    }
    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw AppProxyIdentityFailure.capacity }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AppProxyIdentityFailure.capacity }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

/// The provider's read access to the granted folders, held while its generation is active or prepared.
/// Only the read-only broker mints grants; public implicit bookmarks expire no later than reboot,
/// so a provider restarted from saved preferences fails here and the host mints fresh grants.
public final class AppProxyFolderAccess {
    private var urls: [URL] = []
    public let policy: AppProxyPolicy
    public init(_ policy: AppProxyPolicy) throws {
        try policy.validate(); self.policy = policy
        do {
            for (folder, data) in zip(policy.folders, policy.grants) {
                var stale = false
                let url: URL
                do {
                    url = try URL(resolvingBookmarkData: data,
                                  options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                                  bookmarkDataIsStale: &stale)
                } catch { throw AppProxyIdentityFailure.staleAuthorization }
                guard !stale, url.path == folder else { throw AppProxyIdentityFailure.staleAuthorization }
                if url.startAccessingSecurityScopedResource() { urls.append(url) }
                // Static sandbox access may need no dynamic scope; opening the folder is authoritative.
                try AppProxyCode.requireReadOnlyFolder(folder)
            }
        } catch {
            release(); throw error
        }
    }
    private func release() { for url in urls.reversed() { url.stopAccessingSecurityScopedResource() }; urls.removeAll() }
    deinit { release() }
}

/// No filesystem API, root service, arbitrary command, or network endpoint is exposed.
@objc(MihomoAppProxyCodeAccessService) public protocol AppProxyCodeAccessService {
    func authorize(_ request: Data, interactive: Bool, reply: @escaping (Data?, String?) -> Void)
}

/// One application's code folders. An interactive request approves all of them, existing or not,
/// so a vendor installing one later needs no new consent; grants cover the existing ones.
public struct AppProxyFolderRequest: Codable, Equatable, Sendable {
    public let ownerUID: UInt32
    public let category: String
    public let folders: [String]
    public init(ownerUID: UInt32, category: String, folders: [String]) {
        self.ownerUID = ownerUID; self.category = category; self.folders = folders
    }
    public func validate() throws {
        guard ownerUID > 0, !category.isEmpty, category.utf8.count <= 64, (1...16).contains(folders.count),
              Set(folders).count == folders.count, folders.allSatisfy(AppProxyCode.isFolder) else {
            throw AppProxyIdentityFailure.malformed
        }
    }
}

public struct AppProxyFolderGrants: Codable, Equatable, Sendable {
    public let ownerUID: UInt32
    public let category: String
    /// The requested folders that exist, in request order, each with one read-only grant.
    public let folders: [String]
    public let grants: [Data]
    public init(ownerUID: UInt32, category: String, folders: [String], grants: [Data]) {
        self.ownerUID = ownerUID; self.category = category; self.folders = folders; self.grants = grants
    }
    public func validate(for request: AppProxyFolderRequest) throws {
        guard ownerUID == request.ownerUID, category == request.category, grants.count == folders.count,
              folders.allSatisfy(request.folders.contains), Set(folders).count == folders.count,
              grants.allSatisfy({ !$0.isEmpty && $0.count <= 65536 }) else { throw AppProxyIdentityFailure.malformed }
    }
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

public struct AppProxyRuntimeMessage: Codable {
    public enum Action: String, Codable { case status, prepare, commit, abort, renew, flowOwners }
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
    /// Applications (routes) in the active policy; executables before policy version 5.
    public var verifiedTargets: Int
    public var failure: AppProxyIdentityFailure?
    public var counters: [String: Int]
    public var recentFlows: [AppProxyFlowEvidence]
    /// Present only in the reply to a `flowOwners` request.
    public var flowOwners: AppProxyFlowOwners?
    /// The running provider's bundle version; absent from providers up to 1.0.8.
    public var providerVersion: String?
    public init(generation: UUID?, ready: Bool, verifiedTargets: Int, failure: AppProxyIdentityFailure? = nil,
                counters: [String: Int] = [:], recentFlows: [AppProxyFlowEvidence] = [], flowOwners: AppProxyFlowOwners? = nil,
                providerVersion: String? = nil) {
        self.generation = generation; self.ready = ready; self.verifiedTargets = verifiedTargets
        self.failure = failure; self.counters = counters; self.recentFlows = recentFlows; self.flowOwners = flowOwners
        self.providerVersion = providerVersion
    }
}

/// The verified process behind each provider connection to a Mihomo listener, keyed by that
/// connection's local port. Mihomo sees only the provider as the socket owner; the dashboard
/// uses this table to attribute App Proxy traffic to the real application. Paths are shared
/// by index so the reply stays within the provider message limit.
public struct AppProxyFlowOwners: Codable, Equatable, Sendable {
    public struct Flow: Codable, Equatable, Sendable {
        public let port: UInt16
        public let udp: Bool
        public let executable: Int
        public let pid: UInt32
        public init(port: UInt16, udp: Bool, executable: Int, pid: UInt32) {
            self.port = port; self.udp = udp; self.executable = executable; self.pid = pid
        }
    }
    public static let maximumFlows = 512
    public static let maximumExecutables = 128
    public private(set) var executables: [String]
    public private(set) var flows: [Flow]

    /// Keeps at most `maximumFlows` flows and `maximumExecutables` distinct paths, in the given order.
    public init(_ owners: [(port: UInt16, udp: Bool, path: String, pid: UInt32)]) {
        var executables: [String] = [], index: [String: Int] = [:], flows: [Flow] = []
        for owner in owners where flows.count < Self.maximumFlows {
            let position: Int
            if let known = index[owner.path] { position = known }
            else {
                guard executables.count < Self.maximumExecutables else { continue }
                position = executables.count; index[owner.path] = position; executables.append(owner.path)
            }
            flows.append(.init(port: owner.port, udp: owner.udp, executable: position, pid: owner.pid))
        }
        self.executables = executables; self.flows = flows
    }
    public func owner(port: UInt16, udp: Bool) -> (path: String, pid: UInt32)? {
        guard let flow = flows.first(where: { $0.port == port && $0.udp == udp }),
              executables.indices.contains(flow.executable) else { return nil }
        return (executables[flow.executable], flow.pid)
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
    /// Validation may complete after a stop, expiry, or a policy commit. A late
    /// success must never resurrect expired authority or renew another generation.
    public func validateRenewal(expected: UUID, active: Bool, lastRenewal: TimeInterval, now: TimeInterval) throws {
        guard expected == current else { throw AppProxyIdentityFailure.generationMismatch }
        guard active, now >= lastRenewal, now - lastRenewal <= 90 else { throw AppProxyIdentityFailure.staleAuthorization }
    }
}

extension AppProxyIdentityFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permission: return "The sandbox could not obtain read-only access to an application code folder."
        case .signature: return "The running code does not satisfy its application's Team ID requirement."
        case .changedFile: return "Application code changed while it was being checked. Retry shortly."
        case .escapedPath: return "A code folder crosses a symbolic link or is not a directory."
        case .missingFile: return "A code folder is no longer present."
        case .staleAuthorization, .needsAuthorization: return "Code folder access needs approval or renewal. Turn the application off and on to approve it."
        case .wrongUser: return "App Proxy authorization belongs to another login session."
        case .generationMismatch: return "The saved rules and active policy generation do not agree."
        case .capacity: return "The App Proxy policy exceeds its safety limits."
        case .malformed: return "The App Proxy policy is invalid."
        case .runtimeIdentity: return "The operating system could not validate the running process identity. Inspect framework validation diagnostics."
        case .undiscoveredTarget: return "The running code is not signed by a selected application's Team ID with a listed signing identifier."
        case .unavailable: return "The code access service or provider did not respond."
        case .codeAccessTimeout: return "Code folder access took too long. Retry shortly."
        case .providerTimeout: return "The App Proxy extension did not finish the request before its deadline."
        }
    }
}
