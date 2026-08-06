import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import SystemConfiguration
import XCTest
@testable import MihomoDNSCore

final class CoreTests: XCTestCase {
    func testDNSMessageLengthValidation() {
        XCTAssertThrowsError(try DNSMessage.validate(Data(repeating: 0, count: 11)))
        XCTAssertNoThrow(try DNSMessage.validate(Data(repeating: 0, count: 12)))
    }

    func testTruncatedFlag() {
        XCTAssertTrue(DNSMessage.isTruncated(Data([0, 0, 0x02, 0])))
        XCTAssertFalse(DNSMessage.isTruncated(Data([0, 0, 0x01, 0])))
    }

    func testDNSQuestionNameParsing() throws {
        XCTAssertEqual(try DNSMessage.questionName(query(for: "API.Corp.Example")), "api.corp.example")
        XCTAssertThrowsError(try DNSMessage.questionName(Data(repeating: 0, count: 12)))
    }

    func testSplitDNSUsesLongestSuffixThenMatchOrder() {
        let broad = DNSUpstreamSelection(
            interfaceName: "en7",
            serviceID: "vpn-broad",
            servers: ["10.0.0.53"]
        )
        let specificLowPriority = DNSUpstreamSelection(
            interfaceName: "utun7",
            serviceID: "vpn-specific-low",
            servers: ["10.1.0.53"]
        )
        let specificHighPriority = DNSUpstreamSelection(
            interfaceName: "utun8",
            serviceID: "vpn-specific-high",
            servers: ["10.2.0.53"]
        )
        let snapshot = NetworkDNSSnapshot(
            interfaceName: "en0",
            serviceID: "primary",
            servers: ["192.0.2.53"],
            splitRoutes: [
                SplitDNSRoute(domain: "example", matchOrder: 1, upstream: broad),
                SplitDNSRoute(domain: "corp.example", matchOrder: 200, upstream: specificLowPriority),
                SplitDNSRoute(domain: "corp.example", matchOrder: 100, upstream: specificHighPriority),
            ]
        )

        XCTAssertEqual(snapshot.upstream(for: "api.corp.example"), specificHighPriority)
        XCTAssertEqual(snapshot.upstream(for: "public.example"), broad)
        XCTAssertEqual(snapshot.upstream(for: "example.net").interfaceName, "en0")
    }

    func testDNSDiscoveryFallsBackFromDHCPToServiceThenGlobal() {
        let state = NetworkDNSState(
            excludedServers: ["127.0.0.53", "127.0.0.1"],
            fallbackServers: []
        )

        XCTAssertEqual(
            state.selectDiscoveredServers(
                dhcpServers: ["192.0.2.53"],
                serviceServers: ["198.51.100.53"],
                globalServers: ["203.0.113.53"]
            ),
            ["192.0.2.53"]
        )
        XCTAssertEqual(
            state.selectDiscoveredServers(
                dhcpServers: [],
                serviceServers: ["198.51.100.53"],
                globalServers: ["203.0.113.53"]
            ),
            ["198.51.100.53"]
        )
        XCTAssertEqual(
            state.selectDiscoveredServers(
                dhcpServers: ["127.0.0.53"],
                serviceServers: [],
                globalServers: ["203.0.113.53", "203.0.113.53"]
            ),
            ["203.0.113.53"]
        )
    }

