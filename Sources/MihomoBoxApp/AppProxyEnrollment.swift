import Foundation
import MihomoControl

/// One policy generation for the requested applications. Failures are isolated per
/// application before any OS rules exist; the others still form a complete generation.
struct AppProxyEnrollment {
    let targets: AIAppTargets
    let policy: AppProxyPolicy?
    /// Applications left out, and applications routed with some folders still awaiting approval.
    let failures: [String: String]

    @MainActor static func prepare(applications: [AppProxyEntry], requested: Set<String>,
        interactiveID: String?, home: String,
        build: ([AppProxyApplicationPolicy]) async -> AIAppTargets,
        authorize: (_ category: String, _ folders: [String], _ interactive: Bool) async throws -> AppProxyFolderGrants
    ) async throws -> Self {
        var policies: [AppProxyApplicationPolicy] = [], folders: [String] = [], grants: [Data] = []
        var failures: [String: String] = [:]
        for app in applications where requested.contains(app.id) {
            do {
                let policy = try AppProxyApplicationPolicy.resolve(app, home: home)
                var granted: [(String, Data)] = []
                if !policy.folders.isEmpty {
                    let reply = try await authorize(app.id, policy.folders, interactiveID == app.id)
                    granted = Array(zip(reply.folders, reply.grants))
                    if policy.existingFolders.contains(where: { !reply.folders.contains($0) }) {
                        failures[app.id] = AppProxyIdentityFailure.needsAuthorization.rawValue
                    }
                }
                policies.append(policy)
                for (folder, grant) in granted where !folders.contains(folder) { folders.append(folder); grants.append(grant) }
            } catch {
                failures[app.id] = (error as? AppProxyIdentityFailure)?.rawValue
                    ?? ((error as? AIAppTargets.Failure) == nil ? "unavailable" : "discoveryFailed")
            }
        }
        let targets = await build(policies)
        guard !policies.isEmpty else { return Self(targets: targets, policy: nil, failures: failures) }
        let policy = AppProxyPolicy(ownerUID: getuid(), routes: targets.routes, folders: folders, grants: grants,
                                    codeStamp: targets.codeStamp)
        try policy.validate()
        return Self(targets: targets, policy: policy, failures: failures)
    }
}


/// A user may leave a consent panel open longer than the provider's lease.
/// Keep only the existing generation alive while preparing candidates. Stop and
/// join renewal before publishing any new rules.
@MainActor enum AppProxyAuthorizationLease {
    static func run<T>(interval: UInt64 = 20_000_000_000,
                       renew: @escaping @MainActor () async throws -> Void,
                       operation: @MainActor () async throws -> T) async throws -> T {
        let keeper = Task<Error?, Never> { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return nil }
                guard !Task.isCancelled else { return nil }
                do { try await renew() } catch { return error }
            }
            return nil
        }
        let result: Result<T, Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        keeper.cancel()
        if let error = await keeper.value { throw error }
        return try result.get()
    }
}

/// Periodic maintenance and a long prepare operation can request the same
/// renewal concurrently. Share one provider request per generation.
@MainActor final class AppProxyLeaseRenewer {
    private var pending: (generation: UUID, ticket: UUID, task: Task<Void, Error>)?
    func run(generation: UUID, operation: @escaping @MainActor () async throws -> Void) async throws {
        if let pending, pending.generation == generation { return try await pending.task.value }
        let ticket = UUID(), task = Task { try await operation() }
        pending = (generation, ticket, task)
        defer { if pending?.ticket == ticket { pending = nil } }
        try await task.value
    }
}
