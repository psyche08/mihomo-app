import Foundation
import MihomoControl

final class AppProxyCodeAccessClient {
    func snapshot(records: [AppProxyCodeIdentity], scopes: [AppProxyScope] = [], interactive: Bool) async throws -> AppProxyIdentitySnapshot {
        let request = AppProxyAccessRequest(ownerUID: getuid(), records: records, scopes: scopes)
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
                    guard let data else { throw AppProxyIdentityFailure(rawValue: error ?? "") ?? .permission }
                    let snapshot = try AppProxyIdentitySnapshot.decode(data)
                    guard snapshot.ownerUID == request.ownerUID, snapshot.records == request.records,
                          snapshot.scopes == request.scopes else { throw AppProxyIdentityFailure.malformed }
                    completion.finish(.success(snapshot))
                } catch { completion.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (interactive ? 300 : 20)) {
                completion.finish(.failure(AppProxyIdentityFailure.unavailable))
            }
        }
    }
}
// NSXPCConnection supports invalidation from the completion threads; the continuation is locked.
private final class CodeAccessCompletion: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<AppProxyIdentitySnapshot, Error>?
    let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<AppProxyIdentitySnapshot, Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func finish(_ result: Result<AppProxyIdentitySnapshot, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        guard let c else { return }; connection.invalidate(); c.resume(with: result)
    }
}
