import Foundation
import MihomoControl

/// Authorization failures are isolated before any OS interception rules exist.
/// An application is atomic: all of its discovered code and responsible hosts
/// must pass. Other applications can still form a complete verified generation.
struct AppProxyEnrollment {
    let targets: AIAppTargets
    let snapshot: AppProxyIdentitySnapshot?
    let failures: [String: String]

    @MainActor static func prepare(applications: [AppProxyEntry], requested: Set<String>,
        interactiveID: String?, previous: AppProxyIdentitySnapshot?,
        discover: (AppProxyEntry) async throws -> AIAppTargets,
        authorize: ([AppProxyCodeIdentity], Bool) async throws -> AppProxyIdentitySnapshot
    ) async throws -> Self {
        var groups: [AIAppTargets] = []
        var grants: [String: (AppProxyCodeIdentity, Data)] = [:]
        var failures: [String: String] = [:]
        for app in applications where requested.contains(app.id) {
            do {
                let targets = try await discover(app)
                let records = targets.targets.map(\.identity)
                guard records.contains(where: { $0.category == app.id }) else { throw AppProxyIdentityFailure.missingFile }
                if interactiveID != app.id {
                    // After loss of a prior generation, only durable broker consent
                    // can restore files; never silently approve a changed publisher.
                    if let previous { try previous.validateRefresh(records) }
                }
                let snapshot = try await authorize(records, interactiveID == app.id)
                try snapshot.validate()
                guard snapshot.ownerUID == getuid(), snapshot.records == records else { throw AppProxyIdentityFailure.malformed }
                for record in records {
                    if let old = grants[record.path], old.0 != record { throw AIAppTargets.Failure.duplicateTarget }
                }
                for (record, grant) in zip(records, snapshot.grants) { grants[record.path] = (record, grant) }
                groups.append(targets)
            } catch {
                failures[app.id] = (error as? AppProxyIdentityFailure)?.rawValue
                    ?? ((error as? AIAppTargets.Failure) == nil ? "unavailable" : "discoveryFailed")
            }
        }
        let targets = try AIAppTargets(combining: groups)
        let records = targets.targets.map(\.identity)
        let snapshot = records.isEmpty ? nil : AppProxyIdentitySnapshot(ownerUID: getuid(), records: records,
            grants: try records.map { record in
                guard let grant = grants[record.path], grant.0 == record else { throw AppProxyIdentityFailure.malformed }
                return grant.1
            })
        try snapshot?.validate()
        return Self(targets: targets, snapshot: snapshot, failures: failures)
    }
}


/// A user may leave a consent panel open longer than the provider's lease.
/// Keep only the existing, independently revalidated generation alive while
/// preparing candidates. Stop and join renewal before publishing any new rules.
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
