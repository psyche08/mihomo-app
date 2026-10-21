import XCTest
import NetworkExtension
import MihomoControl
@testable import MihomoBoxApp

final class AppProxyCoordinatorTests: XCTestCase {
    func testCustomSignedExecutableIncludesIdentityAndRejectsDuplicateOwnership() throws {
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "List", path: "/bin/ls", port: 17975)
        let discovered = try AIAppTargets(requireAll: false, applications: [entry])
        let target = try XCTUnwrap(discovered.targets.first { $0.category == entry.id })
        XCTAssertEqual(target.path, "/bin/ls")
        XCTAssertFalse(target.id.isEmpty)
        XCTAssertFalse(target.requirement.isEmpty)
        var duplicate = entry
        duplicate.id = "app_00000000-0000-0000-0000-000000000002"; duplicate.port = 17976
        XCTAssertThrowsError(try AIAppTargets(requireAll: false, applications: [entry, duplicate]))
        var unsigned = entry; unsigned.path = "/etc/hosts"
        XCTAssertThrowsError(try AIAppTargets(requireAll: false, applications: [unsigned]))
    }
    @MainActor func testNewManagerUsesAppProxyProviderAndPerApplicationRouting() {
        let manager: NETunnelProviderManager = AppProxyCoordinator.makeManager()
        XCTAssertTrue(manager is NEAppProxyProviderManager)
        XCTAssertEqual(manager.routingMethod, .sourceApplication)
        XCTAssertFalse(manager.isEnabled)
    }
}
