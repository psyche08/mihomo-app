import CMihomoDNSSystem
import Darwin
import Foundation
import XCTest
@testable import MihomoDNSCore

final class DaemonOwnedTUNTests: XCTestCase {
    func testPrefixSubtractionRetainsBothAddressFamilies() throws {
        let all = try OwnedTUNPrefix("0.0.0.0/0")
        let omitted = try OwnedTUNPrefix("192.0.2.0/24")
        let parts = all.subtracting(omitted)
        XCTAssertFalse(parts.contains { $0.contains(omitted) || omitted.contains($0) })
        XCTAssertTrue(parts.contains { $0.contains(try! OwnedTUNPrefix("192.0.3.1/32")) })
        XCTAssertEqual(parts.reduce(UInt64(0)) { $0 + (UInt64(1) << (32-$1.bits)) }, (UInt64(1)<<32)-256)
        let v6 = try OwnedTUNPrefix("2001:db8::/32")
        let split = v6.subtracting(try OwnedTUNPrefix("2001:db8:8000::/33"))
        XCTAssertEqual(split, [try OwnedTUNPrefix("2001:db8::/33")])
        XCTAssertEqual(v6.subtracting(omitted), [v6])
        XCTAssertThrowsError(try OwnedTUNPrefix("1.2.3.4/33"))
        XCTAssertThrowsError(try OwnedTUNPrefix("invalid/8"))
    }

