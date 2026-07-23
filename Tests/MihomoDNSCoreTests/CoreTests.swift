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
