import Foundation
import XCTest
@testable import MihomoDNSCore

final class NetworkProfileSettingsTests: XCTestCase {
    private let source = """
    mixed-port: 7897
    port: 7890
    socks-port: 7891
    mode: global
    tun:
      enable: true
      stack: system
      dns-hijack:
        - any:53
    dns:
      enable: true
      nameserver:
        - tcp://127.0.0.1:1054
    proxy-groups:
      - name: PROXY
        type: select
        proxies: [REJECT]
    rules:
      - DOMAIN-SUFFIX,example.test,REJECT
      - MATCH,PROXY

    """

    func testMixedListenerUnifiesPortsWithoutChangingDNSOrTUNOwnership() throws {
        let result = try NetworkProfileSettings(mixedPort: 8888).applying(to: source)
        XCTAssertTrue(result.contains("mixed-port: 8888\nport: 0\nsocks-port: 0"))
        XCTAssertTrue(result.contains("  stack: mixed"))
        XCTAssertTrue(result.contains("  enable: true\n"))
        XCTAssertTrue(result.contains("    - tcp://127.0.0.1:1054"))
        XCTAssertTrue(result.contains("mode: global"))
    }

    func testSelectedAppsIncludesHelpersAndPreventsUnsupportedUDPFallingThroughToDirect() throws {
        let settings = NetworkProfileSettings(applicationMode: .selectedOnly,
            applicationPaths: ["/Applications/Chat (Beta).app"], policy: "PROXY")
        let result = try settings.applying(to: source)
        let rule = #"PROCESS-PATH-REGEX,^/Applications/Chat \(Beta\)\.app/,PROXY"#
        XCTAssertTrue(result.contains(rule))
        XCTAssertTrue(result.contains("mode: rule\n"))
        XCTAssertTrue(result.contains("find-process-mode: always\n"))
        let reject = try XCTUnwrap(result.range(of: #"\.app/,REJECT"#))
        let direct = try XCTUnwrap(result.range(of: "MATCH,DIRECT"))
        let original = try XCTUnwrap(result.range(of: "DOMAIN-SUFFIX,example.test,REJECT"))
        XCTAssertLessThan(reject.lowerBound, direct.lowerBound)
        XCTAssertLessThan(direct.lowerBound, original.lowerBound)
        let pattern = #"^/Applications/Chat \(Beta\)\.app/"#
        let regex = try NSRegularExpression(pattern: pattern)
        for path in ["/Applications/Chat (Beta).app/Contents/MacOS/Chat",
                     "/Applications/Chat (Beta).app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"] {
            XCTAssertNotNil(regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)))
        }
        let other = "/Applications/Chat (Beta).app.evil/Contents/MacOS/Chat"
        XCTAssertNil(regex.firstMatch(in: other, range: NSRange(other.startIndex..., in: other)))
    }

    func testRepeatedEditsReplaceManagedRulesAndDisablingPreservesOriginalRules() throws {
        var settings = NetworkProfileSettings(applicationMode: .bypassSelected,
            applicationPaths: ["/Applications/Game.app"])
        let once = try settings.applying(to: source)
        XCTAssertEqual(try settings.applying(to: once), once)
        XCTAssertEqual(try NetworkProfileSettings.read(from: once), settings)
        settings.applicationPaths = ["/Applications/Other.app"]
        let changed = try settings.applying(to: once)
        XCTAssertFalse(changed.contains("Game"))
        XCTAssertTrue(changed.contains("DOMAIN-SUFFIX,example.test,REJECT"))
        XCTAssertFalse(changed.contains("MATCH,DIRECT"))
        settings.applicationMode = .profileRules
        let disabled = try settings.applying(to: changed)
        XCTAssertFalse(disabled.contains("PROCESS-PATH-REGEX"))
        XCTAssertFalse(disabled.contains("mihomobox-app-rules-begin"))
        XCTAssertTrue(disabled.contains("  - MATCH,PROXY"))
    }

    func testZeroIndentRulesCRLFDocumentStartAndQuotedPaths() throws {
        let input = "---\r\n" + source.replacingOccurrences(of: "  - DOMAIN", with: "- DOMAIN")
            .replacingOccurrences(of: "  - MATCH", with: "- MATCH").replacingOccurrences(of: "\n", with: "\r\n")
        let settings = NetworkProfileSettings(applicationMode: .bypassSelected,
            applicationPaths: ["/Applications/It's #1.app"])
        let result = try settings.applying(to: input)
        XCTAssertTrue(result.contains("\n- 'PROCESS-PATH-REGEX"))
        XCTAssertTrue(result.contains("It''s #1"))
        XCTAssertLessThan(try XCTUnwrap(result.range(of: "---")).lowerBound,
                          try XCTUnwrap(result.range(of: "find-process-mode:")).lowerBound)
        XCTAssertEqual(try settings.applying(to: result), result)
    }

    func testRejectsUnsafeRuleInputsAndListenerCollisions() {
        for path in ["Game.app", "/Applications/a,b.app", "/Applications/../Game.app", "/Apps/a\n.app"] {
            XCTAssertThrowsError(try NetworkProfileSettings(applicationMode: .selectedOnly,
                applicationPaths: [path]).applying(to: source))
        }
        for policy in ["", "A,DIRECT", "A\nB"] {
            XCTAssertThrowsError(try NetworkProfileSettings(applicationMode: .selectedOnly,
                applicationPaths: ["/Applications/Game.app"], policy: policy).applying(to: source))
        }
        for port in [0, -1, 53, 443, 1054, 1153, 9090, 65536] {
            XCTAssertThrowsError(try NetworkProfileSettings(mixedPort: port).applying(to: source))
        }
        XCTAssertThrowsError(try NetworkProfileSettings(mixedPort: 8888)
            .applying(to: "external-controller: 127.0.0.1:8888\n" + source))
        XCTAssertThrowsError(try NetworkProfileSettings().applying(to: "listeners: []\n" + source))
    }

