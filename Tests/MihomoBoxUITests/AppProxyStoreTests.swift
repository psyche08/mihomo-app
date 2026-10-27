import XCTest
import MihomoControl
@testable import MihomoBoxUI

private final class RoutingGateway: AppProxyRoutingGateway, @unchecked Sendable {
    var state = AppProxyRoutingState(settings: .init(routes: Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "one") })), profile: "test.yaml", revision: "1")
    var writes = 0
    var fail = false
    var failRead = false
    var dropsExecutablePaths = false
    func fetchAppProxyRouting() async throws -> AppProxyRoutingState {
        if failRead { throw AppProxySettingsError.staleState }; return state
    }
    func fetchProxies() async throws -> ControllerProxyCatalog {
        .init(proxies: ["one": .init(name: "one", type: "Shadowsocks"), "two": .init(name: "two", type: "Trojan"), "DIRECT": .init(name: "DIRECT", type: "Direct"), "PASS-RULE": .init(name: "PASS-RULE", type: "PassRule")])
    }
    func setAppProxyRouting(_ update: AppProxyRoutingUpdate) async throws -> AppProxyRoutingState {
        writes += 1
        if fail { throw AppProxySettingsError.staleState }
        guard update.expectedRevision == state.revision else { throw AppProxySettingsError.staleState }
        state = .init(settings: update.settings, profile: state.profile, revision: "2")
        if dropsExecutablePaths {
            for index in state.settings.applications.indices { state.settings.applications[index].executablePaths = [] }
        }
        return state
    }
}
@MainActor private final class ExtensionService: DashboardAppProxyService {
    var enabled = false
    var scans = 0
    var failScan = false
    var scanStarted: (() -> Void)?
    var scanContinuation: CheckedContinuation<[AppProxyExecutable], Error>?
    var suspendScan = false
    var enableStarted: (() -> Void)?
    var enableContinuation: CheckedContinuation<Void, Error>?
    var suspendEnable = false
    func status(settings: AppProxySettings) async throws -> AppProxyExtensionStatus { .init(available: true, enabled: enabled, connected: enabled, applications: applicationStates) }
    func discoverExecutables(applications: [AppProxyEntry]) async throws -> [AppProxyExecutable] {
        scans += 1
        if failScan { throw AppProxySettingsError.invalidExecutables }
        if suspendScan {
            return try await withCheckedThrowingContinuation { continuation in
                scanContinuation = continuation; scanStarted?()
            }
        }
        return applications.map {
            .init(applicationID: $0.id, path: "/test/" + $0.id, signingIdentifier: $0.id,
                  teamIdentifier: nil, requirement: "test")
        }
    }
    var applicationCalls: [(String, Bool)] = []
    var applicationStates: [String: AppProxyApplicationStatus] = [:]
    func setApplicationEnabled(_ id: String, enabled: Bool, settings: AppProxySettings) async throws {
        applicationCalls.append((id, enabled))
        applicationStates[id] = .init(requested: enabled, active: enabled)
    }
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws {
        if suspendEnable {
            try await withCheckedThrowingContinuation { continuation in
                enableContinuation = continuation; enableStarted?()
            }
        }
        self.enabled = enabled
    }
    func chooseApplication(port: UInt16) async throws -> AppProxyEntry? {
        .init(id: "app_00000000-0000-0000-0000-000000000001", title: "Test App", path: "/Applications/Test.app", port: port)
    }
    func chooseExecutable() async throws -> String? { "/usr/bin/curl" }
    var hosts: [AppProxyLaunchHost] = []
    func launchHosts() async -> [AppProxyLaunchHost] { hosts }
}
final class AppProxyStoreTests: XCTestCase {
    func testAppProxyConnectionsAreAttributedToTheVerifiedProcess() {
        let owners = AppProxyFlowOwners([(53001, false, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", 42)])
        let applications = AppProxyEntry.defaults
        let exact = AppProxyAttribution.process(inboundName: "mihomobox-app-chatgpt", sourcePort: "53001", network: "tcp",
                                                owners: owners, applications: applications)
        XCTAssertEqual(exact?.process, "codex")
        XCTAssertEqual(exact?.path, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let unmatched = AppProxyAttribution.process(inboundName: "mihomobox-app-chatgpt", sourcePort: "53001", network: "udp",
                                                    owners: owners, applications: applications)
        XCTAssertEqual(unmatched?.process, applications.first { $0.id == "chatgpt" }?.title, "falls back to the App Proxy application")
        XCTAssertNil(unmatched?.path)
        XCTAssertNil(AppProxyAttribution.process(inboundName: "DEFAULT-TUN", sourcePort: "53001", network: "tcp",
                                                 owners: owners, applications: applications), "other inbounds keep Mihomo's process")
    }
    @MainActor func testExecutableScanCarriesLaunchHostsAcrossStatusRefresh() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        service.hosts = ["/usr/libexec/sshd-session", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]
            .map(AppProxyLaunchHost.init(path:))
        model.configure(service); await model.refresh()
        XCTAssertEqual(model.extensionStatus.launchHosts.map(\.name), ["SSH login", "Visual Studio Code"])
        await model.refresh()
        XCTAssertEqual(model.extensionStatus.launchHosts.count, 2, "a status refresh keeps the last scan's launchers")
        XCTAssertEqual(AppProxyLaunchHost(path: "/usr/sbin/sshd").name, "SSH login")
        XCTAssertEqual(AppProxyLaunchHost(path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal").name, "Terminal")
    }
    @MainActor func testBypassEditsPersistAndRequireDisabledExtension() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        let routes = model.draft.routes
        try model.setBypassCIDRs(["192.168.13.12/32", "fd12::/16"])
        XCTAssertTrue(model.dirty)
        try await model.apply()
        XCTAssertEqual(gateway.state.settings.bypass.cidrs, ["192.168.13.12/32", "fd12::/16"])
        XCTAssertEqual(gateway.state.settings.routes, routes)
        try await model.setEnabled(true)
        XCTAssertThrowsError(try model.setBypassCIDRs([]))
        model.draft.bypass = .init(cidrs: [])
        do { try await model.apply(); XCTFail("Enabled extension must not keep a stale bypass policy") } catch {}
        model.discardChanges()
        try await model.setEnabled(false)
        try model.setBypassCIDRs([])
        try await model.apply()
        await model.refresh()
        XCTAssertTrue(model.draft.bypass.cidrs.isEmpty)
        XCTAssertEqual(model.draft.routes, routes)
    }
    @MainActor func testDaemonDroppingExecutableMembershipCannotReportSuccessfulSave() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        try await model.setExecutablePaths(["/usr/bin/curl"], for: "chatgpt")
        gateway.dropsExecutablePaths = true
        do { try await model.apply(); XCTFail("Must verify saved membership") } catch {}
        XCTAssertNil(model.routing)
        XCTAssertEqual(model.draft.applications[0].executablePaths, ["/usr/bin/curl"])
        do { try await model.setEnabled(true); XCTFail("Must not enable after incomplete save") } catch {}
        XCTAssertFalse(service.enabled)
    }
    @MainActor func testExecutableEditsValidateBeforeDraftAndPersistWithOwnerRoute() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        try await model.setExecutablePaths(["/usr/bin/curl"], for: "chatgpt")
        XCTAssertEqual(model.draft.applications[0].executablePaths, ["/usr/bin/curl"])
        XCTAssertTrue(gateway.state.settings.applications[0].executablePaths.isEmpty)
        XCTAssertEqual(model.changedApplicationCount, 1)
        try await model.apply()
        XCTAssertEqual(gateway.state.settings.applications[0].executablePaths, ["/usr/bin/curl"])
        XCTAssertEqual(gateway.state.settings.routes["chatgpt"], "one")
        let saved = model.draft
        service.failScan = true
        do { try await model.setExecutablePaths(["/invalid"], for: "chatgpt"); XCTFail("Expected signature failure") } catch {}
        XCTAssertEqual(model.draft, saved)
        service.failScan = false
        do { try await model.setExecutablePaths(["/usr/bin/curl"], for: "claude"); XCTFail("Expected duplicate rejection") } catch {}
        XCTAssertEqual(model.draft, saved)
        try await model.setEnabled(true)
        do { try await model.setExecutablePaths([], for: "chatgpt"); XCTFail("Disable first") } catch {}
        XCTAssertEqual(model.draft, saved)
        try await model.setEnabled(false)
        try await model.setExecutablePaths([], for: "chatgpt")
        model.discardChanges()
        XCTAssertEqual(model.draft, saved)
        try await model.setExecutablePaths([], for: "chatgpt")
        try await model.apply()
        XCTAssertTrue(gateway.state.settings.applications[0].executablePaths.isEmpty)
    }
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
    func testTypedAndDroppedPathsNormalize() {
        XCTAssertEqual(AppProxyStore.normalizedPath("  '/usr/bin/curl'\n"), "/usr/bin/curl")
        XCTAssertEqual(AppProxyStore.normalizedPath("\"/usr/bin/curl\""), "/usr/bin/curl")
        XCTAssertEqual(AppProxyStore.normalizedPath("file:///Applications/My%20App.app"), "/Applications/My App.app")
        XCTAssertEqual(AppProxyStore.normalizedPath("~/bin/tool"), NSHomeDirectory() + "/bin/tool")
        XCTAssertEqual(AppProxyStore.normalizedPath("   "), "")
    }
    @MainActor func testAddByPathNeedsNoPickerAndRejectsInvalidPaths() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        let count = model.draft.applications.count
        for invalid in ["usr/bin/curl", "/nonexistent/tool", "/usr/bin", "/etc/hosts"] {
            await model.addApplication(path: invalid)
            XCTAssertEqual(model.draft.applications.count, count, invalid)
            XCTAssertNotNil(model.error, invalid)
        }
        await model.addApplication(path: "file:///usr/bin/curl")
        let entry = try XCTUnwrap(model.draft.applications.last)
        XCTAssertEqual(entry.title, "curl"); XCTAssertEqual(entry.path, "/usr/bin/curl")
        XCTAssertEqual(entry.port, 17975); XCTAssertTrue(entry.id.hasPrefix("app_"))
        XCTAssertNil(model.error)
        await model.addApplication(path: "/usr/bin/curl")
        XCTAssertEqual(model.draft.applications.count, count + 1)
        XCTAssertNotNil(model.error)
    }
    @MainActor func testPolicyNormalizesTeamsAndDirectoriesAndRejectsInvalidScopes() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        try await model.setPolicy(executablePaths: ["/usr/bin/curl"], teamIdentifiers: [" 2dc432gll2 "],
                                  directories: ["/usr/local/../bin/"], for: "chatgpt")
        let entry = try XCTUnwrap(model.draft.applications.first { $0.id == "chatgpt" })
        XCTAssertEqual(entry.teamIdentifiers, ["2DC432GLL2"])
        XCTAssertEqual(entry.directories, ["/usr/bin"], "directories are stored canonically")
        XCTAssertEqual(entry.executablePaths, ["/usr/bin/curl"])
        XCTAssertTrue(entry.capturesLaunchedCLIs)
        try await model.setPolicy(executablePaths: ["/usr/bin/curl"], teamIdentifiers: ["2DC432GLL2"], directories: ["/usr/bin"],
                                  capturesLaunchedCLIs: false, for: "chatgpt")
        XCTAssertEqual(model.draft.applications.first { $0.id == "chatgpt" }?.capturesLaunchedCLIs, false)
        try await model.setExecutablePaths(["/usr/bin/curl"], for: "chatgpt")
        XCTAssertEqual(model.draft.applications.first { $0.id == "chatgpt" }?.capturesLaunchedCLIs, false, "kept when not given")
        do { try await model.setPolicy(executablePaths: [], teamIdentifiers: ["SHORT"], directories: [], for: "chatgpt"); XCTFail() } catch {}
        do { try await model.setPolicy(executablePaths: [], teamIdentifiers: ["2DC432GLL2"], directories: [], for: "claude"); XCTFail("team owned by chatgpt") } catch {}
        XCTAssertEqual(AppProxyStore.teamIdentifier(ofCodeAt: "/usr/bin/curl"), nil, "platform code has no Team ID")
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
    @MainActor func testRefreshPreservesDraftAndReusesSignatureInventory() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway); let service = ExtensionService()
        model.configure(service); await model.refresh()
        XCTAssertEqual(service.scans, 1)
        model.selectTarget("two", for: "claude")
        await model.refresh()
        XCTAssertEqual(model.draft.routes["claude"], "two")
        XCTAssertEqual(service.scans, 1, "Node refresh must not repeat signature scans")
        XCTAssertFalse(model.hasConflict)
        try await model.apply()
        try await model.setEnabled(true)
        try await model.setEnabled(false)
        XCTAssertEqual(service.scans, 1, "Connection status reads must not scan executables")
        XCTAssertEqual(model.extensionStatus.targetCounts["claude"], 1)
        await model.refreshExecutables(force: true)
        XCTAssertEqual(service.scans, 2)
        try await model.apply()
        XCTAssertEqual(gateway.writes, 1, "Unchanged settings must not restart the runtime")
    }

    @MainActor func testExternalChangePreservesDraftButBlocksOverwriteUntilDiscard() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway)
        await model.refresh()
        model.selectTarget("two", for: "claude")
        gateway.state.settings.routes["chatgpt"] = "two"; gateway.state.revision = "external"
        await model.refresh()
        XCTAssertTrue(model.hasConflict)
        XCTAssertEqual(model.draft.routes["claude"], "two")
        do { try await model.apply(); XCTFail("Must not overwrite external edits") } catch {}
        XCTAssertEqual(gateway.writes, 0)
        model.discardChanges()
        XCTAssertFalse(model.hasConflict)
        XCTAssertEqual(model.draft.routes["chatgpt"], "two")
        XCTAssertEqual(model.draft.routes["claude"], "one")
    }

    @MainActor func testReadFailureKeepsDraftAndRequiresConflictResolutionAfterRecovery() async throws {
        let gateway = RoutingGateway(); let model = AppProxyStore(gateway: gateway)
        await model.refresh(); model.selectTarget("two", for: "claude")
        gateway.failRead = true; await model.refresh()
        XCTAssertNil(model.routing)
        XCTAssertEqual(model.draft.routes["claude"], "two")
        XCTAssertEqual(model.nodes, ["one", "two"])
        gateway.failRead = false; await model.refresh()
        XCTAssertEqual(model.draft.routes["claude"], "two")
        XCTAssertTrue(model.hasConflict)
        model.discardChanges(); XCTAssertFalse(model.dirty)
    }

    @MainActor func testSlowDiscoveryDoesNotBlockEditingAndStaleInventoryIsIgnored() async throws {
        let model = AppProxyStore(gateway: RoutingGateway()); let service = ExtensionService()
        service.suspendScan = true; model.configure(service)
        let started = expectation(description: "Scanning started")
        service.scanStarted = { started.fulfill() }
        let refresh = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.scanning)
        XCTAssertFalse(model.refreshing)
        XCTAssertFalse(model.busy)
        model.selectTarget("two", for: "claude")
        model.removeApplication("codex_cli")
        service.scanContinuation?.resume(returning: [.init(applicationID: "codex_cli", path: "/old", signingIdentifier: "old", teamIdentifier: nil, requirement: "old")])
        await refresh.value
        XCTAssertEqual(model.draft.routes["claude"], "two")
        XCTAssertTrue(model.extensionStatus.executables.isEmpty)
        XCTAssertFalse(model.hasExecutableInventory)
        service.suspendScan = false
        await model.refreshExecutables()
        XCTAssertTrue(model.hasExecutableInventory)
        XCTAssertNil(model.extensionStatus.targetCounts["codex_cli"])
    }

    @MainActor func testMutationRejectsOverlappingActionsAndDraftChanges() async throws {
        let model = AppProxyStore(gateway: RoutingGateway()); let service = ExtensionService()
        model.configure(service); await model.refresh()
        service.suspendEnable = true
        let started = expectation(description: "Enable started")
        service.enableStarted = { started.fulfill() }
        let enable = Task { try await model.setEnabled(true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.busy)
        model.selectTarget("two", for: "claude"); model.removeApplication("codex_cli")
        XCTAssertEqual(model.draft.routes["claude"], "one")
        XCTAssertEqual(model.draft.applications.count, 4)
        do { try await model.apply(); XCTFail("Concurrent write must fail") } catch {}
        service.enableContinuation?.resume()
        try await enable.value
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.extensionStatus.connected)
    }

}


