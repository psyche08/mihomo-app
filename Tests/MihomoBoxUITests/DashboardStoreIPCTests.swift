import Foundation
import XCTest

@testable import MihomoBoxUI

@MainActor
final class DashboardStoreIPCTests: XCTestCase {
  func testVisibleStoreLoadsOnlyTheActivePageAndItsIPCStreams() async throws {
    let gateway = FakeDashboardGateway()
    let store = DashboardStore(gateway: gateway)

    store.setVisible(true)
    store.start()

    try await eventually {
      store.runtimeStatus == .connected
        && store.proxyGroups.first?.selectedNode == "Node A"
        && store.activeConnections.first?.host == "example.com"
        && store.traffic.downloadSpeed == 8_000
        && store.traffic.memoryBytes == 64_000_000
    }

    let calls = gateway.calls
    for expected in [
      "fetchVersion", "fetchSnapshot", "stream.connections", "stream.traffic", "stream.memory",
    ] {
      XCTAssertTrue(calls.contains(expected), "missing dashboard IPC call: \(expected)")
    }
    for unexpected in [
      "fetchConfig", "fetchProxies", "fetchProxyProviders", "fetchRules",
      "fetchRuleProviders", "fetchConnections", "stream.logs.debug",
    ] {
      XCTAssertFalse(calls.contains(unexpected), "inactive page made IPC call: \(unexpected)")
    }
    XCTAssertEqual(store.coreVersion, "Mihomo v-test")
    XCTAssertTrue(store.configuration.enhancedTUNEnabled)
    XCTAssertEqual(store.configuration.logLevel, .info)
    XCTAssertFalse(store.configuration.tcpConcurrent)
    XCTAssertEqual(store.configuration.findProcessMode, .strict)

    store.setActivePage(.logs)
    try await eventually {
      store.logs.first?.message == "controller warning" && gateway.cancelledStreams == 3
    }
    XCTAssertTrue(gateway.calls.contains("stream.logs.debug"))

    store.setActivePage(.proxies)
    try await eventually {
      gateway.calls.contains("fetchProxyProviders") && gateway.cancelledStreams == 4
    }

    store.stop()
    XCTAssertEqual(gateway.cancelledStreams, 4)
  }

  func testDashboardControlsCallGatewayAndUseAuthoritativeReadback() async throws {
    let gateway = FakeDashboardGateway()
    let store = DashboardStore(gateway: gateway)

    await store.refresh(.proxies)
    await store.refresh(.rules)
    await store.refresh(.connections)
    await store.refresh(.config)

    await store.selectProxy(group: "Auto", node: "Node B")
    await store.setRuleEnabled("7", enabled: false)
    _ = await store.closeConnection("connection-1")
    await store.setAllowLANEnabled(true)
    await store.setCoreLogLevel(.debug)
    await store.setTCPConcurrentEnabled(true)
    await store.setFindProcessMode(.always)
    await store.flushDNSCache()

    let calls = gateway.calls
    XCTAssertTrue(calls.contains("selectProxy:Auto:Node B"))
    XCTAssertTrue(calls.contains("setRuleDisabled:7:true"))
    XCTAssertTrue(calls.contains("closeConnection:connection-1"))
    XCTAssertGreaterThanOrEqual(calls.filter { $0 == "fetchConnections" }.count, 2)
    XCTAssertTrue(calls.contains("patchConfig:allowLAN:true"))
    XCTAssertTrue(calls.contains("patchConfig:logLevel:debug"))
    XCTAssertTrue(calls.contains("patchConfig:tcpConcurrent:true"))
    XCTAssertTrue(calls.contains("patchConfig:findProcessMode:always"))
    for patchCall in [
      "patchConfig:allowLAN:true",
      "patchConfig:logLevel:debug",
      "patchConfig:tcpConcurrent:true",
      "patchConfig:findProcessMode:always",
    ] {
      let index = try XCTUnwrap(calls.firstIndex(of: patchCall))
      let readbackIndex = calls.index(after: index)
      XCTAssertLessThan(readbackIndex, calls.endIndex)
      XCTAssertEqual(calls[readbackIndex], "fetchConfig")
    }
    XCTAssertTrue(calls.contains("flushDNSCache"))
    XCTAssertTrue(store.activeConnections.isEmpty)
    XCTAssertEqual(store.proxyGroups.first?.selectedNode, "Node B")
    XCTAssertEqual(store.rules.first?.isEnabled, false)
    XCTAssertTrue(store.configuration.allowLAN)
    XCTAssertEqual(store.configuration.logLevel, .debug)
    XCTAssertTrue(store.configuration.tcpConcurrent)
    XCTAssertEqual(store.configuration.findProcessMode, .always)
  }

