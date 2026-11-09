import XCTest
import NetworkExtension
import MihomoControl
@testable import MihomoBoxApp

final class AppProxyCoordinatorTests: XCTestCase {
    private let fm = FileManager.default
    /// A fixture folder below the repository: temporary directories sit behind the /var and /tmp links.
    private func fixtureRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    /// An ad-hoc signed copy of a system tool: a signature without a Team ID.
    private func signedTool(_ url: URL, identifier: String, source: String = "/usr/bin/true") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: source, toPath: url.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, url.path]
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
    }
    /// A bundle with an Info.plist; with `executable`, also its main executable.
    @discardableResult
    private func bundle(_ url: URL, identifier: String, executable: String? = nil) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier]
        if let executable { info["CFBundleExecutable"] = executable }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let executable { try signedTool(contents.appendingPathComponent("MacOS/" + executable), identifier: identifier) }
        return url
    }
    private func policy(_ category: String, teams: [String], identifiers: [String], folders: [String] = [],
                        path: String? = nil) -> AppProxyApplicationPolicy {
        .init(category: category, teams: teams, identifiers: identifiers, folders: folders, existingFolders: folders, path: path)
    }

    func testLaunchHostsCarryOneSharedPathlessToolListAndCopiesShareOneRule() throws {
        let root = try fixtureRoot("hosts")
        let first = root.appendingPathComponent("one/host"), second = root.appendingPathComponent("two/host")
        let other = root.appendingPathComponent("other")
        try signedTool(first, identifier: "dev.linsheng.host")
        try signedTool(second, identifier: "dev.linsheng.host", source: "/usr/bin/false")
        try signedTool(other, identifier: "dev.linsheng.other-host")
        var registered: [URL] = []
        let policies = [policy("a", teams: ["AAAAAAAAA1"], identifiers: ["dev.a", "node"]),
                        policy("b", teams: ["BBBBBBBBB2"], identifiers: ["dev.b", "node"])]
        let targets = AIAppTargets(applications: policies, lookup: { _ in [] }, register: { registered.append($0) },
                                   hostExecutables: [first.path, second.path, other.path])
        // One version-independent entry per identifier; a shared identifier admits each publisher.
        XCTAssertEqual(targets.tools.map(\.matchSigningIdentifier), ["dev.a", "dev.b", "node"])
        XCTAssertTrue(targets.tools.allSatisfy { $0.matchPath == nil })
        XCTAssertEqual(targets.tools.last?.matchDesignatedRequirement,
                       AppProxyCode.requirement(identifier: "node", teams: ["AAAAAAAAA1", "BBBBBBBBB2"]))
        XCTAssertEqual(targets.rules.map(\.matchSigningIdentifier), ["dev.linsheng.host", "dev.linsheng.other-host"])
        let copies = targets.rules[0]
        XCTAssertNil(copies.matchPath, "NetworkExtension keeps one rule per identifier: copies match through LaunchServices")
        XCTAssertTrue(copies.matchDesignatedRequirement.hasPrefix("(") && copies.matchDesignatedRequirement.contains(") or ("))
        XCTAssertEqual(targets.rules[1].matchPath, other.path)
        for rule in targets.rules { XCTAssertEqual(rule.matchTools?.map(\.matchSigningIdentifier), ["dev.a", "dev.b", "node"]) }
        XCTAssertTrue(targets.applications.allSatisfy { $0.category == nil }, "a launch host is never routed")
        XCTAssertEqual(targets.routes, [.init(category: "a", teams: ["AAAAAAAAA1"], identifiers: ["dev.a", "node"]),
                                        .init(category: "b", teams: ["BBBBBBBBB2"], identifiers: ["dev.b", "node"])])
        XCTAssertEqual(targets.issues, ["a:notInstalled": 1, "b:notInstalled": 1])
        XCTAssertEqual(targets.processRoutes, AppProxyProcessRoutes())
        XCTAssertTrue(registered.isEmpty)
        XCTAssertEqual(targets.codeStamp.count, 64)
        // Without a requested application there is nothing to divert, not even launch hosts.
        let none = AIAppTargets(applications: [], lookup: { _ in [] }, register: { _ in }, hostExecutables: [first.path])
        XCTAssertTrue(none.rules.isEmpty && none.tools.isEmpty && none.applications.isEmpty)
    }
    func testFolderBundlesAreRegisteredAndUnreadableOrUnsignedCodeIsSkipped() throws {
        let root = try fixtureRoot("folders")
        let vendor = try bundle(root.appendingPathComponent("1.0/Vendor.app"), identifier: "dev.example.vendor", executable: "Vendor")
        let tool = root.appendingPathComponent("outside/tool")
        try signedTool(tool, identifier: "dev.example.tool")
        var registered: [String] = []
        let granted = policy("a", teams: ["AAAAAAAAA1"], identifiers: ["dev.example.vendor"], folders: [root.path])
        let targets = AIAppTargets(applications: [granted], lookup: { _ in [] }, register: { registered.append($0.path) },
                                   hostExecutables: [])
        XCTAssertEqual(registered, [vendor.path], "LaunchServices learns about a version an updater did not register")
        XCTAssertTrue(targets.applications.isEmpty, "ad-hoc code has no Team ID")
        XCTAssertEqual(targets.processRoutes.prefixes["a"], [root.path], "Mihomo routes the whole granted folder")
        XCTAssertEqual(targets.issues, [:])
        // A chosen CLI the provider cannot read without a grant is reported, never diverted.
        let unreadable = policy("b", teams: ["BBBBBBBBB2"], identifiers: ["dev.example.tool"], path: tool.path)
        let skipped = AIAppTargets(applications: [unreadable], lookup: { _ in [] }, register: { _ in }, hostExecutables: [])
        XCTAssertEqual(skipped.issues, ["b:unreadableCode": 1, "b:notInstalled": 1])
        XCTAssertTrue(skipped.applications.isEmpty)
        // Folders named Applications or bin hold other vendors' code: they are never routed whole.
        let shared = policy("c", teams: ["CCCCCCCCC3"], identifiers: ["x"], folders: ["/Users/me/Applications", "/opt/tools/bin"])
        XCTAssertNil(AIAppTargets(applications: [shared], lookup: { _ in [] }, register: { _ in }, hostExecutables: [])
            .processRoutes.prefixes["c"])
    }
    func testBundlesAreFoundByIdentifierWithoutLinksOrNestedHelpers() throws {
        let root = try fixtureRoot("bundles")
        let top = try bundle(root.appendingPathComponent("Vendor.app"), identifier: "dev.example.vendor", executable: "Vendor")
        let versioned = try bundle(root.appendingPathComponent("versions/1.2/Vendor.app"), identifier: "dev.example.vendor")
        let helper = try bundle(top.appendingPathComponent("Contents/Helpers/Helper.app"), identifier: "dev.example.vendor")
        try bundle(root.appendingPathComponent("a/b/c/Deep.app"), identifier: "dev.example.vendor")
        try bundle(root.appendingPathComponent("Other.app"), identifier: "dev.example.other")
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("versions"))
        XCTAssertEqual(AIAppTargets.bundles(in: root.path, identifiers: ["dev.example.vendor"]), [top.path, versioned.path])
        XCTAssertEqual(AIAppTargets.bundles(in: root.path, identifiers: ["dev.example.vendor"], limit: 1), [])
        XCTAssertTrue(AIAppTargets.isTopLevelBundle(top.path))
        XCTAssertFalse(AIAppTargets.isTopLevelBundle(helper.path))
        XCTAssertFalse(AIAppTargets.isTopLevelBundle(root.appendingPathComponent("Missing.app").path))
        XCTAssertFalse(AIAppTargets.isTopLevelBundle("/Users/me/.Trash/Vendor.app"))
        XCTAssertEqual(AIAppTargets.bundleIdentifier(top.path), "dev.example.vendor")
        XCTAssertEqual(AIAppTargets.mainExecutable(of: top.path), top.path + "/Contents/MacOS/Vendor")
        XCTAssertNil(AIAppTargets.mainExecutable(of: versioned.path))
        let signature = try XCTUnwrap(AIAppTargets.signature(top.path + "/Contents/MacOS/Vendor"))
        XCTAssertEqual(signature.identifier, "dev.example.vendor")
        XCTAssertNil(signature.team)
        XCTAssertThrowsError(try AIAppTargets.codeIdentity(of: top.path), "unsigned or ad-hoc code is unsupported")
        XCTAssertThrowsError(try AIAppTargets.codeIdentity(of: "/bin/ls"), "platform code has no Team ID")
    }
    func testCodeFoldersReadableRootsAndUpdateRoots() {
        let home = "/Users/me"
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/Applications/Tool.app", home: home), [])
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/usr/bin/curl", home: home), [])
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/opt/homebrew/Cellar/packer/1.15.3/bin/packer", home: home),
                       ["/opt/homebrew/Cellar/packer"], "the formula folder survives an upgrade")
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/usr/local/Caskroom/codex/0.9/codex", home: home), ["/usr/local/Caskroom/codex"])
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/Users/me/Applications/Tool.app", home: home), ["~/Applications/Tool.app"])
        XCTAssertEqual(AIAppTargets.codeFolders(for: "/Users/me/.local/bin/tool", home: home), ["~/.local/bin"])
        XCTAssertTrue(AIAppTargets.providerCanRead("/Applications/Tool.app", folders: []))
        XCTAssertTrue(AIAppTargets.providerCanRead("/Users/me/tools/Tool.app", folders: ["/Users/me/tools"]))
        XCTAssertFalse(AIAppTargets.providerCanRead("/Users/me/tools2/Tool.app", folders: ["/Users/me/tools"]))
        XCTAssertFalse(AIAppTargets.providerCanRead("/opt/homebrew/bin/tool", folders: []))
        XCTAssertEqual(AIAppTargets.requirement(["b", "a", "a"]), "(a) or (b)")
        XCTAssertEqual(AIAppTargets.requirement(["a", "a"]), "a")
        let claude = policy("claude", teams: ["Q6L2SF6YDW"], identifiers: ["x"], folders: ["/Users/me/.local/share/claude/versions"])
        XCTAssertEqual(AIAppTargets.updateRoots(applications: [claude], home: home),
                       ["/Applications", "/Users/me/.local/share/claude/versions", "/Users/me/Applications"])
        XCTAssertTrue(AIAppTargets.launchHostBundles.isSuperset(of: ["com.apple.Terminal", "com.microsoft.VSCode", "com.jetbrains.goland"]))
    }
    func testCodeStampChangesOnlyWhenCodeIsReplaced() throws {
        let root = try fixtureRoot("stamp")
        let tool = root.appendingPathComponent("tool")
        try Data("one".utf8).write(to: tool)
        let stamp = AIAppTargets.stamp(paths: [tool.path, tool.path], folders: [root.path])
        XCTAssertEqual(stamp, AIAppTargets.stamp(paths: [tool.path], folders: [root.path]))
        XCTAssertNotEqual(stamp, AIAppTargets.stamp(paths: [], folders: [root.path]))
        try Data("one".utf8).write(to: tool, options: .atomic)
        XCTAssertNotEqual(stamp, AIAppTargets.stamp(paths: [tool.path], folders: [root.path]), "an update replaces the file")
        let missing = AIAppTargets.stamp(paths: [root.appendingPathComponent("missing").path], folders: [])
        XCTAssertEqual(missing.count, 64)
    }
    /// Uses installed vendor code when present; NetworkExtension validates real signatures only.
    func testInstalledApplicationsGetTheirOwnRulesAndTeamFromTheirSignature() throws {
        let path = "/Applications/Claude.app"
        try XCTSkipUnless(fm.fileExists(atPath: path + "/Contents/Info.plist"), "Claude is not installed")
        let identity = try AIAppTargets.codeIdentity(of: path)
        XCTAssertEqual(identity.team, "Q6L2SF6YDW")
        XCTAssertEqual(identity.identifiers.first, "com.anthropic.claudefordesktop")
        XCTAssertTrue(identity.identifiers.contains("com.anthropic.claudefordesktop.helper"))
        let claude = policy("claude", teams: ["Q6L2SF6YDW"], identifiers: ["com.anthropic.claudefordesktop", "com.anthropic.claude-code"])
        let targets = AIAppTargets(applications: [claude], lookup: { $0 == "com.anthropic.claudefordesktop" ? [URL(fileURLWithPath: path)] : [] },
                                   register: { _ in }, hostExecutables: [])
        let rule = try XCTUnwrap(targets.rules.first { $0.matchSigningIdentifier == "com.anthropic.claudefordesktop" })
        XCTAssertEqual(rule.matchPath, path + "/Contents/MacOS/Claude")
        XCTAssertTrue(rule.matchDesignatedRequirement.contains("Q6L2SF6YDW"))
        XCTAssertEqual(rule.matchTools?.map(\.matchSigningIdentifier), ["com.anthropic.claude-code", "com.anthropic.claudefordesktop"])
        XCTAssertEqual(rule.matchTools?.map(\.matchPath), [nil, path + "/Contents/MacOS/Claude"],
                       "code LaunchServices cannot resolve stays path-less only when it is not found")
        XCTAssertEqual(targets.applications.first?.category, "claude")
        XCTAssertEqual(targets.processRoutes.prefixes["claude"], [path])
        XCTAssertEqual(targets.issues, [:])
        // Another publisher's identifier never yields a rule for this code.
        let forged = policy("x", teams: ["AAAAAAAAA1"], identifiers: ["com.anthropic.claudefordesktop"])
        let lookup: (String) -> [URL] = { $0 == "com.anthropic.claudefordesktop" ? [URL(fileURLWithPath: path)] : [] }
        XCTAssertTrue(AIAppTargets(applications: [forged], lookup: lookup, register: { _ in },
                                   hostExecutables: []).rules.isEmpty)
    }
    func testExecutablesOfListedIdentifiersAreMatchedByPathAndOthersStayPathless() throws {
        let root = try fixtureRoot("located")
        let app = try bundle(root.appendingPathComponent("Vendor.app"), identifier: "dev.example.vendor", executable: "Vendor")
        try bundle(app.appendingPathComponent("Contents/Frameworks/V.framework/Versions/A/Helpers/Helper.app"),
                   identifier: "dev.example.helper", executable: "Helper")
        try signedTool(app.appendingPathComponent("Contents/Resources/tool"), identifier: "dev.example.helper")
        try signedTool(root.appendingPathComponent("cli/1.0/bin/cli"), identifier: "cli")
        try signedTool(root.appendingPathComponent("cli/1.1/bin/cli"), identifier: "cli", source: "/usr/bin/false")
        try signedTool(root.appendingPathComponent("cli/1.1/bin/other"), identifier: "other")
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("cli/script"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("cli/script").path)
        try fm.createSymbolicLink(at: root.appendingPathComponent("cli/link"), withDestinationURL: root.appendingPathComponent("cli/1.0/bin/cli"))
        XCTAssertEqual(AIAppTargets.executables(in: app.path, bundle: true).map { $0.replacingOccurrences(of: app.path, with: "") },
                       ["/Contents/Frameworks/V.framework/Versions/A/Helpers/Helper.app/Contents/MacOS/Helper", "/Contents/MacOS/Vendor"],
                       "an application's executables sit in MacOS and Helpers folders")
        XCTAssertEqual(AIAppTargets.executables(in: root.appendingPathComponent("cli").path, bundle: false).count, 3,
                       "a folder's Mach-O executables, without scripts or links")
        // Ad-hoc fixtures have no Team ID: give them one, as a vendor's signature would.
        let identify: (String) -> AIAppTargets.Identity? = { path in
            AIAppTargets.identity(path).map { .init(identifier: $0.identifier, team: path.contains("/1.1/") ? "BBBBBBBBB2" : "AAAAAAAAA1") }
        }
        let a = policy("a", teams: ["AAAAAAAAA1"], identifiers: ["dev.example.vendor", "dev.example.helper", "cli", "absent"],
                       folders: [root.path], path: app.path)
        let targets = AIAppTargets(applications: [a], lookup: { _ in [] }, register: { _ in }, hostExecutables: [], identify: identify)
        // A granted folder's code counts wherever it sits; another publisher's copy (1.1) and
        // unlisted identifiers are left out. Ad-hoc Vendor.app is no application, so its deep
        // helper is beyond the folder scan's depth.
        XCTAssertEqual(targets.located.map { "\($0.identifier) \($0.path.replacingOccurrences(of: root.path, with: ""))" },
                       ["dev.example.vendor /Vendor.app/Contents/MacOS/Vendor", "dev.example.helper /Vendor.app/Contents/Resources/tool",
                        "cli /cli/1.0/bin/cli"])
        XCTAssertEqual(targets.tools.map { "\($0.matchSigningIdentifier) \($0.matchPath != nil)" },
                       ["absent false", "cli true", "dev.example.helper true", "dev.example.vendor true"])
        XCTAssertTrue(targets.tools.allSatisfy { $0.matchDesignatedRequirement.contains("AAAAAAAAA1") })
        // A path tool changes the code stamp when it is replaced.
        let before = targets.codeStamp
        try fm.removeItem(at: root.appendingPathComponent("cli/1.0/bin/cli"))
        try signedTool(root.appendingPathComponent("cli/1.0/bin/cli"), identifier: "cli")
        XCTAssertNotEqual(AIAppTargets(applications: [a], lookup: { _ in [] }, register: { _ in }, hostExecutables: [],
                                       identify: identify).codeStamp, before)
        // Code the provider cannot read is never matched: only granted folders count.
        let ungranted = AppProxyApplicationPolicy(category: "a", teams: ["AAAAAAAAA1"], identifiers: ["cli"],
                                                  folders: [root.path], existingFolders: [root.path], path: nil).granted([])
        XCTAssertTrue(AIAppTargets(applications: [ungranted], lookup: { _ in [] }, register: { _ in }, hostExecutables: [],
                                   identify: identify).located.isEmpty)
        XCTAssertEqual(ungranted.folders, [root.path], "Mihomo's process routes still name every configured folder")
    }
    func testCopiesOfAnIdentifierWithPathToolsNameThePreferredCopy() throws {
        // NetworkExtension caches UUIDs per identifier and a lookup by path replaces the cache,
        // so an identifier with path tools must never also have a path-less rule.
        let root = try fixtureRoot("copies")
        let first = root.appendingPathComponent("one/host"), second = root.appendingPathComponent("two/host")
        let third = root.appendingPathComponent("three/host"), fourth = root.appendingPathComponent("four/host")
        try signedTool(first, identifier: "dev.linsheng.host")
        try signedTool(second, identifier: "dev.linsheng.host", source: "/usr/bin/false")
        try signedTool(third, identifier: "dev.linsheng.copy")
        try signedTool(fourth, identifier: "dev.linsheng.copy", source: "/usr/bin/false")
        let identify: (String) -> AIAppTargets.Identity? = { path in
            AIAppTargets.identity(path).map { .init(identifier: $0.identifier, team: "AAAAAAAAA1") }
        }
        let a = policy("a", teams: ["AAAAAAAAA1"], identifiers: ["dev.linsheng.host"], folders: [root.appendingPathComponent("one").path,
                                                                                                 root.appendingPathComponent("two").path])
        let targets = AIAppTargets(applications: [a], lookup: { _ in [] }, register: { _ in },
                                   hostExecutables: [first.path, second.path, third.path, fourth.path], identify: identify)
        XCTAssertEqual(targets.tools.map(\.matchPath), [first.path, second.path])
        XCTAssertEqual(targets.rules.map(\.matchSigningIdentifier), ["dev.linsheng.copy", "dev.linsheng.host"])
        XCTAssertNil(targets.rules[0].matchPath, "copies without path tools still match through LaunchServices")
        XCTAssertEqual(targets.rules[1].matchPath, second.path, "the last path when no bundle version decides")
    }
    func testPreferredCopyIsTheHighestBundleVersion() throws {
        let root = try fixtureRoot("versions")
        func copy(_ name: String, _ version: String) throws -> AIAppTargets.Application {
            let url = try bundle(root.appendingPathComponent(name + "/claude.app"), identifier: "dev.example.cli")
            let info = url.appendingPathComponent("Contents/Info.plist")
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.example.cli", "CFBundleVersion": version],
                                               format: .xml, options: 0).write(to: info)
            return .init(identifier: "dev.example.cli", team: "AAAAAAAAA1", requirement: "", path: url.path + "/Contents/MacOS/claude",
                         bundle: url.path, category: "a")
        }
        let older = try copy("z-old", "2.1.9"), newer = try copy("a-new", "2.1.10")
        XCTAssertEqual(AIAppTargets.preferredCopy([older, newer]), newer.path)
        XCTAssertEqual(AIAppTargets.preferredCopy([newer, older]), newer.path)
    }
    /// Uses installed vendor code when present: helpers and CLIs that LaunchServices cannot
    /// resolve get path tools, and the whole configuration stays far below NetworkExtension's limit.
    @MainActor func testInstalledDefaultsMatchHelpersByPathWithinTheBudget() throws {
        try XCTSkipUnless(fm.fileExists(atPath: "/Applications/ChatGPT.app/Contents/Info.plist"), "ChatGPT is not installed")
        let home = fm.homeDirectoryForCurrentUser.path
        let defaults = AppProxyEntry.defaults.filter { ["chatgpt", "claude"].contains($0.id) }
        let policies = try defaults.map { try AppProxyApplicationPolicy.resolve($0, home: home) }
        let targets = AIAppTargets(applications: policies, register: { _ in })
        let identifiers = Set(targets.located.map(\.identifier))
        XCTAssertTrue(identifiers.isSuperset(of: ["com.openai.codex", "com.openai.codex.helper", "com.openai.codex.helper.renderer", "codex"]))
        let pathTools = Set(targets.tools.filter { $0.matchPath != nil }.map(\.matchSigningIdentifier))
        XCTAssertTrue(targets.rules.allSatisfy { $0.matchPath != nil || !pathTools.contains($0.matchSigningIdentifier) },
                      "an identifier is matched by path everywhere or nowhere")
        XCTAssertFalse(targets.tools.contains { $0.matchPath == nil && pathTools.contains($0.matchSigningIdentifier) })
        let bytes = AppProxyCoordinator.configurationSize([:], rules: targets.rules)
        print("installed defaults: rules=\(targets.rules.count) tools=\(targets.tools.count) located=\(targets.located.count) bytes=\(bytes)")
        XCTAssertLessThan(bytes, AppProxyCoordinator.configurationBudget / 2)
    }
    @MainActor func testConfigurationSizeCountsSharedToolsOncePerRule() {
        let tool = NEAppRule(signingIdentifier: "dev.linsheng.tool", designatedRequirement: "identifier \"dev.linsheng.tool\"")
        tool.matchPath = "/opt/tool"
        func rules(_ make: () -> NEAppRule) -> [NEAppRule] {
            (0..<4).map { index in
                let rule = NEAppRule(signingIdentifier: "dev.linsheng.app\(index)", designatedRequirement: "identifier \"dev.linsheng.app\(index)\"")
                rule.matchTools = [make()]
                return rule
            }
        }
        let shared = rules { tool }
        let separate = rules { tool.copy() as! NEAppRule }
        // NetworkExtension measures the configuration after XPC, which does not keep sharing.
        XCTAssertEqual(AppProxyCoordinator.configurationSize([:], rules: shared),
                       AppProxyCoordinator.configurationSize([:], rules: separate))
    }
    @MainActor func testNewManagerUsesAppProxyProviderAndPerApplicationRouting() {
        let manager: NETunnelProviderManager = AppProxyCoordinator.makeManager()
        XCTAssertTrue(manager is NEAppProxyProviderManager)
        XCTAssertEqual(manager.routingMethod, .sourceApplication)
        XCTAssertFalse(manager.isEnabled)
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
    @MainActor func testTransientEmptyReplyRecoversOnlyForIdempotentRequests() async throws {
        for action in [AppProxyRuntimeMessage.Action.status, .flowOwners, .renew] {
            var calls = 0, pauses = 0
            let value = try await AppProxyCoordinator.withProviderReplyRetry(action: action, pause: { pauses += 1 }) {
                calls += 1
                if calls == 1 { throw AppProxyCoordinator.ProviderTransportFailure.emptyReply }
                return "verified"
            }
            XCTAssertEqual(value, "verified"); XCTAssertEqual(calls, 2); XCTAssertEqual(pauses, 1)
        }
        for action in [AppProxyRuntimeMessage.Action.prepare, .commit, .abort] {
            var calls = 0, pauses = 0
            do {
                let _: Int = try await AppProxyCoordinator.withProviderReplyRetry(action: action, pause: { pauses += 1 }) {
                    calls += 1; throw AppProxyCoordinator.ProviderTransportFailure.emptyReply
                }
                XCTFail("An unobserved publication must not be replayed")
            } catch { XCTAssertEqual(error as? AppProxyCoordinator.ProviderTransportFailure, .emptyReply) }
            XCTAssertEqual(calls, 1); XCTAssertEqual(pauses, 0)
        }
    }
    @MainActor func testProviderReplyRetryIsBoundedAndNeverRetriesValidationOrTimeoutFailures() async {
        let failures: [Error] = [AppProxyCoordinator.ProviderTransportFailure.emptyReply,
            AppProxyCoordinator.ProviderTransportFailure.oversizedReply,
            AppProxyIdentityFailure.signature, AppProxyIdentityFailure.providerTimeout]
        for failure in failures {
            var calls = 0, pauses = 0
            do {
                let _: Int = try await AppProxyCoordinator.withProviderReplyRetry(action: .status, pause: { pauses += 1 }) {
                    calls += 1; throw failure
                }
                XCTFail("Failure must propagate")
            } catch {}
            let empty = (failure as? AppProxyCoordinator.ProviderTransportFailure) == .emptyReply
            XCTAssertEqual(calls, empty ? 3 : 1); XCTAssertEqual(pauses, empty ? 2 : 0)
        }
    }
}