extension AppProxyStoreTests {
    @MainActor func testIndependentEnablePreservesAllEntriesAndNodeSelections() async throws {
        let gateway = RoutingGateway(); let service = ExtensionService(); let model = AppProxyStore(gateway: gateway)
        model.configure(service); await model.refresh()
        let settings = model.draft
        try await model.setApplicationEnabled("claude", enabled: true)
        XCTAssertEqual(service.applicationCalls.count, 1)
        XCTAssertEqual(service.applicationCalls.first?.0, "claude")
        XCTAssertEqual(model.draft, settings); XCTAssertEqual(gateway.writes, 0)
        XCTAssertEqual(model.extensionStatus.applications["claude"]?.active, true)
        XCTAssertNil(model.extensionStatus.applications["chatgpt"])
        try await model.setApplicationEnabled("claude", enabled: false)
        XCTAssertEqual(model.draft, settings)
        XCTAssertEqual(model.extensionStatus.applications["claude"]?.requested, false)
    }
    @MainActor func testIndependentEnableRejectsUnsavedOrStaleRoutesBeforeConsent() async throws {
        let gateway = RoutingGateway(); let service = ExtensionService(); let model = AppProxyStore(gateway: gateway)
        model.configure(service); await model.refresh()
        model.selectTarget("two", for: "claude")
        do { try await model.setApplicationEnabled("claude", enabled: true); XCTFail("unsaved") } catch {}
        XCTAssertTrue(service.applicationCalls.isEmpty)
        model.discardChanges(); gateway.state.revision = "external"
        do { try await model.setApplicationEnabled("claude", enabled: true); XCTFail("stale") } catch {}
        XCTAssertTrue(service.applicationCalls.isEmpty)
    }
    func testPendingAndPausedEntriesNeverClaimInterception() {
        XCTAssertTrue(AppProxyApplicationStatus(requested: true, issue: "needsAuthorization").summary.contains("Not intercepted"))
        XCTAssertTrue(AppProxyApplicationStatus(requested: true, servicePaused: true).summary.contains("Not intercepted"))
        XCTAssertTrue(AppProxyApplicationStatus(requested: true, active: true).summary.contains("API not yet verified"))
    }
}
