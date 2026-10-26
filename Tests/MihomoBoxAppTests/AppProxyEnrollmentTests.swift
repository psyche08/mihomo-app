import XCTest
import MihomoControl
@testable import MihomoBoxApp

final class AppProxyEnrollmentTests: XCTestCase {
    private let a = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "A", path: "/bin/ls", port: 17975)
    private let b = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000002", title: "B", path: "/usr/bin/curl", port: 17976)
    private func discover(_ app: AppProxyEntry) throws -> AIAppTargets {
        try AIAppTargets(requireAll: false, applications: [app])
    }
    private func snapshot(_ records: [AppProxyCodeIdentity]) -> AppProxyIdentitySnapshot {
        // Opaque fixture bytes exercise assembly only; not actual OS grants.
        .init(ownerUID: getuid(), records: records, grants: records.map { _ in Data([1]) })
    }
    @MainActor func testDeniedApplicationDoesNotPreventOtherApplicationAndNeverLeaksItsRules() async throws {
        var interactive: [String] = []
        let plan = try await AppProxyEnrollment.prepare(applications: [a,b], requested: [a.id,b.id], interactiveID: b.id, previous: nil,
            discover: { try self.discover($0) }, authorize: { records, consent in
                let id = records.first { $0.category != "cli_host" }!.category
                if consent { interactive.append(id) }
                if id == self.b.id { throw AppProxyIdentityFailure.needsAuthorization }
                return self.snapshot(records)
            })
        XCTAssertEqual(interactive, [b.id])
        XCTAssertEqual(plan.failures, [b.id: "needsAuthorization"])
        XCTAssertEqual(Set(plan.snapshot!.records.filter { $0.category != "cli_host" }.map(\.category)), [a.id])
        XCTAssertFalse(plan.targets.rules.contains { $0.matchPath == b.path })
        XCTAssertTrue(plan.targets.rules.allSatisfy { rule in
            guard let tools = rule.matchTools, !tools.isEmpty else { return false }
            return tools.allSatisfy { $0.matchPath != self.b.path }
        })
    }
    @MainActor func testDisabledEntriesAreNeitherDiscoveredNorPromptedAndAllDeniedHasNoRules() async throws {
        var visited: [String] = []
        let plan = try await AppProxyEnrollment.prepare(applications: [a,b], requested: [a.id], interactiveID: a.id, previous: nil,
            discover: { app in visited.append(app.id); return try self.discover(app) },
            authorize: { _,_ in throw AppProxyIdentityFailure.permission })
        XCTAssertEqual(visited, [a.id]); XCTAssertNil(plan.snapshot)
        XCTAssertTrue(plan.targets.rules.isEmpty)
        XCTAssertEqual(plan.failures, [a.id: "permission"])
    }
    @MainActor func testSharedResponsibleHostIsDeduplicatedWithoutUnrestrictedChildren() async throws {
        let plan = try await AppProxyEnrollment.prepare(applications: [a,b], requested: [a.id,b.id], interactiveID: nil, previous: nil,
            discover: { try self.discover($0) }, authorize: { records, interactive in
                XCTAssertFalse(interactive); return self.snapshot(records)
            })
        let snapshot = try XCTUnwrap(plan.snapshot)
        XCTAssertEqual(Set(snapshot.records.map(\.path)).count, snapshot.records.count)
        XCTAssertEqual(snapshot.records.count, snapshot.grants.count)
        let terminal = try XCTUnwrap(plan.targets.rules.first { $0.matchSigningIdentifier == "com.apple.Terminal" })
        XCTAssertEqual(Set(terminal.matchTools!.compactMap(\.matchPath)), [a.path!,b.path!])
        let withoutB = try await AppProxyEnrollment.prepare(applications: [a,b], requested: [a.id], interactiveID: nil, previous: snapshot,
            discover: { try self.discover($0) }, authorize: { records,_ in self.snapshot(records) })
        XCTAssertFalse(withoutB.targets.rules.flatMap { $0.matchTools ?? [] }.contains { $0.matchPath == b.path })
    }
    @MainActor func testMalformedBrokerReplyAndMissingFileStayLocalToApplication() async throws {
        let plan = try await AppProxyEnrollment.prepare(applications: [a,b], requested: [a.id,b.id], interactiveID: nil, previous: nil,
            discover: { app in
                if app.id == self.a.id { throw AppProxyIdentityFailure.missingFile }
                return try self.discover(app)
            }, authorize: { records,_ in .init(ownerUID: getuid()+1, records: records, grants: records.map { _ in Data([1]) }) })
        XCTAssertNil(plan.snapshot)
        XCTAssertEqual(plan.failures, [a.id: "missingFile", b.id: "malformed"])
    }
    @MainActor func testDuplicateOwnershipRejectsOnlyConflictingApplication() async throws {
        var duplicate = b; duplicate.path = a.path
        let plan = try await AppProxyEnrollment.prepare(applications: [a,duplicate], requested: [a.id,b.id], interactiveID: nil, previous: nil,
            discover: { try self.discover($0) }, authorize: { records,_ in self.snapshot(records) })
        XCTAssertEqual(plan.failures[b.id], "discoveryFailed")
        XCTAssertEqual(plan.snapshot?.records.first { $0.path == self.a.path }?.category, a.id)
    }
    @MainActor func testAuthorizationRecoveryDoesNotRequireRemovingEntries() async throws {
        let apps = [a,b]
        var denied = true
        func prepare() async throws -> AppProxyEnrollment {
            try await AppProxyEnrollment.prepare(applications: apps, requested: [a.id,b.id], interactiveID: nil, previous: nil,
                discover: { try self.discover($0) }, authorize: { records,_ in
                    if denied && records.contains(where: { $0.category == self.b.id }) { throw AppProxyIdentityFailure.staleAuthorization }
                    return self.snapshot(records)
                })
        }
        let before = try await prepare(); XCTAssertNotNil(before.failures[b.id])
        denied = false
        let after = try await prepare(); XCTAssertTrue(after.failures.isEmpty)
        XCTAssertEqual(Set(after.snapshot!.records.filter { $0.category != "cli_host" }.map(\.category)), [a.id,b.id])
        XCTAssertEqual(apps.count, 2)
    }
}

extension AppProxyEnrollmentTests {
    @MainActor func testConsentWaitRenewsExistingLeaseAndJoinsBeforePublication() async throws {
        var renewals = 0
        let value = try await AppProxyAuthorizationLease.run(interval: 1_000_000, renew: { renewals += 1 }, operation: {
            try await Task.sleep(nanoseconds: 20_000_000)
            return 42
        })
        XCTAssertEqual(value, 42); XCTAssertGreaterThan(renewals, 0)
        let finished = renewals
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(renewals, finished)
    }
    @MainActor func testFailedExistingLeaseCannotBeHiddenBySuccessfulNewConsent() async {
        do {
            _ = try await AppProxyAuthorizationLease.run(interval: 1_000_000, renew: { throw AppProxyIdentityFailure.wrongUser }, operation: {
                try await Task.sleep(nanoseconds: 20_000_000)
                return true
            })
            XCTFail("An invalid previous lease must stop publication")
        } catch { XCTAssertEqual(error as? AppProxyIdentityFailure, .wrongUser) }
    }
}
