import XCTest
import Foundation
import Darwin
import Security
@testable import MihomoControl

final class AppProxyIdentityTests: XCTestCase {
    func testLegacyTeamMigrationPreservesRoutesAndRejectsCustomization() throws {
        var old = AppProxySettings(routes: ["chatgpt":"A", "codex_cli":"A", "claude":"B", "claude_cli":"B"], applications: AppProxyEntry.legacyDefaults)
        let migrated = try XCTUnwrap(old.teamPresetMigration)
        // Only OpenAI and Anthropic replace legacy presets; a new default such as
        // JetBrains has no predecessor route and is added explicitly.
        XCTAssertEqual(migrated.applications, AppProxyEntry.teamPresetReplacements)
        XCTAssertEqual(migrated.applications.map(\.id), ["chatgpt", "claude"])
        XCTAssertEqual(migrated.routes, ["chatgpt":"A", "claude":"B"])
        XCTAssertNoThrow(try migrated.validate())
        XCTAssertEqual(migrated.bypass, old.bypass)
        XCTAssertNil(migrated.teamPresetMigration)
        old.routes["codex_cli"] = "Other"
        XCTAssertNil(old.teamPresetMigration)
        old.routes["codex_cli"] = "A"
        old.applications[1].signingIdentifiers = ["curl"]
        XCTAssertNil(old.teamPresetMigration)
        old.applications = AppProxyEntry.legacyDefaults
        let custom = AppProxyEntry(id: "app_00000000-0000-4000-8000-000000000001", title: "Custom", path: "/Applications/Custom.app", port: 17975)
        old.applications.append(custom); old.routes[custom.id] = "C"
        XCTAssertEqual(old.teamPresetMigration?.applications.last, custom)
        XCTAssertEqual(old.teamPresetMigration?.routes[custom.id], "C")
    }
    func testTeamDefaultsAndLegacyRouteMigration() throws {
        let defaults = AppProxySettings()
        XCTAssertEqual(defaults.applications.map(\.id), ["chatgpt", "claude", "jetbrains"])
        XCTAssertEqual(defaults.applications.flatMap(\.teamIdentifiers), ["2DC432GLL2", "Q6L2SF6YDW", "2ZEFAR8TH3"])
        XCTAssertEqual(defaults.applications.last?.port, 17970)
        XCTAssertEqual(AppProxyApplication.jetbrains.port, 17970)
        XCTAssertNoThrow(try defaults.validate())
        XCTAssertNoThrow(try AppProxySettings(routes: ["chatgpt": "A", "claude": "B", "jetbrains": "C"]).validate())
        // Built-in ports never fall inside the custom range.
        XCTAssertTrue(AppProxyApplication.allCases.allSatisfy { !(17975...18002).contains($0.port) })
        XCTAssertEqual(Set(AppProxyApplication.allCases.map(\.port)).count, AppProxyApplication.allCases.count)
        XCTAssertEqual(AppProxyEntry.legacyDefaults.map(\.id), ["chatgpt", "codex_cli", "claude", "claude_cli"])
        let oldRoutes = Dictionary(uniqueKeysWithValues: AppProxyApplication.legacyPresets.map { ($0.rawValue, "Proxy") })
        let data = try JSONSerialization.data(withJSONObject: ["routes": oldRoutes])
        let legacy = try JSONDecoder().decode(AppProxySettings.self, from: data)
        XCTAssertEqual(legacy.applications, AppProxyEntry.legacyDefaults)
        XCTAssertEqual(legacy.routes, oldRoutes)
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(legacy)), legacy)
        XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(defaults)), defaults)
    }
    func testCodeSyntaxAndRequirementsCompile() {
        XCTAssertTrue(AppProxyCode.isTeamIdentifier("2DC432GLL2"))
        for bad in ["2dc432gll2", "2DC432GLL", "2DC432GLL2X", "2DC432GLL!"] { XCTAssertFalse(AppProxyCode.isTeamIdentifier(bad), bad) }
        XCTAssertTrue(AppProxyCode.isSigningIdentifier("com.openai.codex"))
        for bad in ["", "a b", "a\"b", "a\\b", "a\u{7f}", String(repeating: "a", count: 256)] {
            XCTAssertFalse(AppProxyCode.isSigningIdentifier(bad), bad)
        }
        XCTAssertTrue(AppProxyCode.isFolder("/Users/me/Library/Application Support/Claude/claude-code"))
        for bad in ["/", "relative", "/tmp/../etc", "/tmp//x", "/tmp/./x", "/tmp/x/", "/tmp/x\n"] {
            XCTAssertFalse(AppProxyCode.isFolder(bad), bad)
        }
        XCTAssertEqual(AppProxyCode.teamRequirement(["2DC432GLL2"]),
                       "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"")
        let tool = AppProxyCode.requirement(identifier: "codex", teams: ["2DC432GLL2", "Q6L2SF6YDW"])
        XCTAssertEqual(tool, "anchor apple generic and identifier \"codex\" and (certificate leaf[subject.OU] = \"2DC432GLL2\""
                       + " or certificate leaf[subject.OU] = \"Q6L2SF6YDW\")")
        for text in [tool, AppProxyCode.teamRequirement(["2DC432GLL2", "Q6L2SF6YDW"])] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
        }
    }
    func testFoldersOpenWithoutLinksAndGrantsMustBeReadOnly() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func failure(_ path: String, readOnly: Bool = false) -> AppProxyIdentityFailure? {
            do {
                try readOnly ? AppProxyCode.requireReadOnlyFolder(path) : AppProxyCode.requireReadableFolder(path)
                return nil
            } catch { return error as? AppProxyIdentityFailure }
        }
        XCTAssertNil(failure(root.path))
        XCTAssertEqual(failure(root.path, readOnly: true), .permission, "a writable folder is never granted")
        if getuid() != 0 { XCTAssertNil(failure("/usr/bin", readOnly: true)) }
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin"))
        XCTAssertEqual(failure(link.path), .escapedPath)
        XCTAssertEqual(failure("/tmp"), .escapedPath, "no component may be a link")
        XCTAssertEqual(failure(root.appendingPathComponent("missing").path), .missingFile)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(failure(file.path), .escapedPath)
    }
    func testPolicyRoutesAreUniqueAndRoundTrip() throws {
        let stamp = String(repeating: "a", count: 64)
        let openai = AppProxyPolicy.Route(category: "chatgpt", teams: ["2DC432GLL2"], identifiers: ["com.openai.codex", "codex"])
        let claude = AppProxyPolicy.Route(category: "claude", teams: ["Q6L2SF6YDW"], identifiers: ["com.anthropic.claude-code"])
        let policy = AppProxyPolicy(ownerUID: 501, routes: [openai, claude], folders: ["/opt/homebrew/Caskroom/codex"],
                                    grants: [Data([1])], codeStamp: stamp)
        XCTAssertEqual(policy.version, 5)
        XCTAssertEqual(try AppProxyPolicy.decode(policy.encoded()), policy)
        XCTAssertEqual(openai.requirement, AppProxyCode.teamRequirement(["2DC432GLL2"]))
        // A later generation with freshly minted grant bytes carries the same authority; an update does not.
        let renewed = AppProxyPolicy(ownerUID: 501, routes: [openai, claude], folders: policy.folders, grants: [Data([2])], codeStamp: stamp)
        XCTAssertNotEqual(renewed, policy)
        XCTAssertTrue(renewed.sameAuthority(as: policy))
        let updated = AppProxyPolicy(ownerUID: 501, routes: [openai, claude], folders: policy.folders, grants: [Data([1])],
                                     codeStamp: String(repeating: "b", count: 64))
        XCTAssertFalse(updated.sameAuthority(as: policy))
        // One publisher may route different identifiers to different applications, never one pair twice.
        let sameTeam = AppProxyPolicy.Route(category: "app_x", teams: ["2DC432GLL2"], identifiers: ["other"])
        XCTAssertNoThrow(try AppProxyPolicy(ownerUID: 501, routes: [openai, sameTeam], folders: [], grants: [], codeStamp: stamp).validate())
        let overlap = AppProxyPolicy.Route(category: "app_x", teams: ["2DC432GLL2"], identifiers: ["codex"])
        func route(_ teams: [String], _ identifiers: [String]) -> AppProxyPolicy.Route {
            .init(category: "app_y", teams: teams, identifiers: identifiers)
        }
        let invalid: [AppProxyPolicy] = [
            .init(ownerUID: 0, routes: [openai], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai, overlap], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai, openai], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [route(["lower12345"], ["a"])], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [route([], ["a"])], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [route(["2DC432GLL2"], [])], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [route(["2DC432GLL2"], ["a", "a"])], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [route(["2DC432GLL2"], ["a b"])], folders: [], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai], folders: ["/opt/x"], grants: [], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai], folders: ["/"], grants: [Data([1])], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai], folders: ["/opt/x", "/opt/x"], grants: [Data([1]), Data([1])], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai], folders: ["/opt/x"], grants: [Data()], codeStamp: stamp),
            .init(ownerUID: 501, routes: [openai], folders: [], grants: [], codeStamp: "short"),
            .init(ownerUID: 501, routes: [openai], folders: [], grants: [], codeStamp: String(repeating: "A", count: 64)),
        ]
        for (index, value) in invalid.enumerated() { XCTAssertThrowsError(try value.encoded(), "\(index)") }
        // Older generations listed executables; they never decode as this policy.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: policy.encoded()) as? [String: Any])
        json["version"] = 4
        XCTAssertThrowsError(try AppProxyPolicy.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try AppProxyPolicy.decode(Data(count: AppProxyPolicy.maximumBytes + 1)))
        // A malformed grant is never a path fallback.
        XCTAssertThrowsError(try AppProxyFolderAccess(policy)) {
            XCTAssertEqual($0 as? AppProxyIdentityFailure, .staleAuthorization)
        }
        XCTAssertNoThrow(try AppProxyFolderAccess(AppProxyPolicy(ownerUID: 501, routes: [openai], folders: [], grants: [], codeStamp: stamp)))
    }
    func testFolderGrantsAnswerOnlyTheirRequest() throws {
        let folders = ["/opt/homebrew/Caskroom/claude-code", "/Users/me/.local/share/claude/versions"]
        let request = AppProxyFolderRequest(ownerUID: 501, category: "claude", folders: folders)
        XCTAssertNoThrow(try request.validate())
        let invalidRequests = [
            AppProxyFolderRequest(ownerUID: 0, category: "claude", folders: folders),
            AppProxyFolderRequest(ownerUID: 501, category: "", folders: folders),
            AppProxyFolderRequest(ownerUID: 501, category: "claude", folders: []),
            AppProxyFolderRequest(ownerUID: 501, category: "claude", folders: (0..<17).map { "/opt/f\($0)" }),
            AppProxyFolderRequest(ownerUID: 501, category: "claude", folders: [folders[0], folders[0]]),
            AppProxyFolderRequest(ownerUID: 501, category: "claude", folders: ["/"]),
        ]
        for value in invalidRequests { XCTAssertThrowsError(try value.validate(), "\(value)") }
        // Folders that do not exist yet are approved but not granted.
        XCTAssertNoThrow(try AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: [folders[1]], grants: [Data([1])])
            .validate(for: request))
        XCTAssertNoThrow(try AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: [], grants: []).validate(for: request))
        let invalidGrants = [
            AppProxyFolderGrants(ownerUID: 502, category: "claude", folders: [folders[0]], grants: [Data([1])]),
            AppProxyFolderGrants(ownerUID: 501, category: "chatgpt", folders: [folders[0]], grants: [Data([1])]),
            AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: ["/opt/other"], grants: [Data([1])]),
            AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: [folders[0]], grants: []),
            AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: [folders[0], folders[0]], grants: [Data([1]), Data([1])]),
            AppProxyFolderGrants(ownerUID: 501, category: "claude", folders: [folders[0]], grants: [Data()]),
        ]
        for value in invalidGrants { XCTAssertThrowsError(try value.validate(for: request), "\(value)") }
    }
    func testGenerationTransactionRollbackExpiryAndReplay() throws {
        let a=UUID(), b=UUID(), c=UUID()
        var gate=AppProxyGenerationGate(a)
        XCTAssertThrowsError(try gate.prepare(b, expected: c, now: 0))
        try gate.prepare(b, expected: a, now: 0)
        XCTAssertEqual(gate.current,a) // prepare cannot activate policy
        gate.abort(); XCTAssertEqual(gate.current,a)
        XCTAssertThrowsError(try gate.commit(b, now: 1))
        try gate.prepare(b, expected: a, now: 2)
        XCTAssertTrue(gate.expirePrepared(now: 33))
        XCTAssertThrowsError(try gate.commit(b, now: 33))
        try gate.prepare(c, expected: a, now: 34)
        try gate.commit(c, now: 35)
        XCTAssertEqual(gate.current,c)
        XCTAssertThrowsError(try gate.prepare(b, expected: a, now: 36))
    }
    func testSettingsPoliciesValidateAndOlderEntriesTakePresetIdentifiers() throws {
        let customID = "app_00000000-0000-4000-8000-000000000001"
        let entry = AppProxyEntry(id: customID, title: "Tool", path: "/opt/tools/bin/tool", port: 17975,
                                  teamIdentifiers: ["ABCDE12345"], signingIdentifiers: ["tool"], directories: ["~/tools", "/opt/tools"])
        XCTAssertEqual(try JSONDecoder().decode(AppProxyEntry.self, from: JSONEncoder().encode(entry)), entry)
        XCTAssertNoThrow(try AppProxySettings(applications: [entry]).validate())
        // Settings before policy version 5 listed scanned executables. A preset takes its own
        // identifiers and folders and keeps folders the operator added.
        let old = #"{"id":"claude","title":"T","port":17973,"teamIdentifiers":["Q6L2SF6YDW"],"#
            + #""directories":["/opt/extra","~/.local/share/claude/versions"],"executablePaths":["/x"]}"#
        let migrated = try JSONDecoder().decode(AppProxyEntry.self, from: Data(old.utf8))
        let preset = try XCTUnwrap(AppProxyEntry.defaults.first { $0.id == "claude" })
        XCTAssertEqual(migrated.signingIdentifiers, preset.signingIdentifiers)
        XCTAssertEqual(migrated.directories, preset.directories + ["/opt/extra"])
        let legacy = try JSONDecoder().decode(AppProxyEntry.self, from: Data(#"{"id":"chatgpt","title":"T","port":17971}"#.utf8))
        XCTAssertEqual(legacy.teamIdentifiers, []); XCTAssertEqual(legacy.signingIdentifiers, []); XCTAssertEqual(legacy.directories, [])
        let custom = try JSONDecoder().decode(AppProxyEntry.self, from: Data(
            #"{"id":"\#(customID)","title":"T","path":"/opt/tools/bin/tool","port":17975,"teamIdentifiers":["ABCDE12345"]}"#.utf8))
        XCTAssertEqual(custom.signingIdentifiers, [], "custom identifiers come from the chosen code when rules are built")
        // Code policy never reaches Mihomo's configuration.
        let routing = try XCTUnwrap(AppProxySettings(applications: [entry]).runtimeRouting.applications.first)
        XCTAssertEqual(routing.teamIdentifiers + routing.signingIdentifiers + routing.directories, [])
        // A Team ID or folder belongs to one application.
        var other = AppProxyEntry.defaults[0]
        other.teamIdentifiers = ["ABCDE12345"]
        XCTAssertThrowsError(try AppProxySettings(applications: [entry, other]).validate())
        other = AppProxyEntry.defaults[0]
        other.directories = ["/opt/tools"]
        XCTAssertThrowsError(try AppProxySettings(applications: [entry, other]).validate())
        let invalid: [([String], [String], [String])] = [(["abcde12345"], [], []), (["ABCDE12345", "ABCDE12345"], [], []),
                                                         ([], ["a b"], []), ([], ["x", "x"], []), ([], [], ["/"]),
                                                         ([], [], ["relative"]), ([], [], ["~/"])]
        for (teams, identifiers, directories) in invalid {
            var value = entry
            value.teamIdentifiers = teams; value.signingIdentifiers = identifiers; value.directories = directories
            XCTAssertThrowsError(try AppProxySettings(applications: [value]).validate(), "\(teams) \(identifiers) \(directories)")
        }
        XCTAssertEqual(AppProxyEntry.expandFolder("~/tools", home: "/Users/me"), "/Users/me/tools")
        XCTAssertEqual(AppProxyEntry.expandFolder("/opt/tools", home: "/Users/me"), "/opt/tools")
    }
    func testAuditReceiptPreservesPIDVersionWithoutTrafficData() {
        var words: [UInt32] = [501,501,20,501,20,123,10,7]
        let token = words.withUnsafeMutableBytes { Data($0) }
        let generation = UUID()
        let evidence = AppProxyFlowEvidence(flow: UUID(), token: token, stage: "dnsAnswered", generation: generation)
        XCTAssertEqual(evidence.generation, generation)
        XCTAssertEqual(evidence.pid,123); XCTAssertEqual(evidence.pidVersion,7)
        XCTAssertEqual(AppProxyFlowEvidence.word(token,1),501)
        XCTAssertEqual(AppProxyFlowEvidence.word(Data(),1),0)
    }
    func testFlowOwnersShareExecutablePathsAndStayBounded() throws {
        let owners = AppProxyFlowOwners([(52000, false, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 10),
                                         (52001, false, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 10),
                                         (52000, true, "/opt/homebrew/Cellar/packer/1.15.3/bin/packer", 11)])
        XCTAssertEqual(owners.executables.count, 2, "repeated paths are sent once")
        XCTAssertEqual(owners.owner(port: 52000, udp: true)?.path, "/opt/homebrew/Cellar/packer/1.15.3/bin/packer")
        XCTAssertEqual(owners.owner(port: 52000, udp: false)?.pid, 10)
        XCTAssertNil(owners.owner(port: 52002, udp: false))
        let many = AppProxyFlowOwners((0..<1000).map { (UInt16($0), false, "/tool/\($0 % 300)", UInt32($0)) })
        XCTAssertLessThanOrEqual(many.flows.count, AppProxyFlowOwners.maximumFlows)
        XCTAssertLessThanOrEqual(many.executables.count, AppProxyFlowOwners.maximumExecutables)
        let reply = AppProxyRuntimeStatus(generation: UUID(), ready: true, verifiedTargets: 1, flowOwners: many)
        XCTAssertLessThan(try JSONEncoder().encode(reply).count, 65536, "fits the provider message limit")
        // Replies from a provider without the owner table still decode.
        let legacy = #"{"ready":true,"verifiedTargets":1,"counters":{},"recentFlows":[]}"#
        let decoded = try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.flowOwners)
        XCTAssertNil(decoded.providerVersion, "a provider without a version is treated as older than the bundle")
        let current = AppProxyRuntimeStatus(generation: nil, ready: true, verifiedTargets: 0, providerVersion: "1.0.9")
        XCTAssertEqual(try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: JSONEncoder().encode(current)).providerVersion, "1.0.9")
    }
}

extension AppProxyIdentityTests {
    func testLateSignatureValidationCannotRenewExpiredStoppedOrReplacedLease() throws {
        let generation = UUID(), next = UUID()
        var gate = AppProxyGenerationGate(generation)
        XCTAssertNoThrow(try gate.validateRenewal(expected: generation, active: true, lastRenewal: 10, now: 90))
        for (active, now) in [(false, 90.0), (true, 100.01), (true, 9.0)] {
            XCTAssertThrowsError(try gate.validateRenewal(expected: generation, active: active, lastRenewal: 10, now: now)) {
                XCTAssertEqual($0 as? AppProxyIdentityFailure, .staleAuthorization)
            }
        }
        try gate.prepare(next, expected: generation, now: 20)
        try gate.commit(next, now: 21)
        XCTAssertThrowsError(try gate.validateRenewal(expected: generation, active: true, lastRenewal: 21, now: 22)) {
            XCTAssertEqual($0 as? AppProxyIdentityFailure, .generationMismatch)
        }
    }
}
