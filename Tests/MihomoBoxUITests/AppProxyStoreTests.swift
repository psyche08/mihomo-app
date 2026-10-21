import XCTest
import MihomoControl
@testable import MihomoBoxUI

private final class RoutingGateway: AppProxyRoutingGateway, @unchecked Sendable {
    var state = AppProxyRoutingState(settings: .init(routes: Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "one") })), profile: "test.yaml", revision: "1")
    var fail = false
    func fetchAppProxyRouting() async throws -> AppProxyRoutingState { state }
    func fetchProxies() async throws -> ControllerProxyCatalog {
        .init(proxies: ["one": .init(name: "one", type: "Shadowsocks"), "two": .init(name: "two", type: "Trojan"), "DIRECT": .init(name: "DIRECT", type: "Direct")])
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
    func status() async throws -> AppProxyExtensionStatus { .init(available: true, enabled: enabled, connected: enabled) }
    func setEnabled(_ enabled: Bool) async throws { self.enabled = enabled }
}
final class AppProxyStoreTests: XCTestCase {
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
