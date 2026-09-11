import Foundation
import MihomoControl
import XCTest

final class DNSIntegrationModeTests: XCTestCase {
    private var ready: LocalDoHStatus {
        .init(serverPrepared: true, profileInstalled: true,
              profileInspectionSucceeded: true, runtimeHealthy: true,
              systemDNSManaged: false, certificateTrusted: true)
    }

    func testLocalDoHRequiresEveryReadinessGate() {
        XCTAssertEqual(ready.confirmedDNSMode, .localDoH)
        for field in [\LocalDoHStatus.serverPrepared, \.profileInstalled,
                      \.profileInspectionSucceeded, \.runtimeHealthy] {
            var value = ready
            value[keyPath: field] = false
            XCTAssertNil(value.confirmedDNSMode)
        }
        for trust: Bool? in [false, nil] {
            var value = ready
            value.certificateTrusted = trust
            XCTAssertNil(value.confirmedDNSMode)
        }
    }

    func testLocalDoHSurvivesMissingAgentHealthWhenOriginalDNSBackendIsReady() {
        var value = ready
        value.systemDNSManaged = nil
        XCTAssertEqual(value.confirmedDNSMode, .localDoH)
    }

    func testGlobalDNSRequiresOwnershipAndConfirmedProfileRemoval() {
        var value = ready
        value.globalDNSFallback = true
        value.systemDNSManaged = true
        value.profileInstalled = false
        XCTAssertEqual(value.confirmedDNSMode, .globalDNS)
        value.fallbackProfileRemovalRequired = true
        XCTAssertNil(value.confirmedDNSMode)
        value.fallbackProfileRemovalRequired = false
        value.profileInspectionSucceeded = false
        XCTAssertNil(value.confirmedDNSMode)
        value.profileInspectionSucceeded = true
        value.systemDNSManaged = false
        XCTAssertNil(value.confirmedDNSMode)
    }

    func testTrustCommandIsFixedAdminSSLOnlyAndDoesNotExecute() {
        XCTAssertEqual(LocalDoHTrustCommand.executable, "/usr/bin/security")
        XCTAssertEqual(LocalDoHTrustCommand.arguments, [
            "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
            "-k", "/Library/Keychains/System.keychain",
            "/Library/Application Support/Mihomo App/local-doh/ca.der",
        ])
        XCTAssertEqual(LocalDoHTrustCommand.timeout, 120)
    }

    func testDNSModeCannotEncodeAnOutboundModeOrArbitraryCommand() throws {
        XCTAssertNil(DNSIntegrationMode(rawValue: "global"))
        XCTAssertNil(DNSIntegrationMode(rawValue: "direct"))
        for mode in DNSIntegrationMode.allCases {
            let request = ControlRequest(operation: .setDNSMode, arguments: ["mode": mode.rawValue])
            let copy = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(copy.operation, .setDNSMode)
            XCTAssertEqual(copy.arguments, ["mode": mode.rawValue])
            XCTAssertNil(copy.payload)
        }
    }
}