    func testRejectsAmbiguousYAMLAndDamagedManagedBlocks() {
        for prefix in ["port: 1234\n", "'port': 1234\n", "port : 1234\n", "<<: *defaults\n",
                       "# mihomobox-network: invalid\n"] {
            if prefix.hasPrefix("#") {
                XCTAssertThrowsError(try NetworkProfileSettings.read(from: prefix + source))
            } else {
                XCTAssertThrowsError(try NetworkProfileSettings().applying(to: prefix + source))
            }
        }
        XCTAssertThrowsError(try NetworkProfileSettings().applying(to: source + "  # mihomobox-app-rules-begin\n"))
        XCTAssertThrowsError(try NetworkProfileSettings(applicationMode: .selectedOnly,
            applicationPaths: ["/Applications/App.app"]).applying(to: source.replacingOccurrences(of: "rules:\n", with: "rules: []\n")))
    }

    func testYAMLPortsAreAuthoritativeAfterManualEditing() throws {
        let saved = try NetworkProfileSettings().applying(to: source)
            .replacingOccurrences(of: "mixed-port: 7897", with: "mixed-port: 8900")
        XCTAssertEqual(try NetworkProfileSettings.read(from: saved).mixedPort, 8900)
    }

    func testExistingGVisorStackRemainsSelectedWhenEditingAppRouting() throws {
        let saved = source.replacingOccurrences(of: "stack: system", with: "stack: gVisor")
        let settings = try NetworkProfileSettings.read(from: saved)
        XCTAssertEqual(settings.tunStack, "gvisor")
        XCTAssertTrue(try settings.applying(to: saved).contains("stack: gvisor"))
    }

    func testSwitchOffAndOnRetainsSelectionAndRestoresIdenticalRules() throws {
        for mode in [NetworkProfileSettings.ApplicationMode.selectedOnly, .bypassSelected] {
            var settings = NetworkProfileSettings(applicationMode: mode,
                applicationPaths: ["/Applications/Game.app"], policy: "PROXY")
            let enabled = try settings.applying(to: source)
            settings.applicationRoutingEnabled = false
            let disabled = try settings.applying(to: enabled)
            XCTAssertFalse(disabled.contains("PROCESS-PATH-REGEX"))
            XCTAssertFalse(disabled.contains("MATCH,DIRECT"))
            XCTAssertTrue(disabled.contains("DOMAIN-SUFFIX,example.test,REJECT"))
            var restored = try NetworkProfileSettings.read(from: disabled)
            XCTAssertFalse(restored.usesApplicationRules)
            XCTAssertEqual(restored.applicationMode, mode)
            XCTAssertEqual(restored.applicationPaths, settings.applicationPaths)
            XCTAssertEqual(restored.policy, "PROXY")
            restored.applicationRoutingEnabled = true
            XCTAssertEqual(try restored.applying(to: disabled), enabled)
        }
    }

    func testLegacyMetadataInfersEnablementWithoutChangingRouting() throws {
        for mode in NetworkProfileSettings.ApplicationMode.allCases {
            let legacy = """
            # mihomobox-network: {"mixedPort":7897,"tunStack":"system","applicationMode":"\(mode.rawValue)","applicationPaths":["/Applications/Game.app"],"policy":"PROXY"}
            """
            let settings = try NetworkProfileSettings.read(from: legacy + "\n" + source)
            XCTAssertEqual(settings.usesApplicationRules, mode != .profileRules)
        }
    }

    func testRemovingLastApplicationRequiresDisablingRouting() throws {
        var settings = NetworkProfileSettings(applicationMode: .selectedOnly,
            applicationPaths: ["/Applications/Game.app"])
        let enabled = try settings.applying(to: source)
        settings.applicationPaths = []
        XCTAssertThrowsError(try settings.applying(to: enabled))
        settings.applicationRoutingEnabled = false
        let disabled = try settings.applying(to: enabled)
        XCTAssertFalse(disabled.contains("PROCESS-PATH-REGEX"))
        XCTAssertTrue(try NetworkProfileSettings.read(from: disabled).applicationPaths.isEmpty)
    }
}

/// Opt-in syntax integration against the checksummed, pinned core. This runs
/// `-t` only: no listener, routes, DNS takeover or privileged installation.
final class NetworkProfileKernelTests: XCTestCase {
    func testGeneratedProfilesAreAcceptedByPinnedMihomo() throws {
        guard let binary = ProcessInfo.processInfo.environment["MIHOMO_NETWORK_VALIDATOR"] else {
            throw XCTSkip("Set MIHOMO_NETWORK_VALIDATOR to the pinned Mihomo binary")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        tun:
          enable: true
          stack: mixed
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxy-groups:
          - name: PROXY
            type: select
            proxies: [REJECT]
        rules:
        - MATCH,PROXY

        """
        for mode in NetworkProfileSettings.ApplicationMode.allCases {
            let settings = NetworkProfileSettings(applicationMode: mode,
                applicationPaths: ["/Applications/It's #1 (Beta).app"], policy: "PROXY")
            let config = root.appendingPathComponent("config.yaml")
            try settings.applying(to: source).write(to: config, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-t", "-d", root.path, "-f", config.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                XCTFail("Pinned validator exceeded 15 seconds")
                return
            }
            XCTAssertEqual(process.terminationStatus, 0, "Core rejected \(mode.rawValue)")
        }
    }
}
