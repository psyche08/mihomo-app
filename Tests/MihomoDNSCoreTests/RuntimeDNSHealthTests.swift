import Foundation
import XCTest
@testable import MihomoDNSCore

final class RuntimeDNSHealthTests: XCTestCase {
    func testLivenessRequiresCorrelatedLocalProtocolResponse() throws {
        let query = DNSMessage.runtimeHealthQuery
        XCTAssertEqual(try DNSMessage.questionName(query), "mihomobox-health.invalid")
        XCTAssertFalse(DNSMessage.isRuntimeHealthResponse(query))
        var reply = query
        reply[2] |= 0x80
        reply[3] = 4
        XCTAssertTrue(DNSMessage.isRuntimeHealthResponse(reply))
        for (index, value): (Int, UInt8) in [(0, 0), (2, 0x80), (2, 0x92), (3, 0), (3, 2)] {
            var invalid = reply; invalid[index] = value
            XCTAssertFalse(DNSMessage.isRuntimeHealthResponse(invalid))
        }
        XCTAssertFalse(DNSMessage.isRuntimeHealthResponse(reply.prefix(11)))
    }

    func testPhysicalFallbackCannotSatisfyManagedLiveness() {
        for yaml in ["dns:\n  enhanced-mode: redir-host\n", "dns:\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: rule\n  fake-ip-filter:\n    - MATCH,real-ip\n"] {
            let policy = FakeIPDNSPolicy(yaml: yaml)
            XCTAssertFalse(policy.allowsOriginalDNSFallback(for: DNSMessage.runtimeHealthQuery))
            XCTAssertTrue(policy.allowsOriginalDNSFallback(for: DNSMessage.addressQuery(for: "example.com")!))
        }
    }
}
