import XCTest
import Foundation
import Darwin
@testable import MihomoControl

final class AppProxyIdentityTests: XCTestCase {
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
}