    func testDarwinPlanPreservesExclusionsAndDoesNotReplaceDefaultRoute() throws {
        let plan = try OwnedTUNPlan(controllerData: Data(#"{"tun":{"auto-route":true,"inet4-address":["198.18.0.1/30"],"inet6-address":["fd00::1/126"],"route-exclude-address":["192.0.2.0/24","2001:db8::/32"]}}"#.utf8))
        XCTAssertEqual(plan.mtu, 9000)
        XCTAssertFalse(plan.routes.contains { $0.bits == 0 })
        for value in ["192.0.2.1/32", "2001:db8::1/128", "0.0.0.1/32", "::1/128"] {
            let excluded = try OwnedTUNPrefix(value)
            XCTAssertFalse(plan.routes.contains { $0.contains(excluded) })
        }
        for value in ["8.8.8.8/32", "198.18.0.2/32", "2606:4700::1/128"] {
            let included = try OwnedTUNPrefix(value)
            XCTAssertTrue(plan.routes.contains { $0.contains(included) })
        }
        XCTAssertThrowsError(try OwnedTUNPlan(controllerData: Data(#"{"tun":{"inet4-address":["not-a-prefix"]}}"#.utf8)))
    }

    func testResidentSwitchLeavesInheritedListenerIdentityUnchanged() throws {
        let source = "tun:\n  enable: true\n  auto-route: true\ndns:\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  fake-ip-filter: ['real.invalid']\n"
        let attached = try MihomoConfigurator.attachingDaemonTUN(source, interfaceName: "utun123")
        let off = try MihomoConfigurator.residentProfile(attached, sourceProfile: source,
            configuration: .init(manageSystemDNS: false, enhancedTUNEnabled: false, localDoH: .init()), preserveTUNListener: true)
        let on = try MihomoConfigurator.residentProfile(off, sourceProfile: source,
            configuration: .init(manageSystemDNS: true, globalDNSFallbackEnabled: true, enhancedTUNEnabled: true), preserveTUNListener: true)
        for text in [off, on] {
            XCTAssertEqual(text.components(separatedBy: "dns:\n")[0], attached.components(separatedBy: "dns:\n")[0])
            XCTAssertTrue(text.contains("file-descriptor: 3"))
        }
        XCTAssertTrue(off.contains("MATCH,real-ip"))
        XCTAssertFalse(on.contains("MATCH,real-ip"))
        XCTAssertThrowsError(try MihomoConfigurator.attachingDaemonTUN(source, interfaceName: "en0"))
    }

    func testInheritedDescriptorRejectsAnOrdinarySocket() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        XCTAssertThrowsError(try DaemonOwnedTUN(create: false, inheritedDescriptor: fd))
    }

    func testVerifiedStopLeavesProfilePortableForComponentRollback() throws {
        let source = "tun:\n  enable: true\n  auto-route: true\ndns:\n  enhanced-mode: fake-ip\n"
        XCTAssertEqual(try MihomoConfigurator.detachingDaemonTUN(source, enabled: false), source)
        let attached = try MihomoConfigurator.attachingDaemonTUN(source, interfaceName: "utun123")
        for enabled in [false, true] {
            let portable = try MihomoConfigurator.detachingDaemonTUN(attached, enabled: enabled)
            XCTAssertFalse(portable.contains("file-descriptor:"))
            XCTAssertFalse(portable.contains("device:"))
            XCTAssertTrue(portable.contains("  enable: \(enabled)\n"))
            XCTAssertTrue(portable.contains("  auto-route: true\n"))
            XCTAssertEqual(try MihomoConfigurator.detachingDaemonTUN(portable, enabled: enabled), portable)
        }
    }

    func testGeneralIPv6PreferenceCannotChangeInheritedListenerIdentity() throws {
        let snapshot = Data(#"{"mode":"rule","ipv6":false,"tun":{"file-descriptor":3}}"#.utf8)
        let next = try MihomoConfigurator.preservingResidentSettings(snapshot, in: "mode: direct\nipv6: true\n")
        XCTAssertTrue(next.contains("ipv6: true"))
        XCTAssertTrue(next.contains("mode: rule"))
    }

    func testPrivilegedCleanupPreservesForeignRoutes() throws {
        guard geteuid() == 0, ProcessInfo.processInfo.environment["MIHOMO_PRIVILEGED_TUN_TESTS"] == "1" else {
            throw XCTSkip("requires explicit isolated root TUN acceptance")
        }
        let first = try DaemonOwnedTUN(), second = try DaemonOwnedTUN()
        defer { try? first.deactivate(); try? second.deactivate() }
        for (interface, address) in [(first, "198.19.255.1"), (second, "198.19.255.5")] {
            XCTAssertEqual(mihomo_owned_tun_set_up(interface.handle.fileDescriptor, 1, 9000), 0)
            XCTAssertEqual(mihomo_owned_tun_address(interface.handle.fileDescriptor, address, 30, 1), 0)
        }
        XCTAssertEqual(mihomo_owned_tun_route(first.handle.fileDescriptor, "203.0.113.254", 32, "198.19.255.1", 1), 0)
        var route = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        XCTAssertEqual(mihomo_dns_route_interface("203.0.113.254", &route, route.count), 0)
        // The cached query socket receives every broadcast. Fill its small
        // receive buffer before the next query: its fresh reply must not be
        // dropped behind stale route events and turn readiness into a timeout.
        for _ in 0..<64 {
            XCTAssertEqual(mihomo_owned_tun_route(first.handle.fileDescriptor, "203.0.113.254", 32, "198.19.255.1", 0), 0)
            XCTAssertEqual(mihomo_owned_tun_route(first.handle.fileDescriptor, "203.0.113.254", 32, "198.19.255.1", 1), 0)
        }
        XCTAssertEqual(mihomo_dns_route_interface("203.0.113.254", &route, route.count), 0)
        XCTAssertEqual(String(cString: route), first.interfaceName)
        XCTAssertEqual(mihomo_owned_tun_route(second.handle.fileDescriptor, "203.0.113.254", 32, "198.19.255.5", 1), -EEXIST)
        try second.deactivate()
        XCTAssertEqual(mihomo_dns_route_interface("203.0.113.254", &route, route.count), 0)
        XCTAssertEqual(String(cString: route), first.interfaceName)
        try first.deactivate(); try first.deactivate()
        XCTAssertEqual(mihomo_dns_route_interface("203.0.113.254", &route, route.count), 0)
        XCTAssertNotEqual(String(cString: route), first.interfaceName)
        // A stale controller response cannot reactivate a terminated child.
        let plan = try OwnedTUNPlan(controllerData: Data(#"{"tun":{"auto-route":true,"inet4-address":["198.19.255.1/30"],"route-address":["203.0.113.254/32"]}}"#.utf8))
        try first.activate(plan, permitted: { false })
        XCTAssertEqual(mihomo_dns_route_interface("203.0.113.254", &route, route.count), 0)
        XCTAssertNotEqual(String(cString: route), first.interfaceName)
    }

    /// Explicit privileged acceptance uses only a benchmark network prefix.
    /// It never changes default routes, system DNS or the installed daemon.
    func testPrivilegedInterfaceSurvivesCoreAndTrafficSwitches() throws {
        guard geteuid() == 0, ProcessInfo.processInfo.environment["MIHOMO_PRIVILEGED_TUN_TESTS"] == "1" else {
            throw XCTSkip("requires explicit isolated root TUN acceptance")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/staging/mihomo-aarch64-apple-darwin")
        let directory = URL(fileURLWithPath: "/private/tmp/owned-tun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try DaemonOwnedTUN()
        defer { try? owner.deactivate() }
        let duplicate = try DaemonOwnedTUN(create: false, inheritedDescriptor: owner.handle.fileDescriptor)
        XCTAssertEqual(duplicate.interfaceName, owner.interfaceName)
        let port = try reservePort()
        let path = directory.appendingPathComponent("config.yaml")
        let source = """
        mode: direct
        ipv6: true
        log-level: warning
        external-controller: 127.0.0.1:\(port)
        secret: fixture-only
        tun:
          enable: true
          auto-route: true
          auto-detect-interface: false
          stack: mixed
          route-address: [198.19.128.0/17, '2001:db8::/32']
          inet6-address: ['fd60:ffff::1/126']
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.19.128.1/17
          nameserver: [udp://127.0.0.1:1]

        """
        let attached = try MihomoConfigurator.attachingDaemonTUN(source, interfaceName: owner.interfaceName, enable: false)
        try attached.write(to: path, atomically: true, encoding: .utf8)
        let configuration = ProxyConfiguration(manageSystemDNS: false, enhancedTUNEnabled: true,
            mihomoProcess: .init(binaryPath: binary.path, configDirectory: directory.path, configPath: path.path),
            controllerEndpoint: .init(host: "127.0.0.1", port: port), controllerSecret: "fixture-only", localDoH: .init())
        // Exercise Foundation's explicit stdin handoff, exactly as the signed
        // production launcher does, with this fixture's own executable/paths.
        for _ in 0..<2 {
            try duplicate.deactivate()
            try attached.write(to: path, atomically: true, encoding: .utf8)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "exec 3<&0; exec 0</dev/null; exec \"$@\"", "owned-tun-fixture", binary.path, "-d", directory.path, "-f", path.path]
            child.standardInput = duplicate.handle
            child.standardOutput = FileHandle.standardError; child.standardError = FileHandle.standardError
            try child.run()
            defer {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }
            var data: Data?
            let deadline = Date().addingTimeInterval(5)
            while data == nil, Date() < deadline, child.isRunning {
                data = MihomoRuntimeInspector.rawControllerConfiguration(configuration: configuration)
                if let value = data, let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
                   let tun = object["tun"] as? [String: Any], tun["file-descriptor"] as? Int != 3 { data = nil }
                if data == nil { usleep(10_000) }
            }
            let controllerData = try XCTUnwrap(data)
            let plan = try OwnedTUNPlan(controllerData: controllerData)
            try duplicate.prepareAttachment(plan)
            let ready = try MihomoConfigurator.attachingDaemonTUN(attached, interfaceName: owner.interfaceName)
            try ready.write(to: path, atomically: true, encoding: .utf8)
            try MihomoRuntimeInspector.attachPrebuiltTUN(configuration: configuration)
            let pid = child.processIdentifier
            for enabled in [true, false, true, false] {
                var policy = configuration; policy.enhancedTUNEnabled = enabled
                let next = try MihomoConfigurator.residentProfile(
                    String(contentsOf: path, encoding: .utf8), sourceProfile: source, configuration: policy, preserveTUNListener: true)
                try next.write(to: path, atomically: true, encoding: .utf8)
                try MihomoRuntimeInspector.reloadResidentMihomo(configuration: policy)
                if enabled {
                    try duplicate.activate(plan)
                    let answer = try SocketDNSClient.query(DNSMessage.runtimeHealthQuery,
                        endpoint: .init(host: "198.19.128.2", port: 53), timeoutMilliseconds: 1000, interfaceName: nil)
                    XCTAssertFalse(answer.isEmpty, "packet must traverse the inherited utun into Mihomo")
                } else {
                    try duplicate.suspend()
                    var route = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    XCTAssertEqual(mihomo_dns_route_interface("198.19.128.2", &route, route.count), 0)
                    XCTAssertNotEqual(String(cString: route), owner.interfaceName)
                }
                XCTAssertNotEqual(if_nametoindex(owner.interfaceName), 0)
                XCTAssertTrue(child.isRunning); XCTAssertEqual(child.processIdentifier, pid)
            }
            child.terminate(); child.waitUntilExit()
            XCTAssertNotEqual(if_nametoindex(owner.interfaceName), 0, "daemon's descriptor retains the interface after core exit")
        }
    }

    private func reservePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnedTUNError.system(-errno) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout.size(ofValue: address)); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout.size(ofValue: address))
        return try withUnsafeMutablePointer(to: &address) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(fd, $0, size) == 0, getsockname(fd, $0, &size) == 0 else { throw OwnedTUNError.system(-errno) }
                return Int(UInt16(bigEndian: p.pointee.sin_port))
            }
        }
    }
}
