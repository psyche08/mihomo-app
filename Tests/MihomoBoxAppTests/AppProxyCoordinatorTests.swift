import XCTest
import NetworkExtension
import MihomoControl
@testable import MihomoBoxApp

final class AppProxyCoordinatorTests: XCTestCase {
    func testExtraCLIUsesOwnerRouteAndParticipatesInTerminalRules() throws {
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Test", path: "/bin/ls",
                                  port: 17975, executablePaths: ["/usr/bin/curl"])
        let discovered = try AIAppTargets(requireAll: false, applications: [entry])
        let curl = try XCTUnwrap(discovered.targets.first { $0.path == "/usr/bin/curl" })
        XCTAssertEqual(curl.category, entry.id)
        XCTAssertTrue(discovered.rules.contains { $0.matchTools?.contains { $0.matchSigningIdentifier == curl.id } == true })
        var builtin = AppProxyEntry.defaults[0]
        builtin.executablePaths = ["/bin/ls"]
        XCTAssertThrowsError(try AIAppTargets(requireAll: false, applications: [entry, builtin]))
        for path in ["/etc/hosts", "/missing-cli", "/usr/bin"] {
            var invalid = entry; invalid.executablePaths = [path]
            XCTAssertThrowsError(try AIAppTargets(requireAll: false, applications: [invalid]))
        }
        var builtinOnly = builtin; builtinOnly.executablePaths = ["/usr/bin/curl"]
        let builtinTargets = try AIAppTargets(requireAll: false, applications: [builtinOnly])
        XCTAssertEqual(builtinTargets.targets.first { $0.path == "/usr/bin/curl" }?.category, "chatgpt")
    }
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
