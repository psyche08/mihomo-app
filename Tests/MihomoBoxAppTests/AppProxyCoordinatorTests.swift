import XCTest
import NetworkExtension
@testable import MihomoBoxApp

final class AppProxyCoordinatorTests: XCTestCase {
    @MainActor func testNewManagerUsesAppProxyProviderAndPerApplicationRouting() {
        let manager: NETunnelProviderManager = AppProxyCoordinator.makeManager()
        XCTAssertTrue(manager is NEAppProxyProviderManager)
        XCTAssertEqual(manager.routingMethod, .sourceApplication)
        XCTAssertFalse(manager.isEnabled)
    }
}