    func testConfigurationRejectsRecursiveEndpoint() {
        let shared = Endpoint(host: "127.0.0.1", port: 1054)
        let config = ProxyConfiguration(mihomoDNS: shared, upstreamListen: shared)
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .recursiveEndpoint)
        }
    }

    func testConfigurationJSONRoundTrip() throws {
        let config = ProxyConfiguration(
            fallbackDNSServers: ["1.1.1.1"],
            controllerEndpoint: Endpoint(host: "127.0.0.1", port: 9191),
            controllerSecret: "persistent-secret"
        )
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ProxyConfiguration.self, from: data), config)
    }

    func testConfigurationRejectsRemoteControllerAndHeaderInjection() {
        XCTAssertThrowsError(try ProxyConfiguration(
            controllerEndpoint: Endpoint(host: "192.0.2.1", port: 9090)
        ).validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidControllerEndpoint)
        }
        XCTAssertThrowsError(try ProxyConfiguration(
            controllerSecret: "secret\r\nInjected: true"
        ).validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidControllerSecret)
        }
    }

    func testExistingLoopbackAliasIsIgnored() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let manager = LoopbackAliasManager(
            interfaceName: "lo0",
            address: "127.0.0.1",
            netmask: "255.0.0.0",
            markerPath: marker
        )
        try manager.ensure()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testPrivilegedLoopbackAliasLifecycle() throws {
        guard ProcessInfo.processInfo.environment["MIHOMO_DNS_PRIVILEGED_TESTS"] == "1" else {
            throw XCTSkip("set MIHOMO_DNS_PRIVILEGED_TESTS=1 and run as root")
        }
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let manager = LoopbackAliasManager(
            interfaceName: "lo0",
            address: "127.0.0.253",
            netmask: "255.0.0.0",
            markerPath: marker
        )
        if try manager.isPresent() {
            throw XCTSkip("temporary loopback alias is already in use")
        }
        defer { try? manager.removeIfManaged() }

        try manager.ensure()
        XCTAssertTrue(try manager.isPresent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        try manager.ensure()
        try manager.removeIfManaged()
        XCTAssertFalse(try manager.isPresent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testGlobalDNSPreferencesApplyAndRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesPath = root.appendingPathComponent("preferences.plist").path
        let backupPath = root.appendingPathComponent("backup.plist").path
        guard let preferences = SCPreferencesCreate(
            nil,
            "dev.linsheng.mihomo.daemon.tests.seed" as CFString,
            preferencesPath as CFString
        ) else {
            return XCTFail("cannot create test preferences")
        }
        XCTAssertTrue(SCPreferencesSetValue(preferences, kSCPrefCurrentSet, "/Sets/Test" as CFString))
        let dnsPath = "/Sets/Test/Network/Global/DNS" as CFString
        let original = [kSCPropNetDNSServerAddresses as String: ["1.1.1.1"]] as CFDictionary
        XCTAssertTrue(SCPreferencesPathSetValue(preferences, dnsPath, original))
        guard SCPreferencesCommitChanges(preferences) else {
            throw XCTSkip("SCPreferences custom-file commit requires privileged SystemConfiguration access")
        }

        let manager = GlobalDNSPreferences(
            servers: ["127.0.0.53"],
            backupPath: backupPath,
            preferencesID: preferencesPath
        )
        try manager.apply()
        XCTAssertTrue(try manager.isApplied())
        SCPreferencesSynchronize(preferences)
        let managed = SCPreferencesPathGetValue(preferences, dnsPath) as? [String: Any]
        XCTAssertEqual(managed?[kSCPropNetDNSServerAddresses as String] as? [String], ["127.0.0.53"])

        try manager.apply()
        try manager.restore()
        SCPreferencesSynchronize(preferences)
        let restored = SCPreferencesPathGetValue(preferences, dnsPath) as? [String: Any]
        XCTAssertEqual(restored?[kSCPropNetDNSServerAddresses as String] as? [String], ["1.1.1.1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
    }

    func testDNSPreferencesTargetsPrimaryServiceAndRestoresExactly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesPath = root.appendingPathComponent("preferences.plist").path
        let backupPath = root.appendingPathComponent("backup.plist").path
        guard let preferences = SCPreferencesCreate(
            nil,
            "dev.linsheng.mihomo.daemon.tests.service-seed" as CFString,
            preferencesPath as CFString
        ) else {
            return XCTFail("cannot create test preferences")
        }
        XCTAssertTrue(SCPreferencesSetValue(preferences, kSCPrefCurrentSet, "/Sets/Test" as CFString))
        let globalPath = "/Sets/Test/Network/Global/DNS" as CFString
        let servicePath = "/Sets/Test/Network/Service/service-1/DNS" as CFString
        let global = [kSCPropNetDNSServerAddresses as String: ["9.9.9.9"]] as CFDictionary
        let service = [
            kSCPropNetDNSServerAddresses as String: ["10.0.0.53"],
            kSCPropNetDNSSearchDomains as String: ["corp.example"],
        ] as CFDictionary
        XCTAssertTrue(SCPreferencesPathSetValue(preferences, globalPath, global))
        XCTAssertTrue(SCPreferencesPathSetValue(preferences, servicePath, service))
        guard SCPreferencesCommitChanges(preferences) else {
            throw XCTSkip("SCPreferences custom-file commit requires privileged SystemConfiguration access")
        }

        let manager = GlobalDNSPreferences(
            servers: ["127.0.0.53"],
            backupPath: backupPath,
            preferencesID: preferencesPath,
            primaryServiceIDOverride: "service-1"
        )
        try manager.apply()
        SCPreferencesSynchronize(preferences)
        let managedService = SCPreferencesPathGetValue(preferences, servicePath) as? [String: Any]
        let untouchedGlobal = SCPreferencesPathGetValue(preferences, globalPath) as? [String: Any]
        XCTAssertEqual(
            managedService?[kSCPropNetDNSServerAddresses as String] as? [String],
            ["127.0.0.53"]
        )
        XCTAssertEqual(
            managedService?[kSCPropNetDNSSearchDomains as String] as? [String],
            ["corp.example"]
        )
        XCTAssertEqual(untouchedGlobal?[kSCPropNetDNSServerAddresses as String] as? [String], ["9.9.9.9"])

        try manager.restore()
        SCPreferencesSynchronize(preferences)
        let restored = SCPreferencesPathGetValue(preferences, servicePath) as? [String: Any]
        XCTAssertEqual(restored?[kSCPropNetDNSServerAddresses as String] as? [String], ["10.0.0.53"])
        XCTAssertEqual(restored?[kSCPropNetDNSSearchDomains as String] as? [String], ["corp.example"])
    }

    func testAsyncFallbackWaitsForEveryPrimaryRequestWithoutOverflowFallback() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let firstPromise = eventLoop.makePromise(of: Data.self)
        let secondPromise = eventLoop.makePromise(of: Data.self)
        let primary = QueuedAsyncForwarder(
            futures: [firstPromise.futureResult, secondPromise.futureResult]
        )
        let fallback = StubAsyncForwarder(
            result: .success(Data(repeating: 2, count: 12))
        )
        let forwarder = FallbackAsyncDNSForwarder(primary: primary, fallback: fallback)

        let first = forwarder.forward(Data(repeating: 0, count: 12), on: eventLoop)
        let second = forwarder.forward(Data(repeating: 0, count: 12), on: eventLoop)
        XCTAssertEqual(primary.callCount, 2)
        XCTAssertEqual(fallback.callCount, 0)

        let firstResponse = Data(repeating: 3, count: 12)
        let secondResponse = Data(repeating: 4, count: 12)
        firstPromise.succeed(firstResponse)
        secondPromise.succeed(secondResponse)
        XCTAssertEqual(try first.wait(), firstResponse)
        XCTAssertEqual(try second.wait(), secondResponse)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testAsyncFallbackRunsOnlyAfterPrimaryFailure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let fallbackResponse = Data(repeating: 2, count: 12)
        let primary = StubAsyncForwarder(result: .failure(TestError.unreachable))
        let fallback = StubAsyncForwarder(result: .success(fallbackResponse))
        let forwarder = FallbackAsyncDNSForwarder(primary: primary, fallback: fallback)

        XCTAssertEqual(
            try forwarder.forward(Data(repeating: 0, count: 12), on: eventLoop).wait(),
            fallbackResponse
        )
        XCTAssertEqual(primary.callCount, 1)
        XCTAssertEqual(fallback.callCount, 1)
    }

    func testAsyncFallbackBypassesPrimaryOnlyWhenRuntimeIsUnsafe() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let fallbackResponse = Data(repeating: 2, count: 12)
        let primary = StubAsyncForwarder(result: .success(Data(repeating: 1, count: 12)))
        let fallback = StubAsyncForwarder(result: .success(fallbackResponse))
        let safetyState = NetworkSafetyState()
        let forwarder = FallbackAsyncDNSForwarder(
            primary: primary,
            fallback: fallback,
            primaryAllowed: { _ in safetyState.isRuntimeReady() }
        )

        XCTAssertEqual(
            try forwarder.forward(Data(repeating: 0, count: 12), on: eventLoop).wait(),
            fallbackResponse
        )
        XCTAssertEqual(primary.callCount, 0)
        XCTAssertEqual(fallback.callCount, 1)
    }

    func testFakeIPManagedDomainNeverFallsBackToOriginalDNS() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let primary = StubAsyncForwarder(result: .failure(TestError.unreachable))
        let fallback = StubAsyncForwarder(result: .success(Data(repeating: 2, count: 12)))
        let policy = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
          fake-ip-filter-mode: blacklist
        """)
        let forwarder = FallbackAsyncDNSForwarder(
            primary: primary,
            fallback: fallback,
            fallbackAllowed: { policy.allowsOriginalDNSFallback(for: $0) }
        )

        XCTAssertThrowsError(
            try forwarder.forward(query(for: "managed.example"), on: eventLoop).wait()
        ) { error in
            guard case DNSForwardingError.originalDNSForbidden = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(primary.callCount, 1)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testUnsafeRuntimeStillBlocksOriginalDNSForFakeIPManagedDomain() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let primary = StubAsyncForwarder(result: .success(Data(repeating: 1, count: 12)))
        let fallback = StubAsyncForwarder(result: .success(Data(repeating: 2, count: 12)))
        let policy = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
        """)
        let forwarder = FallbackAsyncDNSForwarder(
            primary: primary,
            fallback: fallback,
            primaryAllowed: { _ in false },
            fallbackAllowed: { policy.allowsOriginalDNSFallback(for: $0) }
        )

        XCTAssertThrowsError(
            try forwarder.forward(query(for: "managed.example"), on: eventLoop).wait()
        )
        XCTAssertEqual(primary.callCount, 0)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testUnsafeRuntimeHealthProbeUsesOnlyPrimaryDNS() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let primaryResponse = Data(repeating: 1, count: 12)
        let primary = StubAsyncForwarder(result: .success(primaryResponse))
        let fallback = StubAsyncForwarder(result: .success(Data(repeating: 2, count: 12)))
        let forwarder = FallbackAsyncDNSForwarder(
            primary: primary,
            fallback: fallback,
            primaryAllowed: { query in query == DNSMessage.runtimeHealthQuery },
            fallbackAllowed: { _ in false }
        )

        XCTAssertEqual(
            try forwarder.forward(DNSMessage.runtimeHealthQuery, on: eventLoop).wait(),
            primaryResponse
        )
        XCTAssertEqual(primary.callCount, 1)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testFakeIPBlacklistAllowsOriginalDNSOnlyForExplicitFilterMatches() {
        let policy = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
          fake-ip-filter:
            - localhost
            - '*.lan'
            - '+.real.example'
            - '.children.example'
            - 'xbox.*.microsoft.com'
            - 'geosite:private'
        """)

        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "localhost"))
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "router.lan"))
        XCTAssertFalse(policy.allowsOriginalDNSFallback(forDomain: "deep.router.lan"))
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "real.example"))
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "deep.real.example"))
        XCTAssertFalse(policy.allowsOriginalDNSFallback(forDomain: "children.example"))
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "a.children.example"))
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "xbox.live.microsoft.com"))
        XCTAssertFalse(policy.allowsOriginalDNSFallback(forDomain: "managed.example"))
    }

    func testFakeIPWhitelistAndRuleModesRemainFailClosedWhenAmbiguous() {
        let whitelist = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
          fake-ip-filter-mode: whitelist
          fake-ip-filter: ['+.managed.example']
        """)
        XCTAssertFalse(whitelist.allowsOriginalDNSFallback(forDomain: "managed.example"))
        XCTAssertTrue(whitelist.allowsOriginalDNSFallback(forDomain: "real.example"))

        let opaqueWhitelist = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
          fake-ip-filter-mode: whitelist
          fake-ip-filter:
            - 'rule-set:managed'
        """)
        XCTAssertFalse(opaqueWhitelist.allowsOriginalDNSFallback(forDomain: "unknown.example"))

        let ruleMode = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: fake-ip
          fake-ip-filter-mode: rule
          fake-ip-filter:
            - DOMAIN-SUFFIX,internal.example,real-ip
            - MATCH,fake-ip
        """)
        XCTAssertTrue(ruleMode.allowsOriginalDNSFallback(forDomain: "api.internal.example"))
        XCTAssertFalse(ruleMode.allowsOriginalDNSFallback(forDomain: "managed.example"))
    }

    func testNonFakeIPModeAllowsOriginalDNSFallback() {
        let policy = FakeIPDNSPolicy(yaml: """
        dns:
          enhanced-mode: redir-host
        """)
        XCTAssertTrue(policy.allowsOriginalDNSFallback(forDomain: "any.example"))
    }

    func testDNSBridgeFailureRestoresOriginalDNSWithoutRestartingMihomo() {
        var policy = DNSBridgeFailurePolicy(requiredFailures: 3)
        XCTAssertEqual(
            policy.decide(bridgeReady: false, upstreamRuntimeReady: true, networkOwned: true),
            .debounce
        )
        XCTAssertEqual(
            policy.decide(bridgeReady: false, upstreamRuntimeReady: true, networkOwned: true),
            .debounce
        )
        XCTAssertEqual(
            policy.decide(bridgeReady: false, upstreamRuntimeReady: true, networkOwned: true),
            .restoreOriginalDNS
        )
        XCTAssertEqual(
            policy.decide(bridgeReady: true, upstreamRuntimeReady: true, networkOwned: false),
            .none
        )
    }

    func testDNSBridgeFailureDoesNotActWhenMihomoRuntimeIsUnavailable() {
        var policy = DNSBridgeFailurePolicy(requiredFailures: 1)
        XCTAssertEqual(
            policy.decide(bridgeReady: false, upstreamRuntimeReady: false, networkOwned: true),
            .none
        )
    }

    func testRuntimeRecoveryPolicyStartsWaitsAndRecovers() {
        var policy = RuntimeRecoveryPolicy(graceSeconds: 8)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 10), .debounce)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 11), .debounce)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 12), .start)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 13), .wait)
        XCTAssertEqual(policy.decide(runtimeReady: true, networkOwned: true, nowNanoseconds: 14), .recovered)
        XCTAssertEqual(policy.decide(runtimeReady: true, networkOwned: true, nowNanoseconds: 15), .none)
    }

    func testRuntimeRecoveryPolicyFailsAfterGraceWindow() {
        var policy = RuntimeRecoveryPolicy(graceSeconds: 1, requiredFailures: 1)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 20), .start)
        XCTAssertEqual(
            policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 1_000_000_019),
            .wait
        )
        XCTAssertEqual(
            policy.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 1_000_000_020),
            .failed
        )
    }

    func testRuntimeRecoveryPolicyDoesNotActWithoutManagedNetwork() {
        var policy = RuntimeRecoveryPolicy(graceSeconds: 1)
        XCTAssertEqual(policy.decide(runtimeReady: false, networkOwned: false, nowNanoseconds: 1), .none)
    }

    func testPublishedHealthIsServedOnlyWhileFresh() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-\(UUID().uuidString).json")
            .path
        defer { HealthSnapshotStore.remove(at: path) }

        let health = NetworkConsistencyHealth(
            controllerReachable: true,
            tunEnabled: true,
            tunInterface: "utun4",
            fakeIPMode: true,
            fakeIPRouteReady: true,
            dnsBridgeReady: true,
            mihomoDNSReady: true,
            systemDNSManaged: true,
            networkConsistent: true
        )
        let captured = Date()
        HealthSnapshotStore.publish(HealthSnapshot(health: health, capturedAt: captured), to: path)

        XCTAssertEqual(HealthSnapshotStore.read(from: path, now: captured), health)
        XCTAssertEqual(
            HealthSnapshotStore.read(from: path, now: captured.addingTimeInterval(5)),
            health
        )
        // Past the freshness window the observer is presumed gone, and its last
        // reading describes a runtime that may no longer exist.
        XCTAssertNil(HealthSnapshotStore.read(from: path, now: captured.addingTimeInterval(7)))
        // A reading from the future is a clock change, not a fresh reading.
        XCTAssertNil(HealthSnapshotStore.read(from: path, now: captured.addingTimeInterval(-30)))
    }

    func testPublishedHealthIsAbsentWhenNothingWasWritten() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
            .path
        XCTAssertNil(HealthSnapshotStore.read(from: path))
    }

    func testDNSAcquisitionManagesOnceBridgeAnswers() {
        var policy = DNSAcquisitionPolicy()
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: false, nowNanoseconds: 1),
            .manage
        )
    }

    func testDNSAcquisitionReacquiresBridgeAfterRollbackLatch() {
        // Kernel + Mihomo DNS are healthy, but an earlier rollback removed the
        // loopback alias so the bridge no longer answers and ownership was
        // released. The observer must re-ensure the alias instead of latching
        // into passive observation (the ~76h stuck state seen in the logs).
        var policy = DNSAcquisitionPolicy()
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: false, systemDNSManaged: false, nowNanoseconds: 1),
            .reacquireBridge
        )
    }

    func testDNSAcquisitionBacksOffInsteadOfThrashingTheLoopbackAlias() {
        // Observed in the field: once taking over system DNS started failing,
        // every tick rolled back (removing the loopback alias) and the next tick
        // re-created it, so 127.0.0.53 was added and removed every ~2 seconds
        // for eight minutes. A failure must buy silence, not an immediate retry.
        var policy = DNSAcquisitionPolicy(initialBackoffSeconds: 5, maximumBackoffSeconds: 120)
        let second: UInt64 = 1_000_000_000

        XCTAssertEqual(
            policy.decide(
                upstreamRuntimeReady: true,
                dnsBridgeReady: true,
                systemDNSManaged: false,
                nowNanoseconds: second
            ),
            .manage
        )
        policy.recordManageFailed(nowNanoseconds: second)

        // The rollback left the bridge down. Without backoff this would return
        // .reacquireBridge on the very next tick and restart the cycle.
        for tick in 2 ... 5 {
            XCTAssertEqual(
                policy.decide(
                    upstreamRuntimeReady: true,
                    dnsBridgeReady: false,
                    systemDNSManaged: false,
                    nowNanoseconds: UInt64(tick) * second
                ),
                .none,
                "tick \(tick) must stay quiet during backoff"
            )
        }
        // Once the window passes it tries again, so a transient conflict still
        // recovers on its own.
        XCTAssertEqual(
            policy.decide(
                upstreamRuntimeReady: true,
                dnsBridgeReady: false,
                systemDNSManaged: false,
                nowNanoseconds: 7 * second
            ),
            .reacquireBridge
        )
    }

    func testDNSAcquisitionBackoffGrowsAndIsCapped() {
        var policy = DNSAcquisitionPolicy(initialBackoffSeconds: 5, maximumBackoffSeconds: 20)
        let second: UInt64 = 1_000_000_000
        policy.recordManageFailed(nowNanoseconds: 0)
        // 5s window.
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: false, nowNanoseconds: 4 * second),
            .none
        )
        policy.recordManageFailed(nowNanoseconds: 0)
        // 10s window now.
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: false, nowNanoseconds: 9 * second),
            .none
        )
        // Keep failing; the delay must saturate at the cap rather than overflow.
        for _ in 0 ..< 40 {
            policy.recordManageFailed(nowNanoseconds: 0)
        }
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: false, nowNanoseconds: 19 * second),
            .none
        )
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: false, nowNanoseconds: 21 * second),
            .manage
        )
    }

    func testDNSAcquisitionSuccessClearsBackoff() {
        var policy = DNSAcquisitionPolicy(initialBackoffSeconds: 60)
        policy.recordManageFailed(nowNanoseconds: 0)
        policy.recordManageSucceeded()
        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(
            policy.decide(
                upstreamRuntimeReady: true,
                dnsBridgeReady: true,
                systemDNSManaged: false,
                nowNanoseconds: 1
            ),
            .manage
        )
    }

    func testDNSAcquisitionMaintainsAliasWhileManaged() {
        var policy = DNSAcquisitionPolicy()
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: true, systemDNSManaged: true, nowNanoseconds: 1),
            .maintain
        )
    }

    func testDNSAcquisitionYieldsToBridgeFailurePolicyWhenManagedBridgeDrops() {
        // Managed but the bridge dropped: acquisition stays idle so the
        // dedicated bridge-failure policy owns the restore decision.
        var policy = DNSAcquisitionPolicy()
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: true, dnsBridgeReady: false, systemDNSManaged: true, nowNanoseconds: 1),
            .none
        )
    }

    func testEgressProbeIntervalGatesProbingAndWakeForcesIt() {
        var policy = EgressProbePolicy(intervalSeconds: 60)
        let second: UInt64 = 1_000_000_000
        XCTAssertTrue(policy.isProbeDue(nowNanoseconds: 10 * second, forced: false))
        policy.noteProbeStarted(nowNanoseconds: 10 * second)
        // Inside the interval a second probe must not be spent.
        XCTAssertFalse(policy.isProbeDue(nowNanoseconds: 40 * second, forced: false))
        // A wake forces one regardless of how recently we probed.
        XCTAssertTrue(policy.isProbeDue(nowNanoseconds: 41 * second, forced: true))
        policy.noteProbeStarted(nowNanoseconds: 41 * second)
        XCTAssertFalse(policy.isProbeDue(nowNanoseconds: 60 * second, forced: false))
        XCTAssertTrue(policy.isProbeDue(nowNanoseconds: 101 * second, forced: false))
    }

    func testCountingPoliciesAreCallCountersSoOffTickEvaluationsMustNotChargeThem() {
        // Pins the invariant behind evaluate(chargeFailures:). Both policies
        // count *calls*, not elapsed time: their ~6-second debounce exists only
        // because the 2-second timer used to be the sole caller. Now that wakes
        // and SystemConfiguration changes also drive evaluations, charging them
        // would satisfy the threshold instantly and restart the kernel.
        var runtime = RuntimeRecoveryPolicy(graceSeconds: 8, requiredFailures: 3)
        // Three calls at the *same* instant still reach .start — there is no
        // time gate to save us.
        XCTAssertEqual(runtime.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 1), .debounce)
        XCTAssertEqual(runtime.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 1), .debounce)
        XCTAssertEqual(runtime.decide(runtimeReady: false, networkOwned: true, nowNanoseconds: 1), .start)

        var bridge = DNSBridgeFailurePolicy(requiredFailures: 3)
        for _ in 0 ..< 2 {
            XCTAssertEqual(
                bridge.decide(bridgeReady: false, upstreamRuntimeReady: true, networkOwned: true),
                .debounce
            )
        }
        XCTAssertEqual(
            bridge.decide(bridgeReady: false, upstreamRuntimeReady: true, networkOwned: true),
            .restoreOriginalDNS
        )
    }

    func testEgressProbeDueStaysSetUntilAProbeActuallyStarts() {
        // A probe that was dropped (one already in flight) must not consume the
        // interval, otherwise the post-wake revalidation is silently skipped.
        var policy = EgressProbePolicy(intervalSeconds: 60)
        let second: UInt64 = 1_000_000_000
        XCTAssertTrue(policy.isProbeDue(nowNanoseconds: 10 * second, forced: false))
        // Caller did not call noteProbeStarted because schedule() returned false.
        XCTAssertTrue(policy.isProbeDue(nowNanoseconds: 11 * second, forced: false))
    }

    func testEgressReadingSequenceAdvancesOnlyOnNewResults() {
        // Regression guard for the defect where the 2s consistency tick folded
        // the same cached probe result repeatedly, reaching the failure
        // threshold off a single probe within seconds.
        let coordinator = EgressProbeCoordinator(
            configuration: ProxyConfiguration(),
            probe: { _ in .unreachable }
        )
        let initial = coordinator.latest()
        XCTAssertEqual(initial.outcome, .unknown)

        let published = expectation(description: "probe published")
        XCTAssertTrue(coordinator.schedule { _ in published.fulfill() })
        wait(for: [published], timeout: 2)

        let first = coordinator.latest()
        XCTAssertEqual(first.outcome, .unreachable)
        XCTAssertNotEqual(first.sequence, initial.sequence)
        // Reading again without a new probe must report the same sequence, so a
        // caller can tell it has already acted on this result.
        XCTAssertEqual(coordinator.latest(), first)
        XCTAssertEqual(coordinator.latest(), first)

        // Invalidation is itself a new observation (the old one is gone).
        coordinator.invalidate()
        let cleared = coordinator.latest()
        XCTAssertEqual(cleared.outcome, .unknown)
        XCTAssertNotEqual(cleared.sequence, first.sequence)
    }

    func testEgressSingleFailedProbeCannotReachRecoveryThreshold() {
        // Drive the policy the way the consistency tick does: many ticks per
        // probe. With one failed probe folded once, recovery must not trigger.
        var policy = EgressProbePolicy(intervalSeconds: 60, requiredFailures: 3)
        let second: UInt64 = 1_000_000_000
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: second),
            .none
        )
        // One failed probe, folded exactly once.
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 61 * second),
            .debounce
        )
        // 29 further ticks occur before the next probe; none of them may fold a
        // result, so the policy state must be untouched.
        XCTAssertEqual(policy.consecutiveFailures, 1)
    }

    func testEgressProbeCoordinatorDropsConcurrentScheduleRequest() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let coordinator = EgressProbeCoordinator(
            configuration: ProxyConfiguration(),
            probe: { _ in
                started.signal()
                release.wait()
                return .reachable
            }
        )
        XCTAssertTrue(coordinator.schedule())
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // A second request while one is in flight is refused, and the caller
        // learns about it so it can retry rather than lose the request.
        XCTAssertFalse(coordinator.schedule())
        release.signal()
    }

    func testEgressProbeRecoversOnlyAfterSustainedFailure() {
        var policy = EgressProbePolicy(requiredFailures: 3)
        // Egress must have worked at least once for a failure to count as a
        // regression.
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: 1),
            .none
        )
        for _ in 0 ..< 2 {
            XCTAssertEqual(
                policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 2),
                .debounce
            )
        }
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 3),
            .sustainedFailure
        )
    }

    func testEgressProbeNeverRecoversWhenPathNeverWorked() {
        // Offline machine or a genuinely dead proxy: every local signal reads
        // healthy, but restarting the runtime cannot help, so we must stay put
        // no matter how long it keeps failing.
        var policy = EgressProbePolicy(requiredFailures: 1)
        for tick in 1 ... 50 {
            XCTAssertEqual(
                policy.decide(
                    outcome: .unreachable,
                    runtimeReady: true,
                    nowNanoseconds: UInt64(tick) * 1_000_000_000
                ),
                .none
            )
        }
        XCTAssertFalse(policy.observedReachable)
    }

    func testEgressProbeRequiresFreshSuccessBeforeRecoveringAgain() {
        // After one recovery the new runtime must prove egress works before
        // another restart can be triggered — this is what forecloses a restart
        // loop, independently of the cooldown.
        var policy = EgressProbePolicy(cooldownSeconds: 600, requiredFailures: 1)
        let second: UInt64 = 1_000_000_000
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: second),
            .none
        )
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 2 * second),
            .sustainedFailure
        )
        // Still broken after the restart, and well past the cooldown: no second
        // restart, because egress never came back.
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 900 * second),
            .none
        )
        // It works again, then regresses: now a restart is justified once more.
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: 910 * second),
            .none
        )
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 1_000 * second),
            .sustainedFailure
        )
    }

    func testEgressProbeCooldownHoldsAfterRecovery() {
        var policy = EgressProbePolicy(cooldownSeconds: 600, requiredFailures: 1)
        let second: UInt64 = 1_000_000_000
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: second),
            .none
        )
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: second),
            .sustainedFailure
        )
        // Egress recovers and regresses again inside the cooldown window.
        XCTAssertEqual(
            policy.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: 100 * second),
            .none
        )
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 300 * second),
            .debounce
        )
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 602 * second),
            .sustainedFailure
        )
    }

    func testEgressProbeIgnoresUnknownAndUnhealthyRuntime() {
        var policy = EgressProbePolicy(requiredFailures: 1)
        // No probe result yet, or no real outbound proxy selected.
        XCTAssertEqual(
            policy.decide(outcome: .unknown, runtimeReady: true, nowNanoseconds: 1),
            .none
        )
        // The rest of the runtime is already broken; other policies own that.
        XCTAssertEqual(
            policy.decide(outcome: .unreachable, runtimeReady: false, nowNanoseconds: 2),
            .none
        )
        // A success clears accumulated failures.
        var recovering = EgressProbePolicy(requiredFailures: 2)
        XCTAssertEqual(
            recovering.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: 0),
            .none
        )
        XCTAssertEqual(
            recovering.decide(outcome: .unreachable, runtimeReady: true, nowNanoseconds: 1),
            .debounce
        )
        XCTAssertEqual(
            recovering.decide(outcome: .reachable, runtimeReady: true, nowNanoseconds: 2),
            .none
        )
        XCTAssertEqual(recovering.consecutiveFailures, 0)
    }

    func testEgressProbeCoordinatorPublishesResultAndInvalidateDropsIt() {
        let configuration = ProxyConfiguration()
        let coordinator = EgressProbeCoordinator(
            configuration: configuration,
            probe: { _ in .unreachable }
        )
        XCTAssertEqual(coordinator.latest().outcome, .unknown)

        let published = expectation(description: "probe published")
        coordinator.schedule { _ in published.fulfill() }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(coordinator.latest().outcome, .unreachable)

        // Across a sleep boundary the old measurement no longer describes the
        // current network.
        coordinator.invalidate()
        XCTAssertEqual(coordinator.latest().outcome, .unknown)
    }

    func testEgressProbeCoordinatorDiscardsResultRacingAnInvalidate() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let coordinator = EgressProbeCoordinator(
            configuration: ProxyConfiguration(),
            probe: { _ in
                started.signal()
                release.wait()
                return .reachable
            }
        )
        coordinator.schedule()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // Invalidate while the probe is still running: its result describes a
        // network that no longer exists and must not be published.
        coordinator.invalidate()
        release.signal()
        // Give the probe queue a chance to complete before asserting.
        let settled = expectation(description: "probe settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(coordinator.latest().outcome, .unknown)
    }

    func testDNSAcquisitionIdleWhenKernelRuntimeUnavailable() {
        var policy = DNSAcquisitionPolicy()
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: false, dnsBridgeReady: false, systemDNSManaged: false, nowNanoseconds: 1),
            .none
        )
        XCTAssertEqual(
            policy.decide(upstreamRuntimeReady: false, dnsBridgeReady: true, systemDNSManaged: true, nowNanoseconds: 1),
            .none
        )
    }

    func testRotatingFileWriterCapsEachGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("service.log").path
        let writer = RotatingFileWriter(path: path, maximumFileBytes: 10, retainedFiles: 2)

        XCTAssertTrue(writer.append(Data(repeating: 1, count: 7)))
        XCTAssertTrue(writer.append(Data(repeating: 2, count: 7)))
        XCTAssertTrue(writer.flush())

        let current = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
        let rotated = try FileManager.default.attributesOfItem(atPath: "\(path).1")[.size] as? NSNumber
        XCTAssertEqual(current?.intValue, 4)
        XCTAssertEqual(rotated?.intValue, 10)
    }

    func testRestartBackoffIsExponentialAndOpensCircuit() {
        var policy = RestartBackoffPolicy(
            baseDelayMilliseconds: 100,
            maximumDelayMilliseconds: 250,
            maximumFailures: 4,
            stableRuntimeMilliseconds: 1_000
        )

        XCTAssertEqual(policy.recordFailure(runtimeMilliseconds: 0), .retry(delayMilliseconds: 100, failures: 1))
        XCTAssertEqual(policy.recordFailure(runtimeMilliseconds: 0), .retry(delayMilliseconds: 200, failures: 2))
        XCTAssertEqual(policy.recordFailure(runtimeMilliseconds: 0), .retry(delayMilliseconds: 250, failures: 3))
        XCTAssertEqual(policy.recordFailure(runtimeMilliseconds: 0), .open(failures: 4))
        XCTAssertEqual(policy.recordFailure(runtimeMilliseconds: 1_000), .retry(delayMilliseconds: 100, failures: 1))
    }

    func testSanitizedProcessLogNeverPersistsRawContent() throws {
        let accumulator = SanitizedProcessLogAccumulator(maximumLines: 2)
        let message =
            "level=warning url=https://secret.example/sub?token=credential\n" +
            "level=error domain=private.example\n"
        let raw = Data(message.utf8)

        let summary = try XCTUnwrap(accumulator.ingest(raw))
        let text = try XCTUnwrap(String(data: summary, encoding: .utf8))
        XCTAssertTrue(text.contains("event=mihomo_output_summary"))
        XCTAssertTrue(text.contains("lines=2"))
        XCTAssertTrue(text.contains("warning=1"))
        XCTAssertTrue(text.contains("error=1"))
        XCTAssertFalse(text.contains("secret.example"))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("private.example"))
    }

    func testSanitizedProcessLogMigrationRemovesLegacyGenerationsOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("mihomo.log").path
        for candidate in [path, "\(path).1", "\(path).2", "\(path).3"] {
            try Data("domain=legacy.example\n".utf8).write(to: URL(fileURLWithPath: candidate))
        }

        try SanitizedProcessLogMigration.prepare(logPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path).sanitized-v1"))

        try Data("event=mihomo_output_summary\n".utf8).write(to: URL(fileURLWithPath: path))
        try SanitizedProcessLogMigration.prepare(logPath: path)
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            "event=mihomo_output_summary\n"
        )
    }
}

private func query(for domain: String) -> Data {
    var data = Data([
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
    for label in domain.split(separator: ".") {
        data.append(UInt8(label.utf8.count))
        data.append(contentsOf: label.utf8)
    }
    data.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
    return data
}

private enum TestError: Error {
    case unreachable
}

private final class StubAsyncForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Data, Error>
    private var calls = 0

    init(result: Result<Data, Error>) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        lock.lock()
        calls += 1
        lock.unlock()
        return eventLoop.makeFutureWithTask { try self.result.get() }
    }
}

private final class QueuedAsyncForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var futures: [EventLoopFuture<Data>]
    private var calls = 0

    init(futures: [EventLoopFuture<Data>]) {
        self.futures = futures
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return futures.removeFirst()
    }
}