  func testPreviewModeNeverTouchesTheIPCGateway() async {
    let gateway = FakeDashboardGateway()
    let store = DashboardStore(gateway: gateway, previewMode: true)

    store.setVisible(true)
    store.start()
    await store.refresh(.proxies)
    await store.selectProxy(group: "Auto", node: "Tokyo · 01")

    XCTAssertTrue(gateway.calls.isEmpty)
    XCTAssertEqual(store.runtimeStatus, .connected)
    XCTAssertFalse(store.proxyGroups.isEmpty)
  }

  func testMutationFailureIsVisibleAndDoesNotChangeControllerDerivedState() async {
    let gateway = FakeDashboardGateway(failCloseConnection: true)
    let store = DashboardStore(gateway: gateway)
    await store.refresh(.connections)

    let succeeded = await store.closeConnection("connection-1")

    XCTAssertFalse(succeeded)
    XCTAssertEqual(store.activeConnections.map(\.id), ["connection-1"])
    XCTAssertTrue(store.actionError?.contains("Action failed") == true)
    store.dismissActionError()
    XCTAssertNil(store.actionError)
  }

  func testConnectionCloseRequiresAuthoritativeAbsenceOnReadback() async {
    let gateway = FakeDashboardGateway(retainConnectionAfterClose: true)
    let store = DashboardStore(gateway: gateway)
    await store.refresh(.connections)

    let succeeded = await store.closeConnection("connection-1")

    XCTAssertFalse(succeeded)
    XCTAssertEqual(store.activeConnections.map(\.id), ["connection-1"])
    XCTAssertTrue(store.actionError?.contains("still reports this connection") == true)
    XCTAssertEqual(
      Array(gateway.calls.suffix(2)),
      ["closeConnection:connection-1", "fetchConnections"]
    )
  }

