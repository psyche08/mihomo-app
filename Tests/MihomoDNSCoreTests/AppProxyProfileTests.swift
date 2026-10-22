import XCTest
import MihomoControl
@testable import MihomoDNSCore

final class AppProxyProfileTests: XCTestCase {
    func testBypassCannotConsumeCustomFakeIPAndDoesNotChangePublicNode() throws {
        for range in ["10.0.0.1/16", "fc00::/18"] {
            XCTAssertThrowsError(try AppProxyProfile.applying(settings, to: "dns:\n  fake-ip-range: \(range)\nrules: []\n"))
        }
        let source = "dns:\n  fake-ip-range: 198.18.0.1/16\nrules: []\n"
        let generated = try AppProxyProfile.applying(settings, to: source)
        let reloaded = try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(try AppProxyProfile.applying(reloaded, to: source), generated)
        for app in AppProxyApplication.allCases {
            XCTAssertTrue(generated.contains("proxies: [\"node-\(app.rawValue)\"]"))
        }
        var disabled = settings; disabled.bypass = .init(cidrs: [])
        XCTAssertNoThrow(try AppProxyProfile.applying(disabled, to: "dns:\n  fake-ip-range: 10.0.0.1/16\nrules: []\n"))
    }
    func testExecutableMembershipMigrationPersistenceAndBounds() throws {
        let legacy = try JSONDecoder().decode(AppProxyEntry.self, from: Data(#"{"id":"chatgpt","title":"Codex","port":17971}"#.utf8))
        XCTAssertEqual(legacy.executablePaths, [])
        var settings = AppProxySettings(applications: [legacy])
        settings.applications[0].executablePaths = ["/usr/bin/curl", "/usr/bin/git"]
        XCTAssertNoThrow(try settings.validate())
        XCTAssertEqual(try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(settings)), settings)
        for paths in [["curl"], ["~/bin/curl"], ["/usr/../bin/curl"], ["/bin/curl\n"], ["/"],
                      ["/bin/curl", "/bin/curl"], (0..<33).map { "/bin/tool\($0)" }] {
            settings.applications[0].executablePaths = paths
            XCTAssertThrowsError(try settings.validate())
        }
        settings.applications = AppProxyEntry.defaults
        settings.applications[0].executablePaths = ["/usr/bin/curl"]
        settings.applications[1].executablePaths = ["/usr/bin/curl"]
        XCTAssertThrowsError(try settings.validate(), "Ownership must be unique across apps")
    }
    private var settings: AppProxySettings {
        .init(routes: Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "node-" + $0.rawValue) }))
    }
    func testFourIndependentLoopbackListenersPreserveRawProfile() throws {
        let source = "mixed-port: 7897\ntun:\n  enable: false\nrules:\n  - MATCH,REJECT\n"
        let rendered = try AppProxyProfile.applying(settings, to: source)
        XCTAssertTrue(rendered.hasPrefix(source))
        for app in AppProxyApplication.allCases {
            XCTAssertTrue(rendered.contains("port: \(app.port)\n    udp: true\n    rule: mihomobox-app-\(app.rawValue)"))
            XCTAssertTrue(rendered.contains("MATCH,mihomobox-app-\(app.rawValue)"))
        }
        XCTAssertFalse(rendered.contains("    proxy:"), "An unconditional listener proxy bypasses Global/Direct mode")
        XCTAssertEqual(rendered.components(separatedBy: "listen: 127.0.0.1").count - 1, 4)
        XCTAssertFalse(rendered.contains("0.0.0.0"))
        XCTAssertEqual(try AppProxyProfile.applying(.init(), to: source), source)
    }
    func testLegacySettingsMigrateAndExplicitEmptyApplicationListStaysEmpty() throws {
        let legacy = try JSONDecoder().decode(AppProxySettings.self, from: Data(#"{"routes":{}}"#.utf8))
        XCTAssertEqual(legacy.applications, AppProxyEntry.defaults)
        let empty = AppProxySettings(applications: [])
        let restored = try JSONDecoder().decode(AppProxySettings.self, from: JSONEncoder().encode(empty))
        XCTAssertEqual(restored, empty)
        XCTAssertNoThrow(try restored.validate())
    }

    func testCustomApplicationProducesOnlyItsOwnBoundedListener() throws {
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Browser", path: "/Applications/Browser.app", port: 17975)
        let custom = AppProxySettings(routes: [entry.id: "remote"], applications: [entry])
        let output = try AppProxyProfile.applying(custom, to: "rules: []\n")
        XCTAssertTrue(output.contains("port: 17975"))
        XCTAssertFalse(output.contains("port: 17971"))
        XCTAssertThrowsError(try AppProxyProfile.applying(custom, to: "mixed-port: 17975\n"))
        for invalidPort in [UInt16(22), 7897, 17971, 18003] {
            var invalid = custom; invalid.applications[0].port = invalidPort
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = custom; invalid.applications.append(entry)
        XCTAssertThrowsError(try invalid.validate())
        invalid = custom; invalid.applications[0].path = "/Applications/../Browser.app"
        XCTAssertThrowsError(try invalid.validate())
        invalid = custom; invalid.applications[0].id = "injected:\nlisteners"
        XCTAssertThrowsError(try invalid.validate())
    }
    func testRejectsAmbiguousProfilesAndPortConflicts() {
        for source in ["listeners: []", "'listeners': []", "<<: *base", "---\n---\n", "...", "mixed-port: 17971", "socks-port: '17974'"] {
            XCTAssertThrowsError(try AppProxyProfile.applying(settings, to: source), source)
        }
    }
    func testPolicyNamesAreQuotedWithoutYAMLInjection() throws {
        var routes = settings
        routes.routes["chatgpt"] = "香港: \"fast\" # node"
        let output = try AppProxyProfile.applying(routes, to: "rules: []\n")
        XCTAssertTrue(output.contains("proxies: [\"香港: \\\"fast\\\" # node\"]"))
        routes.routes["chatgpt"] = "x\nlisteners: []"
        XCTAssertThrowsError(try AppProxyProfile.applying(routes, to: "rules: []"))
    }
    func testPinnedCoreAcceptsOverlayButNeedsRuntimeNodeValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/staging/mihomo-aarch64-apple-darwin")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "pinned Mihomo not staged")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-proxy-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = "mode: rule\nrules:\n  - MATCH,REJECT\nproxies:\n"
        for app in AppProxyApplication.allCases {
            source += "  - name: node-\(app.rawValue)\n    type: socks5\n    server: 127.0.0.1\n    port: 9\n"
        }
        func validate(_ settings: AppProxySettings) throws -> Int32 {
            let path = directory.appendingPathComponent("config.yaml")
            try AppProxyProfile.applying(settings, to: source).write(to: path, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-t", "-d", directory.path, "-f", path.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try validate(settings), 0)
        var invalid = settings; invalid.routes["claude"] = "missing-node"
        // The private selector also makes unknown targets fail core validation.
        XCTAssertNotEqual(try validate(invalid), 0)
        let snapshot = ControllerRouteSnapshot(mode: "rule", proxies: Dictionary(uniqueKeysWithValues:
            AppProxyApplication.allCases.map { ("node-" + $0.rawValue, .init(name: "node-" + $0.rawValue, type: "Socks5")) }))
        XCTAssertNoThrow(try settings.validateRoutes(in: snapshot))
        XCTAssertThrowsError(try invalid.validateRoutes(in: snapshot))
    }

    func testExistingGroupAndSubRuleBlocksArePreservedWithoutDuplicateKeys() throws {
        for indentation in ["", "  ", "    "] {
            let source = "proxy-groups:\n\(indentation)- name: Existing\n\(indentation)  type: select\n\(indentation)  proxies: [DIRECT]\nsub-rules:\n    existing:\n      - MATCH,DIRECT\nrules: []\n"
            let output = try AppProxyProfile.applying(settings, to: source)
            XCTAssertEqual(output.components(separatedBy: "\nsub-rules:").count, 2)
            XCTAssertTrue(output.contains("\(indentation)- name: mihomobox-app-chatgpt"))
            XCTAssertTrue(output.contains("    existing:\n      - MATCH,DIRECT"))
            XCTAssertTrue(output.contains("    mihomobox-app-chatgpt:\n      - MATCH,mihomobox-app-chatgpt"))
        }
        XCTAssertNoThrow(try AppProxyProfile.applying(settings, to: "proxy-groups: []\nsub-rules: {}\nrules: []\n"))
        let quotedKeys = try AppProxyProfile.applying(settings, to: "'proxy-groups' : []\n\"sub-rules\" : {}\nrules: []\n")
        XCTAssertFalse(quotedKeys.contains("'proxy-groups'"))
        XCTAssertFalse(quotedKeys.contains("\"sub-rules\""))
        for source in ["proxy-groups: *groups", "sub-rules: {existing: []}", "sub-rules: {}\nsub-rules: {}", "proxies:\n  - name: mihomobox-app-chatgpt\n"] {
            XCTAssertThrowsError(try AppProxyProfile.applying(settings, to: source))
        }
    }

    func testPinnedCoreActuallyFollowsModeAtRuntime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/staging/mihomo-aarch64-apple-darwin")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "pinned Mihomo not staged")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-proxy-modes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = AppProxyEntry(id: "app_00000000-0000-0000-0000-000000000001", title: "Fixture", path: "/tmp/fixture", port: 17999)
        let settings = AppProxySettings(routes: [entry.id: "app,node"], applications: [entry])
        let source = """
        mode: rule
        external-controller: 127.0.0.1:12347
        find-process-mode: off
        log-level: silent
        dns:
          enable: false
        proxies:
          - name: app,node
            type: http
            server: 127.0.0.1
            port: 12345
          - name: global-node
            type: http
            server: 127.0.0.1
            port: 12346
        proxy-groups:
        - name: Existing
          type: select
          proxies: [global-node]
        sub-rules:
            existing:
              - MATCH,REJECT
        rules:
          - MATCH,REJECT
        """
        let path = directory.appendingPathComponent("config.yaml")
        try AppProxyProfile.applying(settings, to: source).write(to: path, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/check-app-proxy-modes.py").path, binary.path, path.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testIncompleteUnknownAndDirectRoutesFailClosed() {
        XCTAssertThrowsError(try AppProxySettings(routes: ["chatgpt": "node"]).validate())
        var routes = settings
        routes.routes["unknown"] = "node"
        XCTAssertThrowsError(try routes.validate())
        for target in ["DIRECT", "PASS", "REJECT", "GLOBAL", "", " name "] {
            routes = settings; routes.routes["chatgpt"] = target
            XCTAssertThrowsError(try routes.validate())
        }
    }

    func testLoadBalancedAppRoutesDoNotRequireCurrentSelection() throws {
        // Match the pinned core's /proxies response: LoadBalance has `all`
        // but no `now`, unlike a Selector or URLTest group.
        let snapshot = try ControllerRouteSnapshot(
            configsData: Data(#"{"mode":"rule"}"#.utf8),
            proxiesData: Data(#"""
            {"proxies":{
              "Proxy":{"name":"Proxy","type":"LoadBalance","all":["direct-node","via-us","via-jp"]},
              "direct-node":{"name":"direct-node","type":"Trojan"},
              "via-us":{"name":"via-us","type":"Vmess"},
              "via-jp":{"name":"via-jp","type":"Trojan"}
            }}
            """#.utf8)
        )
        let routes = AppProxySettings(routes: Dictionary(uniqueKeysWithValues:
            AppProxyApplication.allCases.map { ($0.rawValue, "Proxy") }))
        XCTAssertNoThrow(try routes.validateRoutes(in: snapshot))
    }

    func testLoadBalancedRoutesValidateEveryBranchAndRejectCycles() {
        var snapshot = ControllerRouteSnapshot(mode: "rule", proxies: [
            "Proxy": .init(name: "Proxy", type: "LoadBalance", all: ["Node", "Nested"]),
            "Nested": .init(name: "Nested", type: "LoadBalance", all: ["Auto", "Node"]),
            "Auto": .init(name: "Auto", type: "Selector", now: "Node", all: ["Node", "DIRECT"]),
            "Node": .init(name: "Node", type: "Trojan"),
            "DIRECT": .init(name: "DIRECT", type: "Direct"),
            "Unknown": .init(name: "Unknown", type: "FutureProtocol"),
            "RenamedDirect": .init(name: "RenamedDirect", type: "Direct"),
        ])
        XCTAssertTrue(snapshot.routesThroughRemoteProxy("Proxy"))
        for members in [[String](), ["DIRECT"], ["Node", "DIRECT"], ["Node", "REJECT"],
                        ["Node", "Missing"], ["Node", "Unknown"], ["Node", "RenamedDirect"],
                        ["Node", "Proxy"], ["Node", "Nested"]] {
            snapshot.proxies["Nested"]?.all = members
            XCTAssertFalse(snapshot.routesThroughRemoteProxy("Proxy"), "members=\(members)")
        }
        snapshot.proxies["Nested"]?.all = ["Auto"]
        snapshot.proxies["Auto"]?.now = "Proxy"
        XCTAssertFalse(snapshot.routesThroughRemoteProxy("Proxy"))
        snapshot.proxies["Auto"]?.now = "DIRECT"
        XCTAssertFalse(snapshot.routesThroughRemoteProxy("Proxy"))
        snapshot.proxies["Auto"]?.now = ""
        XCTAssertFalse(snapshot.routesThroughRemoteProxy("Proxy"))
    }
}
