import Foundation
import MihomoControl

final class AppProxyCodeAccessClient {
    /// Read-only grants for one application's existing code folders; see `CodeAccessBroker`.
    func grants(category: String, folders: [String], interactive: Bool) async throws -> AppProxyFolderGrants {
        let request = AppProxyFolderRequest(ownerUID: getuid(), category: category, folders: folders)
        try request.validate()
        let data = try JSONEncoder().encode(request)
        let requirement = try AppProxyPeerRequirement.sameLeaf(identifier: "dev.linsheng.mihomo-app.code-access")
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(serviceName: "dev.linsheng.mihomo-app.code-access")
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: AppProxyCodeAccessService.self)
            let completion = CodeAccessCompletion(connection: connection, continuation: continuation)
            connection.interruptionHandler = { completion.finish(.failure(AppProxyIdentityFailure.unavailable)) }
            connection.invalidationHandler = { completion.finish(.failure(AppProxyIdentityFailure.unavailable)) }
            connection.resume()
            guard let service = connection.remoteObjectProxyWithErrorHandler({ _ in completion.finish(.failure(AppProxyIdentityFailure.unavailable)) }) as? AppProxyCodeAccessService else {
                completion.finish(.failure(AppProxyIdentityFailure.unavailable)); return
            }
            service.authorize(data, interactive: interactive) { data, error in
                do {
                    guard let data, data.count <= 1_048_576 else { throw AppProxyIdentityFailure(rawValue: error ?? "") ?? .permission }
                    let grants = try JSONDecoder().decode(AppProxyFolderGrants.self, from: data)
                    try grants.validate(for: request)
                    completion.finish(.success(grants))
                } catch { completion.finish(.failure(error)) }
            }
            // The broker opens a few folders and mints bookmarks: seconds at most.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                completion.finish(.failure(AppProxyIdentityFailure.codeAccessTimeout))
            }
        }
    }
}
// NSXPCConnection supports invalidation from the completion threads; the continuation is locked.
private final class CodeAccessCompletion: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<AppProxyFolderGrants, Error>?
    let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<AppProxyFolderGrants, Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func finish(_ result: Result<AppProxyFolderGrants, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        guard let c else { return }; connection.invalidate(); c.resume(with: result)
    }
}