  private func eventually(
    timeout: TimeInterval = 2,
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline {
        XCTFail("condition was not met before timeout")
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private final class FakeDashboardGateway: DashboardControlGateway, @unchecked Sendable {
  private let lock = NSLock()
  private let failCloseConnection: Bool
  private let retainConnectionAfterClose: Bool
  private var recordedCalls: [String] = []
  private var streamCancellationCount = 0
  private var selectedProxy = "Node A"
  private var ruleDisabled = false
  private var config = ControllerConfig(
    mode: "rule",
    port: 7890,
    socksPort: 7891,
    mixedPort: 7893,
    tun: ControllerTUNConfig(enable: true, stack: "mixed"),
    allowLAN: false,
    unifiedDelay: true,
    logLevel: "info",
    ipv6: false,
    interfaceName: "en0",
    tcpConcurrent: false,
    findProcessMode: "strict"
  )
  private var connections = ControllerConnectionsFrame(
    connections: [
      ControllerConnection(
        id: "connection-1",
        download: 2_048,
        upload: 1_024,
        chains: ["Node A"],
        rule: "DOMAIN-SUFFIX",
        rulePayload: "example.com",
        start: "2026-08-11T00:00:00Z",
        metadata: ControllerConnectionMetadata(
          network: "tcp",
          destinationIP: "203.0.113.1",
          destinationPort: "443",
          host: "example.com",
          sourceIP: "127.0.0.1",
          sourcePort: "52100"
        )
      )
    ],
    uploadTotal: 4_096,
    downloadTotal: 8_192
  )

  init(
    failCloseConnection: Bool = false,
    retainConnectionAfterClose: Bool = false
  ) {
    self.failCloseConnection = failCloseConnection
    self.retainConnectionAfterClose = retainConnectionAfterClose
  }

  var calls: [String] {
    lock.withLock { recordedCalls }
  }

  var cancelledStreams: Int {
    lock.withLock { streamCancellationCount }
  }

  func fetchVersion() async throws -> ControllerVersion {
    record("fetchVersion")
    return ControllerVersion(meta: true, version: "v-test")
  }

  func fetchSnapshot() async throws -> ControllerSnapshot {
    record("fetchSnapshot")
    return snapshot()
  }

  func fetchConfig() async throws -> ControllerConfig {
    record("fetchConfig")
    return lock.withLock { config }
  }

  func fetchProxies() async throws -> ControllerProxyCatalog {
    record("fetchProxies")
    return proxyCatalog()
  }

  func fetchProxyProviders() async throws -> ControllerProxyProviderCatalog {
    record("fetchProxyProviders")
    return ControllerProxyProviderCatalog(
      providers: [
        "Subscription": ControllerProxyProvider(
          name: "Subscription",
          proxies: [ControllerProxy(name: "Node A", type: "VLESS", alive: true)],
          updatedAt: "2026-08-11T00:00:00Z",
          vehicleType: "HTTP"
        )
      ]
    )
  }

  func fetchRules() async throws -> ControllerRuleCatalog {
    record("fetchRules")
    let disabled = lock.withLock { ruleDisabled }
    return ControllerRuleCatalog(
      rules: [
        ControllerRule(
          index: 7,
          type: "DOMAIN-SUFFIX",
          payload: "example.com",
          proxy: "Auto",
          extra: ControllerRuleExtra(disabled: disabled)
        )
      ]
    )
  }

  func fetchRuleProviders() async throws -> ControllerRuleProviderCatalog {
    record("fetchRuleProviders")
    return ControllerRuleProviderCatalog(
      providers: [
        "Private": ControllerRuleProvider(
          behavior: "domain",
          format: "mrs",
          name: "Private",
          ruleCount: 1,
          type: "Rule",
          vehicleType: "HTTP"
        )
      ]
    )
  }

  func fetchConnections() async throws -> ControllerConnectionsFrame {
    record("fetchConnections")
    return lock.withLock { connections }
  }

  func applyOutboundMode(_ mode: ControllerOutboundMode) async throws -> ControllerSnapshot {
    record("applyOutboundMode:\(mode.rawValue)")
    lock.withLock { config.mode = mode.rawValue }
    return snapshot()
  }

  func patchConfig(_ patch: RuntimeConfigPatch) async throws {
    switch patch {
    case .allowLAN(let value):
      record("patchConfig:allowLAN:\(value)")
      lock.withLock { config.allowLAN = value }
    case .ipv6(let value):
      record("patchConfig:ipv6:\(value)")
      lock.withLock { config.ipv6 = value }
    case .logLevel(let value):
      record("patchConfig:logLevel:\(value.rawValue)")
      lock.withLock { config.logLevel = value.rawValue }
    case .unifiedDelay(let value):
      record("patchConfig:unifiedDelay:\(value)")
      lock.withLock { config.unifiedDelay = value }
    case .tcpConcurrent(let value):
      record("patchConfig:tcpConcurrent:\(value)")
      lock.withLock { config.tcpConcurrent = value }
    case .findProcessMode(let value):
      record("patchConfig:findProcessMode:\(value.rawValue)")
      lock.withLock { config.findProcessMode = value.rawValue }
    }
  }

  func selectProxy(group: String, proxy: String) async throws {
    record("selectProxy:\(group):\(proxy)")
    lock.withLock { selectedProxy = proxy }
  }

  func testProxyGroupDelay(
    group: String,
    timeoutMilliseconds: Int
  ) async throws -> [String: Int] {
    record("testProxyGroupDelay:\(group):\(timeoutMilliseconds)")
    return ["Node A": 42]
  }

  func refreshProxyProvider(_ name: String) async throws {
    record("refreshProxyProvider:\(name)")
  }

  func testProxyProvider(_ name: String) async throws -> [String: Int] {
    record("testProxyProvider:\(name)")
    return ["Node A": 42]
  }

  func refreshRuleProvider(_ name: String) async throws {
    record("refreshRuleProvider:\(name)")
  }

  func setRuleDisabled(index: Int, disabled: Bool) async throws {
    record("setRuleDisabled:\(index):\(disabled)")
    lock.withLock { ruleDisabled = disabled }
  }

  func closeConnection(id: String) async throws {
    record("closeConnection:\(id)")
    if failCloseConnection {
      throw NSError(
        domain: "DashboardStoreIPCTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "controller refused close"]
      )
    }
    if !retainConnectionAfterClose {
      lock.withLock {
        connections.connections.removeAll { $0.id == id }
      }
    }
  }

  func closeAllConnections() async throws {
    record("closeAllConnections")
    lock.withLock { connections.connections.removeAll() }
  }

  func flushFakeIPCache() async throws { record("flushFakeIPCache") }
  func flushDNSCache() async throws { record("flushDNSCache") }
  func updateGeoData() async throws { record("updateGeoData") }
  func reloadActiveProfile() async throws { record("reloadActiveProfile") }
  func restartAgent() async throws { record("restartAgent") }

  func connectionsStream() -> AsyncThrowingStream<ControllerConnectionsFrame, Error> {
    makeStream(name: "connections", value: lock.withLock { connections })
  }

  func trafficStream() -> AsyncThrowingStream<ControllerTrafficFrame, Error> {
    makeStream(name: "traffic", value: ControllerTrafficFrame(up: 2_000, down: 8_000))
  }

  func memoryStream() -> AsyncThrowingStream<ControllerMemoryFrame, Error> {
    makeStream(name: "memory", value: ControllerMemoryFrame(inuse: 64_000_000))
  }

  func logsStream(
    level: ControllerLogLevel
  ) -> AsyncThrowingStream<ControllerLogFrame, Error> {
    makeStream(
      name: "logs.\(level.rawValue)",
      value: ControllerLogFrame(type: "warning", payload: "controller warning")
    )
  }

  private func snapshot() -> ControllerSnapshot {
    ControllerSnapshot(configs: lock.withLock { config }, proxies: proxyCatalog())
  }

  private func proxyCatalog() -> ControllerProxyCatalog {
    let selected = lock.withLock { selectedProxy }
    return ControllerProxyCatalog(
      proxies: [
        "Auto": ControllerProxy(
          name: "Auto",
          type: "Selector",
          all: ["Node A", "Node B"],
          now: selected
        ),
        "Node A": ControllerProxy(
          name: "Node A",
          type: "VLESS",
          history: [ControllerDelayHistory(delay: 42)],
          alive: true,
          udp: true
        ),
        "Node B": ControllerProxy(
          name: "Node B",
          type: "VLESS",
          history: [ControllerDelayHistory(delay: 55)],
          alive: true,
          udp: true
        ),
      ]
    )
  }

  private func makeStream<Value: Sendable>(
    name: String,
    value: Value
  ) -> AsyncThrowingStream<Value, Error> {
    record("stream.\(name)")
    return AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock { self?.streamCancellationCount += 1 }
      }
      continuation.yield(value)
    }
  }

  private func record(_ call: String) {
    lock.withLock { recordedCalls.append(call) }
  }
}
