import Foundation
import XCTest
@testable import MihomoDNSCore

final class LegacyLocalDoHTests: XCTestCase {
    func testProfilePresenceIsProvenOnlyByTheFixedIdentifier() throws {
        let installed: [String: Any] = ["_computerlevel": [[
            "ProfileIdentifier": LegacyLocalDoH.profileIdentifier,
            "ProfileItems": [["PayloadContent": ["DNSSettings": [
                "ServerURL": "https://127.0.0.1/dns-query",
                "SupplementalMatchDomains": ["example.com"],
            ]]]],
        ]]]
        XCTAssertEqual(LegacyLocalDoH.profilePresence(in: try plist(installed)), true)
        XCTAssertEqual(LegacyLocalDoH.profilePresence(in: try plist([
            LegacyLocalDoH.profileIdentifier: ["ProfileItems": []],
        ])), true)
        XCTAssertEqual(LegacyLocalDoH.profilePresence(in: try plist(["_computerlevel": [[
            "ProfileIdentifier": "com.example.other",
            "ProfileDescription": LegacyLocalDoH.profileIdentifier,
        ]]])), false, "only identifier fields count")
        XCTAssertEqual(LegacyLocalDoH.profilePresence(in: try plist([String: Any]())), false)
        XCTAssertEqual(LegacyLocalDoH.profilePresence(in: Data(
            "There are no configuration profiles installed in the system domain\n".utf8
        )), false)
        XCTAssertNil(LegacyLocalDoH.profilePresence(in: Data("unexpected output".utf8)))
        XCTAssertNil(LegacyLocalDoH.profilePresence(in: Data()))
    }

    func testStoredFingerprintAcceptsOnlyAFortyDigitHexLine() {
        let digest = String(repeating: "aB", count: 20)
        XCTAssertEqual(LegacyLocalDoH.storedFingerprint(Data((digest + "\n").utf8)), digest.uppercased())
        XCTAssertEqual(LegacyLocalDoH.storedFingerprint(Data("  \(digest)  \nrest".utf8)), digest.uppercased())
        XCTAssertNil(LegacyLocalDoH.storedFingerprint(Data(String(digest.dropLast()).utf8)))
        XCTAssertNil(LegacyLocalDoH.storedFingerprint(Data((digest + "0").utf8)))
        XCTAssertNil(LegacyLocalDoH.storedFingerprint(Data(String(repeating: "g", count: 40).utf8)))
        XCTAssertNil(LegacyLocalDoH.storedFingerprint(Data("-Z \(digest)".utf8)))
        XCTAssertNil(LegacyLocalDoH.storedFingerprint(Data()))
    }

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
