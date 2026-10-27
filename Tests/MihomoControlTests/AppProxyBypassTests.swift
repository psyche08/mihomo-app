import XCTest
@testable import MihomoControl

final class AppProxyBypassTests: XCTestCase {
    func testPrivateVPNAddressesAndPublicBoundary() throws {
        let policy = AppProxyBypassPolicy()
        try policy.validate()
        for host in ["192.168.50.20", "10.0.0.1", "172.16.0.1", "172.31.255.254",
                     "169.254.1.2", "fd12::1", "fe80::1%utun9", "::ffff:192.168.50.20"] {
            XCTAssertTrue(policy.contains(host), host)
        }
        for host in ["172.15.255.255", "172.32.0.1", "192.169.0.1", "100.64.0.1", "1.1.1.1",
                     "198.18.0.1", "198.18.1.2", "2001:4860::8888", "chatgpt.com", "testmac.local",
                     "192.168.50.20.attacker.test", "fe80::1%", "192.168.1.1%en0"] {
            XCTAssertFalse(policy.contains(host), host)
        }
    }
    func testExplicitRangesDisabledPolicyAndValidation() throws {
        let policy = AppProxyBypassPolicy(cidrs: ["100.64.0.0/10", "203.0.113.12/32", "2001:db8::/32"])
        try policy.validate()
        XCTAssertTrue(policy.contains("100.127.255.254"))
        XCTAssertTrue(policy.contains("203.0.113.12"))
        XCTAssertFalse(policy.contains("203.0.113.13"))
        XCTAssertTrue(policy.contains("2001:db8::2"))
        XCTAssertFalse(AppProxyBypassPolicy(cidrs: []).contains("192.168.50.20"))
        for ranges in [["0.0.0.0/0"], ["::/0"], ["198.18.0.0/16"], ["198.0.0.0/8"],
                       ["192.168.1.1"], ["10.0.0.0/33"], ["fd00::/129"], ["::ffff:10.0.0.0/104"],
                       ["fe80::%en0/64"], ["10.0.0.0/8,DIRECT"], ["10.0.0.0/8\n"],
                       ["10.0.0.0/8", "10.0.0.0/8"], Array(repeating: "10.0.0.0/8", count: 65)] {
            XCTAssertThrowsError(try AppProxyBypassPolicy(cidrs: ranges).validate(), ranges.description)
        }
    }
    func testSettingsMigrationAndExplicitDisableSurviveRoundTrip() throws {
        let legacy = try JSONDecoder().decode(AppProxySettings.self, from: Data(#"{"routes":{}}"#.utf8))
        XCTAssertEqual(legacy.bypass, .init())
        for cidrs in [[], ["192.168.50.20/32"]] {
            let settings = AppProxySettings(bypass: .init(cidrs: cidrs))
            XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(settings)), settings)
        }
    }
}
