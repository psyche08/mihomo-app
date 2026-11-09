import Darwin
import Foundation
import Security

/// Per-user, sandboxed XPC service. It reads the home directory and the conventional CLI
/// prefixes read-only and mints read-only grants for an application's code folders, so the
/// sandboxed provider can read the code NetworkExtension validates. It never reads or checks
/// code itself. No network entitlements and no root privileges. The host cannot mint a
/// writable implicit grant; this broker's own access is read-only, so its grants are too.
final class CodeAccessBroker: NSObject, NSXPCListenerDelegate, AppProxyCodeAccessService {
    private var busy = false
    /// Folders the operator approved, as "category\0directory\0path" (the key the previous scopes used).
    private let approvalsKey = "readOnlyCodeScopes.v1"
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), getuid() != 0,
              let requirement = try? AppProxyPeerRequirement.sameLeaf(identifier: "dev.linsheng.mihomo-app") else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AppProxyCodeAccessService.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func authorize(_ request: Data, interactive: Bool, reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async {
            guard !self.busy else { reply(nil, AppProxyIdentityFailure.unavailable.rawValue); return }
            self.busy = true
            defer { self.busy = false }
            do { reply(try self.grants(request, interactive: interactive), nil) }
            catch { reply(nil, (error as? AppProxyIdentityFailure ?? .permission).rawValue) }
        }
    }
    /// An interactive request is the operator's consent (the host's confirmation, or
    /// `mihomoboxctl app-proxy enable --approve`): it approves every requested folder, present or
    /// not. Otherwise only approved folders are granted, and none approved is an error.
    private func grants(_ data: Data, interactive: Bool) throws -> Data {
        guard data.count <= 65536 else { throw AppProxyIdentityFailure.capacity }
        let request = try JSONDecoder().decode(AppProxyFolderRequest.self, from: data)
        try request.validate()
        guard request.ownerUID == getuid() else { throw AppProxyIdentityFailure.wrongUser }
        guard request.folders.allSatisfy(Self.isGrantable) else { throw AppProxyIdentityFailure.permission }
        var approved = Set(UserDefaults.standard.stringArray(forKey: approvalsKey) ?? [])
        func key(_ folder: String) -> String { [request.category, "directory", folder].joined(separator: "\u{0}") }
        if interactive {
            approved.formUnion(request.folders.map(key))
            guard approved.count <= 1024 else { throw AppProxyIdentityFailure.capacity }
            UserDefaults.standard.set(Array(approved).sorted(), forKey: approvalsKey)
        } else if !request.folders.contains(where: { approved.contains(key($0)) }) {
            throw AppProxyIdentityFailure.needsAuthorization
        }
        var folders: [String] = [], grants: [Data] = []
        for folder in request.folders where approved.contains(key(folder)) {
            do { try AppProxyCode.requireReadOnlyFolder(folder) }
            catch AppProxyIdentityFailure.missingFile { continue }
            folders.append(folder)
            grants.append(try URL(fileURLWithPath: folder, isDirectory: true)
                .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        let result = AppProxyFolderGrants(ownerUID: request.ownerUID, category: request.category, folders: folders, grants: grants)
        try result.validate(for: request)
        return try JSONEncoder().encode(result)
    }
    /// A code folder, never a whole home, library or system prefix.
    static func isGrantable(_ folder: String) -> Bool {
        // The real home directory, not this sandboxed service's container.
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return false }
        let home = String(cString: directory)
        let broad = ["/Users", "/opt", "/opt/homebrew", "/usr", "/usr/local", home, home + "/Library",
                     home + "/Library/Application Support", home + "/Documents", home + "/Desktop", home + "/Downloads"]
        return folder.split(separator: "/").count >= 2 && !broad.contains(folder)
    }
}
let broker = CodeAccessBroker()
let listener = NSXPCListener.service()
listener.delegate = broker
listener.resume()
