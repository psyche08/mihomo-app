import Foundation
import MihomoControl
import XCTest

final class ControlProtocolTests: XCTestCase {
    func testComponentUpdatePackageBinaryRoundTrip() throws {
        let package = ComponentUpdatePackage(
            appVersion: "0.4.0",
            components: [
                ManagedComponent.daemon.rawValue: Data([0, 1, 2]),
                ManagedComponent.agent.rawValue: Data([3, 4]),
                ManagedComponent.mihomo.rawValue: Data([5, 6, 7, 8]),
            ]
        )

        let decoded = try ComponentUpdatePackage.decode(package.encoded())
        XCTAssertEqual(decoded.formatVersion, ComponentUpdatePackage.currentFormatVersion)
        XCTAssertEqual(decoded.appVersion, "0.4.0")
        XCTAssertEqual(decoded.components, package.components)
    }

    func testComponentDigestIsStable() {
        XCTAssertEqual(
            ComponentUpdatePackage.digest(Data("MihomoBox".utf8)),
            "a6cf9ca5fc8c961aa8dfc56139625e8dd3dfe6f3d3df86c1db15db06b9c23194"
        )
    }
}

extension ControlProtocolTests {
    func testDNSQueryIsForwardable() {
        // The dashboard's DNS Query tool was refused, so the tab simply failed.
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "GET", path: "/dns/query"))
        // Only GET: nothing about that tool should be able to write.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/dns/query"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "DELETE", path: "/dns/query"))
    }

    func testUpgradeAndUnknownPathsStayRefused() {
        // These keep the WebView from replacing managed binaries or the UI.
        // The bridge answers them 403 before they get here; this is the layer
        // behind it, and it must refuse them on its own.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade/ui"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade/core"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/restart"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/anything-else"))
        // A path that merely starts with an allowed one is not allowed.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/dns/query/extra"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/configs/extra"))
    }

    func testParameterisedRoutesAcceptOneSegmentOnly() {
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/Node"))
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "GET", path: "/proxies/Node/delay"))
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "DELETE", path: "/connections/abc"))
        // An empty or multi-segment name must not slip through.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/a/b"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/proxies//delay"))
        // Methods are per-route, not global.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/proxies/Node"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/connections/abc"))
    }

    /// A self-replacing daemon drops the connection instead of replying, and
    /// that must read as "it went away", not "it refused" — otherwise a
    /// successful component upgrade reports itself as a failure.
    func testDisconnectionIsDistinguishedFromRefusal() {
        XCTAssertTrue(ControlError.connectionFailed.isDisconnection)
        XCTAssertTrue(ControlError.invalidReply.isDisconnection)

        XCTAssertFalse(ControlError.rejected("Mihomo agent is not running").isDisconnection)
        XCTAssertFalse(ControlError.unsignedProcess.isDisconnection)
        XCTAssertFalse(ControlError.invalidSigningInformation.isDisconnection)
        XCTAssertFalse(ControlError.invalidRequirement.isDisconnection)
        XCTAssertFalse(ControlError.invalidComponentSignature.isDisconnection)
    }
}
