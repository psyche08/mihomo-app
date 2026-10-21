import XCTest
import MihomoControl
@testable import MihomoDNSCore

final class AppProxyProfileTests: XCTestCase {
    private var settings: AppProxySettings {
        .init(routes: Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.map { ($0.rawValue, "node-" + $0.rawValue) }))
    }
    func testFourIndependentLoopbackListenersPreserveRawProfile() throws {
        let source = "mixed-port: 7897\ntun:\n  enable: false\nrules:\n  - MATCH,REJECT\n"
        let rendered = try AppProxyProfile.applying(settings, to: source)
        XCTAssertTrue(rendered.hasPrefix(source))
        for app in AppProxyApplication.allCases {
            XCTAssertTrue(rendered.contains("port: \(app.port)\n    udp: true\n    proxy: \"node-\(app.rawValue)\""))
        }
        XCTAssertEqual(rendered.components(separatedBy: "listen: 127.0.0.1").count - 1, 4)
        XCTAssertFalse(rendered.contains("0.0.0.0"))
        XCTAssertEqual(try AppProxyProfile.applying(.init(), to: source), source)
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
        XCTAssertTrue(output.contains("proxy: \"香港: \\\"fast\\\" # node\""))
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
        // v1.19.30 deliberately does not validate listener proxy names with
        // -t. The root transaction must check the live catalog as well.
        XCTAssertEqual(try validate(invalid), 0)
        let snapshot = ControllerRouteSnapshot(mode: "rule", proxies: Dictionary(uniqueKeysWithValues:
            AppProxyApplication.allCases.map { ("node-" + $0.rawValue, .init(name: "node-" + $0.rawValue, type: "Socks5")) }))
        XCTAssertNoThrow(try settings.validateRoutes(in: snapshot))
        XCTAssertThrowsError(try invalid.validateRoutes(in: snapshot))
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
}
