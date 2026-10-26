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
    func testDirectoryScopeAndOneOSRulePerSigningIdentifier() throws {
        let fm = FileManager.default
        // Temporary directories sit below the /var symlink, which no-follow checks reject by design.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/scope-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for name in ["a", "b"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            let copy = root.appendingPathComponent("\(name)/fixture")
            try fm.copyItem(atPath: "/usr/bin/true", toPath: copy.path)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", "dev.linsheng.mihomo.scope-fixture", copy.path]
            try sign.run(); sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0)
        }
        // An unmodified copy of Apple's code would make its OS rule capture the system original.
        try fm.createDirectory(at: root.appendingPathComponent("apple"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/curl", toPath: root.appendingPathComponent("apple/curl").path)
        var entry = AppProxyEntry.defaults[1]
        entry.directories = [root.path]
        let discovered = try AIAppTargets(requireAll: false, applications: [entry])
        let copies = discovered.targets.filter { $0.path.hasPrefix(root.path + "/") }
        XCTAssertEqual(copies.map(\.path).sorted(), ["a", "b"].map { root.appendingPathComponent("\($0)/fixture").path })
        XCTAssertFalse(discovered.rules.contains { $0.matchSigningIdentifier == "com.apple.curl" })
        guard copies.count == 2 else { return }
        XCTAssertEqual(Set(copies.map(\.category)), [entry.id])
        XCTAssertEqual(Set(discovered.rules.map(\.matchSigningIdentifier)).count, discovered.rules.count,
                       "NE keeps one app rule per signing identifier")
        let shared = try XCTUnwrap(discovered.rules.first { $0.matchSigningIdentifier == copies[0].id })
        XCTAssertNil(shared.matchPath, "a shared identifier leaves the exact path to the provider")
        XCTAssertEqual(Set(shared.matchTools?.compactMap(\.matchPath) ?? []).isSuperset(of: copies.map(\.path)), true)

        // Two applications owning copies of one identifier still publish a single OS rule.
        var first = AppProxyEntry.defaults[1]; first.directories = [root.appendingPathComponent("a").path]
        var second = AppProxyEntry.defaults[3]; second.directories = [root.appendingPathComponent("b").path]
        let one = try AIAppTargets(requireAll: false, applications: [first])
        let two = try AIAppTargets(requireAll: false, applications: [second])
        XCTAssertNotNil(one.rules.first { $0.matchSigningIdentifier == copies[0].id }?.matchPath)
        let combined = try AIAppTargets(combining: [one, two])
        XCTAssertEqual(Set(combined.rules.map(\.matchSigningIdentifier)).count, combined.rules.count)
        let merged = try XCTUnwrap(combined.rules.first { $0.matchSigningIdentifier == copies[0].id })
        XCTAssertNil(merged.matchPath)
        XCTAssertEqual(AIAppTargets.requirement(["b", "a", "a"]), "(a) or (b)")
        XCTAssertEqual(AIAppTargets.requirement(["a", "a"]), "a")
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
    @MainActor func testRuleDifferenceCountsFieldChangesWithoutContent() {
        func rule(_ id: String, _ path: String, _ requirement: String) -> NEAppRule {
            let value = NEAppRule(signingIdentifier: id, designatedRequirement: requirement)
            value.matchPath = path
            return value
        }
        let app = rule("a", "/Users/me/App", "identifier a and anchor apple generic")
        app.matchTools = [rule("t", "/x/tool", "identifier t")]
        let other = rule("b", "/b", "identifier b")
        // Read back: the requirement is only re-serialized, a tool path changes case, a rule is dropped.
        let appBack = rule("a", "/Users/me/App", "identifier \"a\" and anchor apple generic")
        appBack.matchTools = [rule("t", "/X/tool", "identifier t")]
        let d = AppProxyCoordinator.rulesDifference(actual: [appBack], expected: [app, other])
        XCTAssertEqual([d.expectedRules, d.actualRules, d.missingRules, d.extraRules], [2, 1, 1, 0])
        XCTAssertEqual([d.requirementText, d.requirementCanonical, d.requirementCleared], [1, 1, 0])
        XCTAssertEqual([d.expectedTools, d.actualTools, d.missingTools, d.extraTools], [1, 1, 1, 1])
        XCTAssertEqual([d.movedPaths, d.pathCaseOnly, d.pathResolvesEqual, d.pathCleared], [1, 1, 0, 0])
        // Counts only: every token is name=N or name=N/N, so no path or requirement can leak.
        XCTAssertNotNil(d.summary.range(of: #"^[A-Za-z]+=[0-9]+(/[0-9]+)?( [A-Za-z]+=[0-9]+(/[0-9]+)?)*$"#, options: .regularExpression))
        XCTAssertEqual(AppProxyCoordinator.rulesDifference(actual: [app, other], expected: [other, app]),
                       .init(expectedRules: 2, actualRules: 2, expectedTools: 1, actualTools: 1))
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

extension AppProxyCoordinatorTests {
    func testLaunchHostRulesCarryPathsAndOnlyVerifiedToolsWithoutBecomingRecords() throws {
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Tools", path: "/bin/ls", port: 17975, executablePaths: ["/usr/bin/curl"])
        let discovered = try AIAppTargets(requireAll: false, applications: [entry], applicationDirectories: [])
        XCTAssertEqual(Set(discovered.targets.map(\.path)), ["/bin/ls", "/usr/bin/curl"], "hosts are not authorized records")
        let hosts = AIAppTargets.launchHosts(applicationDirectories: [])
        XCTAssertTrue(hosts.contains { $0.id == "com.apple.Terminal" })
        if FileManager.default.fileExists(atPath: "/usr/libexec/sshd-session") {
            XCTAssertEqual(hosts.first { $0.id == "com.apple.sshd-session" }?.path, "/usr/libexec/sshd-session")
        }
        for host in hosts {
            // A path-less rule would never match sshd-session, which LaunchServices does not know.
            let rule = try XCTUnwrap(discovered.rules.first { $0.matchSigningIdentifier == host.id })
            XCTAssertEqual(rule.matchPath, host.path)
            XCTAssertEqual(rule.matchDesignatedRequirement, host.requirement)
            XCTAssertEqual(Set(rule.matchTools?.compactMap(\.matchPath) ?? []), ["/bin/ls", "/usr/bin/curl"])
        }
    }
    func testLaunchHostsAreChosenByBundleIdentifier() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/host-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for (name, id) in [("IDE", "com.jetbrains.mihomo-fixture"), ("Other", "dev.linsheng.mihomo.other-fixture")] {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/\(name)").path)
            try (["CFBundleIdentifier": id, "CFBundleExecutable": name, "CFBundlePackageType": "APPL"] as NSDictionary)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", root.appendingPathComponent("\(name).app").path]
            try sign.run(); sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0)
        }
        let hosts = AIAppTargets.launchHosts(applicationDirectories: [root])
        XCTAssertEqual(hosts.first { $0.id == "com.jetbrains.mihomo-fixture" }?.path,
                       root.appendingPathComponent("IDE.app/Contents/MacOS/IDE").path)
        XCTAssertFalse(hosts.contains { $0.id == "dev.linsheng.mihomo.other-fixture" })
    }
    func testApplicationsRouteOtherApplicationsLaunchedCLIsUnlessDisabled() throws {
        let launcher = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Launcher", path: "/bin/ls", port: 17975)
        let cli = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000002", title: "CLI", path: "/usr/bin/curl", port: 17976)
        func launcherTools(_ launcher: AppProxyEntry) throws -> Set<String> {
            let combined = try AIAppTargets(combining: [
                AIAppTargets(requireAll: false, applications: [launcher], applicationDirectories: []),
                AIAppTargets(requireAll: false, applications: [cli], applicationDirectories: [])])
            let rule = try XCTUnwrap(combined.rules.first { $0.matchPath == "/bin/ls" })
            return Set(rule.matchTools?.compactMap(\.matchPath) ?? [])
        }
        XCTAssertEqual(try launcherTools(launcher), ["/bin/ls", "/usr/bin/curl"])
        var direct = launcher; direct.capturesLaunchedCLIs = false
        XCTAssertEqual(try launcherTools(direct), ["/bin/ls"])
    }
}
