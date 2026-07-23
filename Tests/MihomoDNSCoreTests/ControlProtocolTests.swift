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