extension AppProxyCoordinatorTests {
    func testTimedOutPreferenceRequestStaysSingleFlightUntilRealCallback() throws {
        let gate = AppProxyPreferenceGate(), first = try XCTUnwrap(AppProxyPreferenceGate().begin())
        let pending = try XCTUnwrap(gate.begin())
        // Caller timeout must not release the uncancellable OS request.
        for _ in 0..<100 { XCTAssertNil(gate.begin()) }
        gate.finish(first)
        XCTAssertNil(gate.begin(), "An unrelated late completion cannot release the gate")
        gate.finish(pending)
        let next = try XCTUnwrap(gate.begin())
        gate.finish(pending)
        XCTAssertNil(gate.begin(), "A duplicate old completion cannot release a new request")
        gate.finish(next)
        XCTAssertNotNil(gate.begin())
    }
    @MainActor func testRenewalProgressesWhilePreferencesRemainBlockedAndCoalesces() async throws {
        let gate = AppProxyPreferenceGate(), ticket = try XCTUnwrap(gate.begin())
        let renewer = AppProxyLeaseRenewer(), generation = UUID()
        var calls = 0
        let operation: @MainActor () async throws -> Void = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
        }
        async let first: Void = renewer.run(generation: generation, operation: operation)
        async let second: Void = renewer.run(generation: generation, operation: operation)
        try await first; try await second
        XCTAssertEqual(calls, 1)
        XCTAssertNil(gate.begin(), "Renewal must not consume or unlock the preference operation")
        gate.finish(ticket)
    }
}
