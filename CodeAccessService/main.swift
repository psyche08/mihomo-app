import AppKit
import Foundation
import Security

/// Per-user, sandboxed XPC service. It reads the home directory and the conventional CLI
/// prefixes read-only, so scanned code is approved in the host UI without a file picker;
/// Powerbox remains only for code it still cannot read (for example external volumes).
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
        // Each request now belongs to one application. Never revoke another
        // application's durable consent merely because it is absent here.
        guard saved.count <= 512 else { throw AppProxyIdentityFailure.capacity }
        let identitiesKey = "readOnlyCodeIdentities.v1"
        var pinned = UserDefaults.standard.dictionary(forKey: identitiesKey) as? [String: Data] ?? [:]
        guard pinned.count <= 512 else { throw AppProxyIdentityFailure.capacity }
        var activeURLs: [URL] = []
        defer { for u in activeURLs.reversed() { u.stopAccessingSecurityScopedResource() } }
        // Team/directory scopes are approved once in the host's confirmation sheet; maintenance reuses them.
        let scopesKey = "readOnlyCodeScopes.v1"
        var approvedScopes = Set(UserDefaults.standard.stringArray(forKey: scopesKey) ?? [])
        let categories = Set(request.records.map(\.category))
        guard request.scopes.count <= 64, Set(request.scopes).count == request.scopes.count,
              request.scopes.allSatisfy({ $0.isValid && categories.contains($0.category) }) else { throw AppProxyIdentityFailure.malformed }
        func scopeKey(_ scope: AppProxyScope) -> String { [scope.category, scope.kind.rawValue, scope.value].joined(separator: "\u{0}") }
        for scope in request.scopes where !approvedScopes.contains(scopeKey(scope)) {
            guard interactive else { throw AppProxyIdentityFailure.needsAuthorization }
            approvedScopes.insert(scopeKey(scope))
        }
        guard approvedScopes.count <= 512 else { throw AppProxyIdentityFailure.capacity }
        var result: [Data] = []
        for record in request.records {
            let root = try Self.grantRoot(record.path)
            let scoped = AppProxyScope.match(path: record.path, team: record.team,
                                             in: request.scopes.filter { $0.category == record.category }) != nil
            if !interactive && !scoped {
                let approved = pinned.values.compactMap { try? JSONDecoder().decode(AppProxyCodeIdentity.self, from: $0) }
                if let prior = approved.first(where: { $0.path == record.path }) {
                    try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [prior], grants: []).validateRefresh([record])
                } else {
                    guard let team = record.team, approved.contains(where: {
                        $0.category == record.category && $0.team == team && $0.id == record.id && $0.requirement == record.requirement
                    }) else { throw AppProxyIdentityFailure.needsAuthorization }
                }
            }
            guard pinned[record.path] != nil || pinned.count < 512 else { throw AppProxyIdentityFailure.capacity }
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
                    let application = NSApplication.shared
                    application.setActivationPolicy(.accessory)
                    let panel = NSOpenPanel()
                    panel.title = "Allow MihomoBox to verify application code"
                    panel.message = "Grant read-only access to this code location: \(root.path). This does not authorize access to chats or other application data."
                    panel.canChooseFiles = true; panel.canChooseDirectories = root.pathExtension == "app"
                    panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
                    panel.showsHiddenFiles = true
                    panel.directoryURL = root.deletingLastPathComponent()
                    panel.nameFieldStringValue = root.lastPathComponent
                    guard saved[root.path] != nil || saved.count < 512 else { throw AppProxyIdentityFailure.capacity }
                    // The XPC service uses NSRunLoop, not NSApplication.run().
                    // A modeless panel has no AppKit event pump here. Give the
                    // consent UI an AppKit modal loop and foreground activation.
                    application.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK, let u = panel.url,
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
            // Keep successful exact-code consent even if a later package is cancelled.
            pinned[record.path] = try JSONEncoder().encode(record)
            UserDefaults.standard.set(pinned, forKey: identitiesKey)
            UserDefaults.standard.set(saved, forKey: storeKey)
            result.append(try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        UserDefaults.standard.set(saved, forKey: storeKey)
        // One read-only grant per directory scope. The broker's own access is read-only, so the grant is too.
        var scopeGrants: [Data] = []
        for scope in request.scopes where scope.kind == .directory {
            try AppProxyAccessLease.requireReadableDirectory(scope.value)
            scopeGrants.append(try URL(fileURLWithPath: scope.value, isDirectory: true)
                .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        UserDefaults.standard.set(Array(approvedScopes).sorted(), forKey: scopesKey)
        return try AppProxyIdentitySnapshot(ownerUID: request.ownerUID, records: request.records, grants: result,
                                            scopes: request.scopes, scopeGrants: scopeGrants).encoded()
    }
    static func grantRoot(_ path: String) throws -> URL {
        try AppProxyCodeIdentity.accessURL(for: path)
    }
}
let broker = CodeAccessBroker()
let listener = NSXPCListener.service()
listener.delegate = broker
listener.resume()
