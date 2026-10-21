import XCTest
import MihomoControl
@testable import MihomoBoxUI

private final class RoutingGateway: AppProxyRoutingGateway, @unchecked Sendable {
    var state = AppProxyRoutingState(settings: .init(routes: Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "one") })), profile: "test.yaml", revision: "1")
    var fail = false
    func fetchAppProxyRouting() async throws -> AppProxyRoutingState { state }
    func fetchProxies() async throws -> ControllerProxyCatalog {
        .init(proxies: ["one": .init(name: "one", type: "Shadowsocks"), "two": .init(name: "two", type: "Trojan"), "DIRECT": .init(name: "DIRECT", type: "Direct"), "PASS-RULE": .init(name: "PASS-RULE", type: "PassRule")])
    }
    func setAppProxyRouting(_ update: AppProxyRoutingUpdate) async throws -> AppProxyRoutingState {
        if fail { throw AppProxySettingsError.staleState }
        guard update.expectedRevision == state.revision else { throw AppProxySettingsError.staleState }
        state = .init(settings: update.settings, profile: state.profile, revision: "2")
        return state
    }
}
@MainActor private final class ExtensionService: DashboardAppProxyService {
    var enabled = false
    func status(applications: [AppProxyEntry]) async throws -> AppProxyExtensionStatus { .init(available: true, enabled: enabled, connected: enabled) }
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws { self.enabled = enabled }
    func chooseApplication(port: UInt16) async throws -> AppProxyEntry? {
        .init(id: "app_00000000-0000-0000-0000-000000000001", title: "Test App", path: "/Applications/Test.app", port: port)
    }
}
final class AppProxyStoreTests: XCTestCase {
    @MainActor func testAddRemoveAndEmptyListPersistWithoutChangingOtherRoutes() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        await model.addApplication()
        let entry = try XCTUnwrap(model.draft.applications.last)
        XCTAssertEqual(entry.port, 17975)
        XCTAssertFalse(model.valid)
        model.draft.routes[entry.id] = "two"
        try await model.apply()
        XCTAssertEqual(gateway.state.settings.routes[entry.id], "two")
        XCTAssertEqual(gateway.state.settings.routes["claude"], "one")
        model.removeApplication("claude")
        try await model.apply()
        XCTAssertNil(gateway.state.settings.routes["claude"])
        XCTAssertEqual(gateway.state.settings.routes[entry.id], "two")
        for app in model.draft.applications { model.removeApplication(app.id) }
        XCTAssertTrue(model.valid)
        try await model.apply(); await model.refresh()
        XCTAssertTrue(model.draft.applications.isEmpty)
        do { try await model.setEnabled(true); XCTFail("Empty list must not enable") } catch {}
    }
    @MainActor func testEnabledExtensionPreventsApplicationTopologyChanges() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        service.enabled = true; model.configure(service); await model.refresh()
        model.removeApplication("claude"); await model.addApplication()
        XCTAssertEqual(model.draft.applications, AppProxyEntry.defaults)
        model.draft.applications.removeLast(); model.draft.routes.removeValue(forKey: "claude_cli")
        do { try await model.apply(); XCTFail("Must disable before editing applications") } catch {}
        XCTAssertEqual(gateway.state.settings.applications, AppProxyEntry.defaults)
    }
    @MainActor func testIndependentSelectionOnlyCommitsOnVerifiedReply() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway)
        await model.refresh()
        XCTAssertEqual(model.nodes, ["one", "two"])
        model.draft.routes["claude"] = "two"
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.routing?.settings.routes["claude"], "one")
        try await model.apply()
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.routing?.settings.routes["claude"], "two")
        XCTAssertEqual(model.routing?.settings.routes["chatgpt"], "one")
    }
    @MainActor func testFailedApplyCannotEnableUsingStaleSettings() async {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        model.draft.routes["claude"] = "two"; gateway.fail = true
        do { try await model.apply(); XCTFail("Expected rejection") } catch {}
        XCTAssertNil(model.routing)
        do { try await model.setEnabled(true); XCTFail("Expected stale state") } catch {}
        XCTAssertFalse(service.enabled)
    }
    @MainActor func testExternalProfileChangePreventsEnableAndDisableStillWorks() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        gateway.state.revision = "external"
        do { try await model.setEnabled(true); XCTFail("Expected stale state") } catch {}
        XCTAssertFalse(service.enabled)
        try await model.setEnabled(false)
        XCTAssertFalse(model.extensionStatus.enabled)
    }
}
