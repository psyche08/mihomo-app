import AppKit
import Foundation
import Security

/// Per-user, sandboxed XPC service. Only this process receives read-only Powerbox grants.
/// No network entitlements and no root privileges. The host cannot mint a writable implicit grant.
final class CodeAccessBroker: NSObject, NSXPCListenerDelegate, AppProxyCodeAccessService {
    private var busy = false
    private let storeKey = "readOnlyCodePackages.v2"
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
            Task { @MainActor in
                defer { self.busy = false }
                do { reply(try await self.grants(request, interactive: interactive), nil) }
                catch { reply(nil, (error as? AppProxyIdentityFailure ?? .permission).rawValue) }
            }
        }
    }
    @MainActor private func grants(_ data: Data, interactive: Bool) async throws -> Data {
        guard data.count <= AppProxyIdentitySnapshot.maximumBytes else { throw AppProxyIdentityFailure.capacity }
        let request = try JSONDecoder().decode(AppProxyAccessRequest.self, from: data)
        guard request.ownerUID == getuid(), request.ownerUID > 0,
              !request.records.isEmpty, request.records.count <= 512 else { throw AppProxyIdentityFailure.wrongUser }
        var saved = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data] ?? [:]
        let desiredRoots = try Set(request.records.map { try Self.grantRoot($0.path).path })
        saved = saved.filter { desiredRoots.contains($0.key) }
        UserDefaults.standard.set(saved, forKey: storeKey)
        var activeURLs: [URL] = []
        defer { for u in activeURLs.reversed() { u.stopAccessingSecurityScopedResource() } }
        var result: [Data] = []
        for record in request.records {
            let root = try Self.grantRoot(record.path)
            if !FileManager.default.isReadableFile(atPath: root.path) {
                var usable = false
                if let bookmark = saved[root.path] {
                    var stale = false
                    if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
                       !stale, u.path == root.path, u.startAccessingSecurityScopedResource() {
                        activeURLs.append(u); usable = true
                    } else { saved.removeValue(forKey: root.path) }
                }
                if !usable {
                    guard interactive else { throw AppProxyIdentityFailure.needsAuthorization }
                    _ = NSApplication.shared
                    let panel = NSOpenPanel()
                    panel.title = "Allow MihomoBox to verify application code"
                    panel.message = "Grant read-only access to this code location: \(root.path). This does not authorize access to chats or other application data."
                    panel.canChooseFiles = true; panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = true
                    panel.directoryURL = root.deletingLastPathComponent()
                    guard await panel.begin() == .OK, let u = panel.url,
                          u.standardizedFileURL.path == root.path,
                          u.resolvingSymlinksInPath().path == root.path else { throw AppProxyIdentityFailure.needsAuthorization }
                    // Preserve the Powerbox URL, including its scope, rather than reconstructing it.
                    let bookmark = try u.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    var stale = false
                    let held = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    guard !stale, held.startAccessingSecurityScopedResource() else { throw AppProxyIdentityFailure.permission }
                    activeURLs.append(held); saved[root.path] = bookmark
                }
            }
            try record.validateFile()
            // Refuse to export a grant from an unexpectedly writable source sandbox.
            try record.validateAccessScope()
            result.append(try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        UserDefaults.standard.set(saved, forKey: storeKey)
        return try AppProxyIdentitySnapshot(ownerUID: request.ownerUID, records: request.records, grants: result).encoded()
    }
    static func grantRoot(_ path: String) throws -> URL {
        try AppProxyCodeIdentity.accessURL(for: path)
    }
}
let broker = CodeAccessBroker()
let listener = NSXPCListener.service()
listener.delegate = broker
listener.resume()
