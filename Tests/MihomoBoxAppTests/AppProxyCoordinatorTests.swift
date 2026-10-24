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

extension AppProxyCoordinatorTests {
    func testClaudeCodeRootCoverageIsSeparateFromGenericRemoteServer() {
        let roots = Dictionary(uniqueKeysWithValues: AIAppTargets.claudeCodeRoots)
        XCTAssertEqual(roots["Library/Application Support/Claude/claude-code"], "claude")
        XCTAssertEqual(roots[".claude/remote/ccd-cli"], "claude")
        XCTAssertEqual(roots[".local/share/claude/versions"], "claude_cli")
        XCTAssertNil(roots[".claude/remote/srv"])
    }
    func testOSRulesDoNotInheritUnregisteredChildren() throws {
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Tools", path: "/bin/ls", port: 17975, executablePaths: ["/usr/bin/curl"])
        let discovery = try AIAppTargets(requireAll: false, applications: [entry])
        for rule in discovery.rules {
            let tools = try XCTUnwrap(rule.matchTools)
            XCTAssertFalse(tools.isEmpty)
            XCTAssertTrue(tools.allSatisfy { $0.matchPath != nil })
        }
        let paths = Set(discovery.targets.filter { $0.category == entry.id }.map(\.path))
        XCTAssertEqual(paths, ["/bin/ls", "/usr/bin/curl"])
    }
    func testRootSymlinkIsReportedAndNotTraversed() throws {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let parent = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("claude-code"), withDestinationURL: URL(fileURLWithPath: "/usr/bin"))
        let discovered = try AIAppTargets(requireAll: false, applications: [AppProxyEntry.defaults.first { $0.id == "claude" }!], homeDirectory: home, applicationDirectories: [])
        XCTAssertFalse(discovered.targets.contains { $0.category == "claude" })
        XCTAssertTrue(discovered.issues.contains { $0.failure == .escapedPath })
    }
}

extension AppProxyCoordinatorTests {
    @MainActor func testRuleDigestIgnoresOrderButDetectsScopeExpansion() {
        let a = NEAppRule(signingIdentifier: "a", designatedRequirement: "identifier a")
        a.matchPath = "/a"
        let b = NEAppRule(signingIdentifier: "b", designatedRequirement: "identifier b")
        b.matchPath = "/b"
        a.matchTools = [b]
        let expected = AppProxyCoordinator.rulesDigest([a,b])
        XCTAssertEqual(expected, AppProxyCoordinator.rulesDigest([b,a]))
        a.matchTools = []
        let onlyApp = AppProxyCoordinator.rulesDigest([a,b])
        a.matchTools = nil
        XCTAssertNotEqual(onlyApp, AppProxyCoordinator.rulesDigest([a,b]))
        XCTAssertNotEqual(expected, AppProxyCoordinator.rulesDigest([a,b]))
    }
}


extension AppProxyCoordinatorTests {
    @MainActor func testReadinessDistinguishesFailuresWithoutRelaxingChecks() {
        let generation = UUID()
        let healthy = AppProxyRuntimeStatus(generation: generation, ready: true, verifiedTargets: 2)
        func issue(_ live: AppProxyRuntimeStatus?, rules: Bool = true) -> String? {
            AppProxyCoordinator.readinessIssue(current: true, expectedGeneration: generation, rulesMatch: rules, live: live)
        }
        XCTAssertNil(issue(healthy))
        XCTAssertEqual(issue(nil), "providerUnavailable")
        XCTAssertEqual(issue(healthy, rules: false), "rulesReadbackMismatch")
        var state = healthy; state.generation = UUID()
        XCTAssertEqual(issue(state), "providerGenerationMismatch")
        state = healthy; state.ready = false
        XCTAssertEqual(issue(state), "providerNotReady")
        state.failure = .permission
        XCTAssertEqual(issue(state), "permission")
        state.failure = .staleAuthorization
        XCTAssertEqual(issue(state), "staleAuthorization")
        XCTAssertEqual(AppProxyCoordinator.readinessIssue(current: false, expectedGeneration: nil,
                        rulesMatch: true, live: healthy), "configurationObsolete")
    }
    @MainActor func testProviderReplyCannotHideFailureBehindReadyFlag() {
        let generation = UUID()
        let bad = AppProxyRuntimeStatus(generation: generation, ready: true, verifiedTargets: 2, failure: .signature)
        XCTAssertThrowsError(try AppProxyCoordinator.requireProvider(bad, generation: generation)) { error in
            XCTAssertEqual(error as? AppProxyIdentityFailure, .signature)
        }
    }
}
