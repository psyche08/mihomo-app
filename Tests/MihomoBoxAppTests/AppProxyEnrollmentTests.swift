import XCTest
import MihomoControl
@testable import MihomoBoxApp

final class AppProxyEnrollmentTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default
    override func setUpWithError() throws {
        // Below the repository: temporary directories sit behind the /var and /tmp links,
        // and code folders must equal their resolved path.
        home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/enrollment-test-\(UUID().uuidString)").path
        for folder in ["a1", "a2", "b"] {
            try fm.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try? fm.removeItem(atPath: home) }

    private let a = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "A", path: "/Applications/A.app", port: 17975,
                                  teamIdentifiers: ["AAAAAAAAA1"], signingIdentifiers: ["dev.example.a", "a-cli"],
                                  directories: ["~/a1", "~/a2", "~/a-missing"])
    private let b = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000002", title: "B", path: "/Applications/B.app", port: 17976,
                                  teamIdentifiers: ["BBBBBBBBB2"], signingIdentifiers: ["dev.example.b"], directories: ["~/b"])
    /// No LaunchServices, launch hosts or registration: the policy assembly alone.
    private func build(_ policies: [AppProxyApplicationPolicy]) async -> AIAppTargets {
        AIAppTargets(applications: policies, lookup: { _ in [] }, register: { _ in }, hostExecutables: [])
    }
    /// Grants every existing requested folder, as the broker does for approved folders.
    private func grant(_ category: String, _ folders: [String]) -> AppProxyFolderGrants {
        let existing = folders.filter { fm.fileExists(atPath: $0) }
        return .init(ownerUID: getuid(), category: category, folders: existing, grants: existing.map { _ in Data([1]) })
    }
    private func prepare(_ apps: [AppProxyEntry], requested: Set<String>, interactiveID: String? = nil,
                         authorize: @escaping (String, [String], Bool) throws -> AppProxyFolderGrants) async throws -> AppProxyEnrollment {
        try await AppProxyEnrollment.prepare(applications: apps, requested: requested, interactiveID: interactiveID, home: home,
                                             build: { await self.build($0) }, authorize: { try authorize($0, $1, $2) })
    }

    @MainActor func testPolicyCarriesTeamsIdentifiersAndExistingGrantedFolders() async throws {
        var calls: [(String, [String], Bool)] = []
        let plan = try await prepare([a, b], requested: [a.id, b.id], interactiveID: a.id) { category, folders, interactive in
            calls.append((category, folders, interactive)); return self.grant(category, folders)
        }
        XCTAssertEqual(calls.map(\.0), [a.id, b.id])
        XCTAssertEqual(calls[0].1, [home + "/a1", home + "/a2", home + "/a-missing"], "every configured folder is requested")
        XCTAssertEqual(calls.map(\.2), [true, false], "only the chosen application asks for consent")
        XCTAssertEqual(plan.failures, [:])
        let policy = try XCTUnwrap(plan.policy)
        XCTAssertNoThrow(try policy.validate())
        XCTAssertEqual(policy.ownerUID, getuid())
        XCTAssertEqual(policy.routes, [.init(category: a.id, teams: a.teamIdentifiers, identifiers: a.signingIdentifiers),
                                       .init(category: b.id, teams: b.teamIdentifiers, identifiers: b.signingIdentifiers)])
        XCTAssertEqual(policy.folders, [home + "/a1", home + "/a2", home + "/b"], "a folder that does not exist is not granted")
        XCTAssertEqual(policy.codeStamp, plan.targets.codeStamp)
        // Shared tools list every identifier with its own publisher.
        XCTAssertEqual(plan.targets.tools.map(\.matchSigningIdentifier), ["a-cli", "dev.example.a", "dev.example.b"])
        XCTAssertEqual(plan.targets.tools.first?.matchDesignatedRequirement,
                       AppProxyCode.requirement(identifier: "a-cli", teams: ["AAAAAAAAA1"]))
        XCTAssertTrue(plan.targets.rules.isEmpty, "no top-level code is installed")
        XCTAssertEqual(plan.targets.issues, [:], "applications with existing folders are installed")
        XCTAssertEqual(plan.targets.processRoutes.prefixes[a.id], [home + "/a-missing", home + "/a1", home + "/a2"])
    }
    @MainActor func testDeniedApplicationDoesNotPreventOtherApplicationAndNeverLeaksItsRoute() async throws {
        let plan = try await prepare([a, b], requested: [a.id, b.id], interactiveID: b.id) { category, folders, _ in
            if category == self.b.id { throw AppProxyIdentityFailure.needsAuthorization }
            return self.grant(category, folders)
        }
        XCTAssertEqual(plan.failures, [b.id: "needsAuthorization"])
        XCTAssertEqual(plan.policy?.routes.map(\.category), [a.id])
        XCTAssertFalse(plan.policy?.folders.contains(home + "/b") ?? true)
        XCTAssertFalse(plan.targets.tools.contains { $0.matchSigningIdentifier == "dev.example.b" })
    }
    @MainActor func testPartlyApprovedFoldersStillRouteTheApplication() async throws {
        let plan = try await prepare([a], requested: [a.id]) { category, folders, _ in
            .init(ownerUID: getuid(), category: category, folders: [folders[0]], grants: [Data([1])])
        }
        XCTAssertEqual(plan.failures, [a.id: "needsAuthorization"], "status asks for the remaining folders")
        XCTAssertEqual(plan.policy?.routes.map(\.category), [a.id])
        XCTAssertEqual(plan.policy?.folders, [home + "/a1"])
    }
    @MainActor func testDisabledEntriesAreNotPromptedAndAllDeniedHasNoPolicy() async throws {
        var visited: [String] = []
        let plan = try await prepare([a, b], requested: [a.id], interactiveID: a.id) { category, _, _ in
            visited.append(category); throw AppProxyIdentityFailure.permission
        }
        XCTAssertEqual(visited, [a.id])
        XCTAssertNil(plan.policy)
        XCTAssertTrue(plan.targets.rules.isEmpty && plan.targets.tools.isEmpty)
        XCTAssertEqual(plan.failures, [a.id: "permission"])
    }
    @MainActor func testApplicationsWithoutFoldersNeedNoBrokerAndUnsignedCodeStaysLocal() async throws {
        let readable = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000003", title: "C", path: "/Applications/C.app", port: 17977,
                                     teamIdentifiers: ["CCCCCCCCC3"], signingIdentifiers: ["dev.example.c"])
        // Saved before policy version 5: the Team ID comes from the chosen code, and platform code has none.
        let unsigned = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000004", title: "ls", path: "/bin/ls", port: 17978)
        let unnamed = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000005", title: "X", port: 17979)
        let plan = try await prepare([readable, unsigned, unnamed], requested: [readable.id, unsigned.id, unnamed.id]) { _, _, _ in
            XCTFail("no folders to grant"); throw AppProxyIdentityFailure.permission
        }
        XCTAssertEqual(plan.failures, [unsigned.id: "discoveryFailed", unnamed.id: "undiscoveredTarget"])
        XCTAssertEqual(plan.policy?.routes.map(\.category), [readable.id])
        XCTAssertEqual(plan.policy?.folders, [])
        XCTAssertEqual(plan.targets.issues, [readable.id + ":notInstalled": 1])
    }
    @MainActor func testAuthorizationRecoveryDoesNotRequireRemovingEntries() async throws {
        var denied = true
        func run() async throws -> AppProxyEnrollment {
            try await prepare([a, b], requested: [a.id, b.id]) { category, folders, _ in
                if denied && category == self.b.id { throw AppProxyIdentityFailure.staleAuthorization }
                return self.grant(category, folders)
            }
        }
        let before = try await run()
        XCTAssertEqual(before.failures, [b.id: "staleAuthorization"])
        denied = false
        let after = try await run()
        XCTAssertEqual(after.failures, [:])
        XCTAssertEqual(after.policy?.routes.map(\.category), [a.id, b.id])
        let again = try await run()
        XCTAssertTrue(after.policy?.sameAuthority(as: try XCTUnwrap(again.policy)) ?? false, "an unchanged pass keeps its authority")
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
