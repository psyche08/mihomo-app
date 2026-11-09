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
            // The bridge probe keeps that guarantee even when a DNS Proxy
            // provider rewrote its transaction ID on the way in.
            XCTAssertFalse(policy.allowsOriginalDNSFallback(for: DNSMessage.bridgeHealthQuery(identifier: 0xbeef)))
        }
    }

    /// DNS Proxy providers (MTTA among them) forward standard QUERY messages
    /// but drop other opcodes, so the 127.0.0.53 probe is an ordinary A query.
    func testBridgeProbeIsAStandardQueryRecognisedRegardlessOfTransactionID() throws {
        let probe = DNSMessage.bridgeHealthQuery(identifier: 0x1234)
        XCTAssertEqual(Array(probe.prefix(2)), [0x12, 0x34])
        XCTAssertEqual(probe[2] & 0x80, 0, "query, not response")
        XCTAssertEqual((probe[2] >> 3) & 0x0f, 0, "standard QUERY opcode")
        XCTAssertEqual(try DNSMessage.questionName(probe), DNSMessage.runtimeHealthName)
        let identifiers = Set((0..<8).map { _ in DNSMessage.bridgeHealthQuery().prefix(2) })
        XCTAssertGreaterThan(identifiers.count, 1, "IDs are random per probe")

        var rewritten = probe
        rewritten[0] = 0xab; rewritten[1] = 0xcd
        XCTAssertTrue(DNSMessage.isRuntimeHealthQuery(rewritten))
        XCTAssertTrue(DNSMessage.isRuntimeHealthQuery(DNSMessage.runtimeHealthQuery))
        XCTAssertFalse(DNSMessage.isRuntimeHealthQuery(DNSMessage.addressQuery(for: "example.com")!))
        var answered = probe; answered[2] |= 0x80
        XCTAssertFalse(DNSMessage.isRuntimeHealthQuery(answered))
        XCTAssertFalse(DNSMessage.isRuntimeHealthQuery(probe.prefix(11)))
    }

    func testBridgeProbeAcceptsAnyWellFormedAnswerForItsOwnQuestion() throws {
        let probe = DNSMessage.bridgeHealthQuery(identifier: 0x4242)
        var nxdomain = probe; nxdomain[2] = 0x81; nxdomain[3] = 0x83
        XCTAssertTrue(DNSMessage.isBridgeHealthResponse(nxdomain, query: probe))
        var servfail = probe; servfail[2] = 0x81; servfail[3] = 0x82
        XCTAssertTrue(DNSMessage.isBridgeHealthResponse(servfail, query: probe))

        var wrongID = nxdomain; wrongID[1] ^= 1
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(wrongID, query: probe))
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(probe, query: probe), "a reflected query is no answer")
        var truncated = nxdomain; truncated[2] |= 0x02
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(truncated, query: probe))
        var otherOpcode = nxdomain; otherOpcode[2] |= 0x10
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(otherOpcode, query: probe))
        let other = DNSMessage.addressQuery(for: "example.com", identifier: 0x4242)!
        var otherAnswer = other; otherAnswer[2] = 0x81; otherAnswer[3] = 0x80
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(otherAnswer, query: probe))
        XCTAssertFalse(DNSMessage.isBridgeHealthResponse(nxdomain.prefix(11), query: probe))
    }
}
