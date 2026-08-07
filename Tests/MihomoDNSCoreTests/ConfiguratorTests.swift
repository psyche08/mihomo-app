import Foundation
import XCTest
@testable import MihomoDNSCore

/// Ports the behaviour the Python configurator's tests pinned, plus the
/// tunnel-exclusion rules added after it moved into the agent.
final class ConfiguratorTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let profile = """
    port: 7890
    tun:
      enable: true
      auto-route: true
    dns:
      enable: true
      enhanced-mode: fake-ip
      fake-ip-range: 198.18.0.1/16
      nameserver:
        - 223.5.5.5
    proxies:
      - name: JP
        type: trojan
        server: jp.example.com
        port: 443
    rules:
      - MATCH,Proxy

    """

    struct StubResolver: ProxyServerAddressResolving {
        let answers: [String: [String]]
        func addresses(for host: String) -> [String] { answers[host] ?? [] }
    }

    func testApplyIsIdempotentAndRestoreIsExact() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        let backup = directory.appendingPathComponent("backup.yaml")
        try profile.write(to: config, atomically: true, encoding: .utf8)

        let paths = MihomoConfigurator.Paths(
            config: config.path,
            backup: backup.path,
            secretFile: directory.appendingPathComponent("secret").path
        )
        let resolver = StubResolver(answers: ["jp.example.com": ["198.51.100.7"]])
        try MihomoConfigurator.apply(paths, resolver: resolver)
        let once = try String(contentsOf: config, encoding: .utf8)
        try MihomoConfigurator.apply(paths, resolver: resolver)
        let twice = try String(contentsOf: config, encoding: .utf8)

        XCTAssertEqual(once, twice, "applying twice must not keep growing the file")
        XCTAssertTrue(once.contains("  listen: 127.0.0.1:1153\n"))
        XCTAssertTrue(once.contains("  proxy-server-nameserver:\n    - tcp://127.0.0.1:1054\n"))
        XCTAssertTrue(once.contains("log-level: warning\n"))
        XCTAssertTrue(once.contains("    - 198.51.100.7/32\n"))
        // The user's own keys survive.
        XCTAssertTrue(once.contains("port: 7890\n"))
        XCTAssertTrue(once.contains("      - MATCH,Proxy\n") || once.contains("  - MATCH,Proxy\n"))

        try MihomoConfigurator.restore(config: config.path, backup: backup.path)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), profile)
    }

    func testTunnelExclusionRejectsFakeIPAnswers() throws {
        // A Fake-IP address here would exclude an address the kernel never
        // dials while leaving the real one captured: worse than excluding none.
        let lines: [String] = profile
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) + "\n" }
        let poisoned = StubResolver(answers: ["jp.example.com": ["198.18.0.60"]])
        XCTAssertEqual(
            MihomoConfigurator.excludeProxyServersFromTunnel(lines, resolver: poisoned),
            lines,
            "a Fake-IP answer must leave the configuration untouched"
        )
        let good = StubResolver(answers: ["jp.example.com": ["198.51.100.7"]])
        XCTAssertTrue(
            MihomoConfigurator.excludeProxyServersFromTunnel(lines, resolver: good)
                .joined().contains("    - 198.51.100.7/32\n")
        )
    }

    func testNothingResolvedLeavesThePreviousExclusionAlone() {
        let lines = [
            "tun:\n", "  enable: true\n",
            "  route-exclude-address:\n", "    - 203.0.113.1/32\n",
            "proxies:\n", "  - server: jp.example.com\n",
        ]
        let empty = StubResolver(answers: [:])
        XCTAssertEqual(
            MihomoConfigurator.excludeProxyServersFromTunnel(lines, resolver: empty),
            lines,
            "resolution fails transiently; a stale correct list beats an empty one"
        )
    }

    func testServerHostsComeFromTheProxiesBlockOnly() {
        let lines = [
            "dns:\n", "  server: 1.1.1.1\n",
            "proxies:\n",
            "  - name: A\n", "    server: jp.example.com\n",
            "  - name: B\n", "    server: 203.0.113.9\n",
            "  - name: C\n", "    server: jp.example.com\n",
            "rules:\n", "  - MATCH,Proxy\n",
        ]
        XCTAssertEqual(
            MihomoConfigurator.serverHosts(lines),
            ["jp.example.com", "203.0.113.9"]
        )
    }

    func testControllerMustStayOnLoopback() throws {
        XCTAssertEqual(try MihomoConfigurator.normalizeController("127.0.0.1:9090").port, 9090)
        XCTAssertEqual(try MihomoConfigurator.normalizeController("http://localhost:9091/").port, 9091)
        // Rewritten to loopback even when the profile bound it to all interfaces.
        XCTAssertEqual(try MihomoConfigurator.normalizeController("0.0.0.0:9090").host, "127.0.0.1")
        XCTAssertThrowsError(try MihomoConfigurator.normalizeController("192.0.2.1:9090"))
        XCTAssertThrowsError(try MihomoConfigurator.normalizeController("127.0.0.1:0"))
        XCTAssertThrowsError(try MihomoConfigurator.normalizeController("127.0.0.1"))
    }

    func testTunMustBeEnabled() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try profile.replacingOccurrences(of: "  enable: true\n  auto-route", with: "  enable: false\n  auto-route")
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try MihomoConfigurator.apply(MihomoConfigurator.Paths(
                config: config.path,
                backup: directory.appendingPathComponent("backup.yaml").path
            ), resolver: StubResolver(answers: [:]))
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurator.ConfiguratorError, .tunDisabled)
        }
    }

    func testFakeIPPrefixFollowsThePrefixLength() {
        XCTAssertEqual(
            MihomoConfigurator.fakeIPPrefix(["dns:\n", "  fake-ip-range: 198.18.0.1/16\n"]),
            "198.18."
        )
        XCTAssertEqual(
            MihomoConfigurator.fakeIPPrefix(["dns:\n", "  fake-ip-range: 10.0.0.1/8\n"]),
            "10."
        )
    }
}

