import XCTest
import Foundation
import Darwin
@testable import MihomoControl

final class AppProxyIdentityTests: XCTestCase {
    func testTeamDefaultsAndLegacyRouteMigration() throws {
        let defaults = AppProxySettings()
        XCTAssertEqual(defaults.applications.map(\.id), ["chatgpt", "claude"])
        XCTAssertEqual(defaults.applications.flatMap(\.teamIdentifiers), ["2DC432GLL2", "Q6L2SF6YDW"])
        XCTAssertNoThrow(try defaults.validate())
        let oldRoutes = Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "Proxy") })
        let data = try JSONSerialization.data(withJSONObject: ["routes": oldRoutes])
        let legacy = try JSONDecoder().decode(AppProxySettings.self, from: data)
        XCTAssertEqual(legacy.applications, AppProxyEntry.legacyDefaults)
        XCTAssertEqual(legacy.routes, oldRoutes)
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(legacy)), legacy)
        XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(defaults)), defaults)
    }
    func testCodeAccessScopeNeverIncludesVersionOrDataParent() throws {
        let root = "/Users/test/Library/Application Support/Claude/claude-code/2.1/hash/claude.app"
        XCTAssertEqual(try AppProxyCodeIdentity.accessURL(for: root + "/Contents/MacOS/claude").path, root)
        let helper = root + "/Contents/Frameworks/Helper.app"
        XCTAssertEqual(try AppProxyCodeIdentity.accessURL(for: helper + "/Contents/MacOS/Helper").path, helper)
        let standalone = "/Users/test/.claude/remote/ccd-cli/version"
        XCTAssertEqual(try AppProxyCodeIdentity.accessURL(for: standalone).path, standalone)
        XCTAssertThrowsError(try AppProxyCodeIdentity.accessURL(for: root + "/data"))
        XCTAssertThrowsError(try AppProxyCodeIdentity.accessURL(for: root + "/../escape"))
    }
    func testSignedSystemIdentityAndWrongPublisher() throws {
        let identity = try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "cli")
        XCTAssertFalse(identity.cdHash.isEmpty)
        try identity.validateFile()
        XCTAssertThrowsError(try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "cli", team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code"))
        XCTAssertThrowsError(try AppProxyCodeIdentity.inspect(path: "/etc/hosts", category: "cli"))
    }
    func testSnapshotRejectsAmbiguousPathsAndMissingAuthorization() throws {
        let identity = try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "cli")
        XCTAssertThrowsError(try AppProxyIdentitySnapshot(ownerUID: 0, records: [identity], grants: [Data([1])]).encoded())
        XCTAssertThrowsError(try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity, identity], grants: [Data([1]), Data([1])]).encoded())
        XCTAssertThrowsError(try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: []).encoded())
        let snapshot = AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])])
        XCTAssertEqual(try AppProxyIdentitySnapshot.decode(snapshot.encoded()), snapshot)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        legacy["version"] = 1
        XCTAssertThrowsError(try AppProxyIdentitySnapshot.decode(JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertThrowsError(try AppProxyAccessLease(snapshot)) // malformed/stale capability is not a path fallback
    }
    func testNoFollowAndSamePathReplacement() throws {
        let temporary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let root = temporary
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("first".utf8).write(to: file)
        let initial = try AppProxyFileStamp.read(file.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AppProxyFileStamp.read(link.path))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: URL(fileURLWithPath: "/usr/bin"))
        XCTAssertThrowsError(try AppProxyFileStamp.read(outside.appendingPathComponent("curl").path))
        try Data("first".utf8).write(to: file, options: .atomic)
        XCTAssertNotEqual(try AppProxyFileStamp.read(file.path), initial)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try AppProxyFileStamp.read(file.path))
    }
    func testGenerationTransactionRollbackExpiryAndReplay() throws {
        let a=UUID(), b=UUID(), c=UUID()
        var gate=AppProxyGenerationGate(a)
        XCTAssertThrowsError(try gate.prepare(b, expected: c, now: 0))
        try gate.prepare(b, expected: a, now: 0)
        XCTAssertEqual(gate.current,a) // prepare cannot activate policy
        gate.abort(); XCTAssertEqual(gate.current,a)
        XCTAssertThrowsError(try gate.commit(b, now: 1))
        try gate.prepare(b, expected: a, now: 2)
        XCTAssertTrue(gate.expirePrepared(now: 33))
        XCTAssertThrowsError(try gate.commit(b, now: 33))
        try gate.prepare(c, expected: a, now: 34)
        try gate.commit(c, now: 35)
        XCTAssertEqual(gate.current,c)
        XCTAssertThrowsError(try gate.prepare(b, expected: a, now: 36))
    }
    func testAutomaticRefreshCannotChangeApprovedPublisherOrAdHocHash() throws {
        let identity = try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "app_test")
        let snapshot = AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])])
        try snapshot.validateRefresh([identity])
        func replacing(id: String? = nil, team: String? = nil, hash: Data? = nil) -> AppProxyCodeIdentity {
            .init(id: id ?? identity.id, path: identity.path, category: identity.category, requirement: identity.requirement,
                  team: team ?? identity.team, cdHash: hash ?? identity.cdHash, stamp: identity.stamp)
        }
        XCTAssertThrowsError(try snapshot.validateRefresh([replacing(id: "forged")]))
        XCTAssertThrowsError(try snapshot.validateRefresh([replacing(team: "Q6L2SF6YDW")]))
        XCTAssertNil(identity.team) // system code has no third-party Team ID; changed hash needs approval
        XCTAssertThrowsError(try snapshot.validateRefresh([replacing(hash: Data([9]))]))
    }
    func testScopesMatchMostSpecificAndCoverRefresh() throws {
        let team = AppProxyScope(category: "app_a", kind: .team, value: "2DC432GLL2")
        let wide = AppProxyScope(category: "app_b", kind: .directory, value: "/Users/me/.codex")
        let deep = AppProxyScope(category: "app_c", kind: .directory, value: "/Users/me/.codex/computer-use")
        let scopes = [team, wide, deep]
        XCTAssertEqual(AppProxyScope.match(path: "/Users/me/.codex/computer-use/x/bin", team: "2DC432GLL2", in: scopes), deep)
        XCTAssertEqual(AppProxyScope.match(path: "/Users/me/.codex/bin/node", team: nil, in: scopes), wide)
        XCTAssertEqual(AppProxyScope.match(path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", team: "2DC432GLL2", in: scopes), team)
        XCTAssertNil(AppProxyScope.match(path: "/Users/me/.codexfoo/bin", team: "OTHERTEAM1", in: scopes))
        XCTAssertNil(AppProxyScope.match(path: "/Users/me/.codex", team: nil, in: scopes), "the directory itself is not code under it")
        XCTAssertFalse(AppProxyScope(category: "a", kind: .team, value: "lower12345").isValid)
        XCTAssertFalse(AppProxyScope(category: "a", kind: .directory, value: "/").isValid)
        XCTAssertFalse(AppProxyScope(category: "a", kind: .directory, value: "/tmp/../etc").isValid)
        XCTAssertEqual(team.requirement, "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"")
        XCTAssertNil(wide.requirement)

        let identity = try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "app_test")
        let snapshot = AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])])
        let moved = AppProxyCodeIdentity(id: identity.id, path: "/opt/tools/curl", category: "app_test", requirement: identity.requirement,
                                         team: nil, cdHash: Data([9]), stamp: identity.stamp)
        XCTAssertThrowsError(try snapshot.validateRefresh([moved].map { AppProxyCodeIdentity(id: $0.id, path: $0.path, category: "app_x",
            requirement: $0.requirement, team: $0.team, cdHash: $0.cdHash, stamp: $0.stamp) }))
        try snapshot.validateRefresh([moved], scopes: [.init(category: "app_test", kind: .directory, value: "/opt/tools")])
        XCTAssertThrowsError(try snapshot.validateRefresh([moved], scopes: [.init(category: "app_other", kind: .directory, value: "/opt/tools")]))
    }
    func testSnapshotScopesDecodeCompatiblyAndRequireOneGrantPerDirectory() throws {
        let identity = try AppProxyCodeIdentity.inspect(path: "/usr/bin/curl", category: "app_test")
        let old = AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "scopes"); json.removeValue(forKey: "scopeGrants")
        let decoded = try AppProxyIdentitySnapshot.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.scopes, []); XCTAssertEqual(decoded, old)
        let directory = AppProxyScope(category: "app_test", kind: .directory, value: "/opt/tools")
        let team = AppProxyScope(category: "app_test", kind: .team, value: "2DC432GLL2")
        XCTAssertNoThrow(try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])],
                                                      scopes: [team, directory], scopeGrants: [Data([2])]).validate())
        XCTAssertThrowsError(try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])],
                                                          scopes: [team, directory], scopeGrants: []).validate())
        XCTAssertThrowsError(try AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [Data([1])],
                                                          scopes: [directory, directory], scopeGrants: [Data([2]), Data([2])]).validate())
    }
    func testSettingsScopesAreValidatedAndOwnedByOneApplication() throws {
        var entry = AppProxyEntry.legacyDefaults[1]
        entry.teamIdentifiers = ["2DC432GLL2"]; entry.directories = ["/Users/me/.codex"]
        let decoded = try JSONDecoder().decode(AppProxyEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(entry.scopes.map(\.kind), [.team, .directory])
        XCTAssertNoThrow(try AppProxySettings(applications: [entry]).validate())
        let legacy = try JSONDecoder().decode(AppProxyEntry.self, from: Data(#"{"id":"chatgpt","title":"T","port":17971}"#.utf8))
        XCTAssertEqual(legacy.teamIdentifiers, []); XCTAssertEqual(legacy.directories, [])
        XCTAssertTrue(legacy.capturesLaunchedCLIs, "older settings capture launched CLIs")
        var direct = entry; direct.capturesLaunchedCLIs = false
        XCTAssertEqual(try JSONDecoder().decode(AppProxyEntry.self, from: JSONEncoder().encode(direct)), direct)
        var other = AppProxyEntry.legacyDefaults[2]
        other.teamIdentifiers = ["2DC432GLL2"]
        XCTAssertThrowsError(try AppProxySettings(applications: [entry, other]).validate())
        for (teams, directories) in [(["2dc432gll2"], []), ([], ["/"]), ([], ["relative"]), (Array(repeating: "2DC432GLL2", count: 2), [])] {
            var invalid = AppProxyEntry.legacyDefaults[1]
            invalid.teamIdentifiers = teams; invalid.directories = directories
            XCTAssertThrowsError(try AppProxySettings(applications: [invalid]).validate(), "\(teams) \(directories)")
        }
    }
    func testAuditReceiptPreservesPIDVersionWithoutTrafficData() {
        var words: [UInt32] = [501,501,20,501,20,123,10,7]
        let token = words.withUnsafeMutableBytes { Data($0) }
        let generation = UUID()
        let evidence = AppProxyFlowEvidence(flow: UUID(), token: token, stage: "dnsAnswered", generation: generation)
        XCTAssertEqual(evidence.generation, generation)
        XCTAssertEqual(evidence.pid,123); XCTAssertEqual(evidence.pidVersion,7)
        XCTAssertEqual(AppProxyFlowEvidence.word(token,1),501)
        XCTAssertEqual(AppProxyFlowEvidence.word(Data(),1),0)
    }
    func testFlowOwnersShareExecutablePathsAndStayBounded() throws {
        let owners = AppProxyFlowOwners([(52000, false, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 10),
                                         (52001, false, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 10),
                                         (52000, true, "/opt/homebrew/Cellar/packer/1.15.3/bin/packer", 11)])
        XCTAssertEqual(owners.executables.count, 2, "repeated paths are sent once")
        XCTAssertEqual(owners.owner(port: 52000, udp: true)?.path, "/opt/homebrew/Cellar/packer/1.15.3/bin/packer")
        XCTAssertEqual(owners.owner(port: 52000, udp: false)?.pid, 10)
        XCTAssertNil(owners.owner(port: 52002, udp: false))
        let many = AppProxyFlowOwners((0..<1000).map { (UInt16($0), false, "/tool/\($0 % 300)", UInt32($0)) })
        XCTAssertLessThanOrEqual(many.flows.count, AppProxyFlowOwners.maximumFlows)
        XCTAssertLessThanOrEqual(many.executables.count, AppProxyFlowOwners.maximumExecutables)
        let reply = AppProxyRuntimeStatus(generation: UUID(), ready: true, verifiedTargets: 1, flowOwners: many)
        XCTAssertLessThan(try JSONEncoder().encode(reply).count, 65536, "fits the provider message limit")
        // Replies from a provider without the owner table still decode.
        let legacy = #"{"ready":true,"verifiedTargets":1,"counters":{},"recentFlows":[]}"#
        let decoded = try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.flowOwners)
        XCTAssertNil(decoded.providerVersion, "a provider without a version is treated as older than the bundle")
        let current = AppProxyRuntimeStatus(generation: nil, ready: true, verifiedTargets: 0, providerVersion: "1.0.9")
        XCTAssertEqual(try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: JSONEncoder().encode(current)).providerVersion, "1.0.9")
    }
}