extension ConfiguratorTests {
    /// A commented-out header must never be mistaken for the real block.
    /// Stripping the comment first turned "# dns:" into "dns:", so the managed
    /// keys landed inside the comment and the live block went unmanaged.
    func testCommentedOutHeadersDoNotHijackTheRealBlock() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        let commented = """
        port: 7890
        # dns:
        #   enable: true
        # tun:
        #   enable: false
        tun:
          enable: true
        dns:
          enable: true
          nameserver:
            - 223.5.5.5

        """
        try commented.write(to: config, atomically: true, encoding: .utf8)
        try MihomoConfigurator.apply(MihomoConfigurator.Paths(
            config: config.path,
            backup: directory.appendingPathComponent("backup.yaml").path
        ), resolver: StubResolver(answers: [:]))

        let result = try String(contentsOf: config, encoding: .utf8)
        // The comment block is untouched...
        XCTAssertTrue(result.contains("# dns:\n#   enable: true\n"))
        XCTAssertTrue(result.contains("# tun:\n#   enable: false\n"))
        // ...and the managed keys went into the real dns block.
        let dnsIndex = try XCTUnwrap(result.range(of: "\ndns:\n")).lowerBound
        let listenIndex = try XCTUnwrap(result.range(of: "  listen: 127.0.0.1:1153")).lowerBound
        XCTAssertGreaterThan(listenIndex, dnsIndex, "managed keys must follow the real dns:")
    }

    /// The reader must invert the writer. A secret that does not round-trip is
    /// silently replaced on every apply, and the damage compounds.
    func testQuotedSecretsRoundTripExactly() throws {
        for secret in [#"s3cr3t"x"#, #"back\slash"#, "plain", "it's"] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = directory.appendingPathComponent("config.yaml")
            let secretFile = directory.appendingPathComponent("secret")
            let quoted = String(
                decoding: try JSONSerialization.data(withJSONObject: [secret]),
                as: UTF8.self
            ).dropFirst().dropLast()
            try """
            secret: \(quoted)
            tun:
              enable: true
            dns:
              enable: true

            """.write(to: config, atomically: true, encoding: .utf8)

            let paths = MihomoConfigurator.Paths(
                config: config.path,
                backup: directory.appendingPathComponent("backup.yaml").path,
                secretFile: secretFile.path
            )
            for pass in 1 ... 3 {
                try MihomoConfigurator.apply(paths, resolver: StubResolver(answers: [:]))
                let stored = try String(contentsOf: secretFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertEqual(stored, secret, "pass \(pass) rewrote the secret \(secret)")
            }
        }
    }

    func testScalarParsingMatchesTheOriginal() {
        XCTAssertEqual(MihomoConfigurator.parseScalar(#""a#b""#), "a#b")
        XCTAssertEqual(MihomoConfigurator.parseScalar("'it''s'"), "it's")
        XCTAssertEqual(MihomoConfigurator.parseScalar("plain # comment"), "plain")
        XCTAssertEqual(MihomoConfigurator.parseScalar("value#nospace"), "value#nospace")
        XCTAssertEqual(MihomoConfigurator.parseScalar("  "), "")
        XCTAssertEqual(MihomoConfigurator.parseScalar("# only a comment"), "")
        XCTAssertEqual(MihomoConfigurator.parseScalar("127.0.0.1:9090"), "127.0.0.1:9090")
    }

    /// "\r\n" is a single Swift Character, so a Character-based split never saw
    /// the newline and a CRLF profile collapsed into one unparseable line.
    func testCRLFProfilesStillParse() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        let crlf = "port: 7890\r\ntun:\r\n  enable: true\r\ndns:\r\n  enable: true\r\n"
        try crlf.write(to: config, atomically: true, encoding: .utf8)
        try MihomoConfigurator.apply(MihomoConfigurator.Paths(
            config: config.path,
            backup: directory.appendingPathComponent("backup.yaml").path
        ), resolver: StubResolver(answers: [:]))
        let result = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(result.contains("  listen: 127.0.0.1:1153"))
        XCTAssertTrue(result.contains("port: 7890"), "the user's own keys survive")
    }

    func testAppendingToAProfileWithNoTrailingNewline() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "tun:\n  enable: true\ndns:\n  enable: true".write(
            to: config, atomically: true, encoding: .utf8
        )
        try MihomoConfigurator.apply(MihomoConfigurator.Paths(
            config: config.path,
            backup: directory.appendingPathComponent("backup.yaml").path
        ), resolver: StubResolver(answers: [:]))
        let result = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(result.contains("enable: true  listen"), "keys must not be glued together")
        XCTAssertTrue(result.contains("  enable: true\n  listen: 127.0.0.1:1153"))
    }

    /// Skipping an unreadable daemon.json would leave the daemon authenticating
    /// with the previous secret while the profile carries a new one.
    func testAMissingDaemonConfigFailsLoudly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "tun:\n  enable: true\ndns:\n  enable: true\n".write(
            to: config, atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(
            try MihomoConfigurator.apply(MihomoConfigurator.Paths(
                config: config.path,
                backup: directory.appendingPathComponent("backup.yaml").path,
                daemonConfig: directory.appendingPathComponent("absent.json").path
            ), resolver: StubResolver(answers: [:]))
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurator.ConfiguratorError, .daemonConfigUnreadable)
        }
    }

    func testControllerAndSecretArePersistedWithPrivateModes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        let secretFile = directory.appendingPathComponent("secret")
        let metadata = directory.appendingPathComponent("controller.json")
        let daemonConfig = directory.appendingPathComponent("daemon.json")
        try "tun:\n  enable: true\ndns:\n  enable: true\n".write(
            to: config, atomically: true, encoding: .utf8
        )
        // Unrelated keys must survive the rewrite.
        try #"{"manageSystemDNS":true,"loopbackAlias":"127.0.0.53"}"#.write(
            to: daemonConfig, atomically: true, encoding: .utf8
        )

        try MihomoConfigurator.apply(MihomoConfigurator.Paths(
            config: config.path,
            backup: directory.appendingPathComponent("backup.yaml").path,
            secretFile: secretFile.path,
            controllerMetadata: metadata.path,
            daemonConfig: daemonConfig.path
        ), resolver: StubResolver(answers: [:]))

        let secret = try String(contentsOf: secretFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(secret.count, 64, "a generated secret is 32 bytes of hex")

        for url in [secretFile, metadata, daemonConfig] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            XCTAssertEqual(mode as? NSNumber, 0o600, "\(url.lastPathComponent) must stay private")
        }
        let daemon = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: daemonConfig)) as? [String: Any]
        )
        XCTAssertEqual(daemon["controllerSecret"] as? String, secret)
        XCTAssertEqual(daemon["manageSystemDNS"] as? Bool, true, "unrelated keys survive")
        XCTAssertEqual(daemon["loopbackAlias"] as? String, "127.0.0.53")
    }
}
