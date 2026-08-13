import Foundation
import SwiftUI

/// The fixed controller surface consumed by the dashboard state model.
///
/// Production uses ``ControlGateway``, whose implementation crosses the signed
/// XPC boundary. Keeping this protocol internal lets tests prove that page
/// loads, streams, mutations and authoritative readbacks are wired to that
/// gateway without exposing a raw controller transport to SwiftUI views.
protocol DashboardControlGateway: Sendable {
  func fetchVersion() async throws -> ControllerVersion
  func fetchSnapshot() async throws -> ControllerSnapshot
  func fetchConfig() async throws -> ControllerConfig
  func fetchProxies() async throws -> ControllerProxyCatalog
  func fetchProxyProviders() async throws -> ControllerProxyProviderCatalog
  func fetchRules() async throws -> ControllerRuleCatalog
  func fetchRuleProviders() async throws -> ControllerRuleProviderCatalog
  func fetchConnections() async throws -> ControllerConnectionsFrame
  func applyOutboundMode(_ mode: ControllerOutboundMode) async throws -> ControllerSnapshot
  func patchConfig(_ patch: RuntimeConfigPatch) async throws
  func selectProxy(group: String, proxy: String) async throws
  func testProxyGroupDelay(
    group: String,
    timeoutMilliseconds: Int
  ) async throws -> [String: Int]
  func refreshProxyProvider(_ name: String) async throws
  func testProxyProvider(_ name: String) async throws -> [String: Int]
  func refreshRuleProvider(_ name: String) async throws
  func setRuleDisabled(index: Int, disabled: Bool) async throws
  func closeConnection(id: String) async throws
  func closeAllConnections() async throws
  func flushFakeIPCache() async throws
  func flushDNSCache() async throws
  func updateGeoData() async throws
  func reloadActiveProfile() async throws
  func restartAgent() async throws
  func connectionsStream() -> AsyncThrowingStream<ControllerConnectionsFrame, Error>
  func trafficStream() -> AsyncThrowingStream<ControllerTrafficFrame, Error>
  func memoryStream() -> AsyncThrowingStream<ControllerMemoryFrame, Error>
  func logsStream(
    level: ControllerLogLevel
  ) -> AsyncThrowingStream<ControllerLogFrame, Error>
}

extension ControlGateway: DashboardControlGateway {}

/// Main-actor state for the native dashboard.
///
/// Host, connection and controller-log details are intentionally session-only.
/// The store never writes them to UserDefaults, files or unified logging.
@MainActor
public final class DashboardStore: ObservableObject {
  public static let shared = DashboardStore()

  private enum StreamKind: Hashable {
    case connections
    case traffic
    case memory
    case logs
  }

  private enum ActionValidationError: LocalizedError {
    case connectionStillActive

    var errorDescription: String? {
      switch self {
      case .connectionStillActive:
        "the controller still reports this connection as active"
      }
    }
  }

  private static let maximumTrendPoints = 120
  private static let maximumClosedConnections = 500
  private static let maximumLogs = 500

  @Published public private(set) var overviewState: DashboardLoadState = .loading
  @Published public private(set) var proxiesState: DashboardLoadState = .loading
  @Published public private(set) var rulesState: DashboardLoadState = .loading
  @Published public private(set) var connectionsState: DashboardLoadState = .loading
  @Published public private(set) var usageState: DashboardLoadState = .loading
  @Published public private(set) var logsState: DashboardLoadState = .loading
  @Published public private(set) var configState: DashboardLoadState = .loading

  @Published public private(set) var runtimeStatus: DashboardRuntimeStatus = .disconnected
  @Published public private(set) var runtimeMessage = "Waiting for Mihomo"
  @Published public private(set) var actionError: String?
  @Published public private(set) var coreVersion = "Mihomo"
  @Published public private(set) var traffic = TrafficSnapshot()
  @Published public private(set) var trafficHistory: [TrafficPoint] = []
  @Published public private(set) var memoryHistory: [MetricPoint] = []
  @Published public private(set) var connectionHistory: [MetricPoint] = []

  @Published public private(set) var proxyGroups: [ProxyGroup] = []
  @Published public private(set) var proxyProviders: [ProxyProvider] = []
  @Published public private(set) var rules: [DashboardRule] = []
  @Published public private(set) var ruleProviders: [RuleProvider] = []
  @Published public private(set) var activeConnections: [DashboardConnection] = []
  @Published public private(set) var closedConnections: [DashboardConnection] = []
  @Published public private(set) var usageRows: [UsageRow] = []
  @Published public private(set) var usageHistory: [TrafficPoint] = []
  @Published public private(set) var logs: [DashboardLogEntry] = []
  @Published public private(set) var configuration = DashboardConfiguration()

  @Published public private(set) var usageDimension: UsageDimension = .device
  @Published public private(set) var usageRange: UsageRange = .day
  @Published public private(set) var logLevel: DashboardLogLevel = .all
  @Published public private(set) var connectionsPaused = false
  @Published public private(set) var logsPaused = false
  @Published public private(set) var isVisible = false
  @Published public private(set) var isStarted = false

  private let gateway: any DashboardControlGateway
  private let previewMode: Bool
  private var streamTasks: [StreamKind: Task<Void, Never>] = [:]
  private var streamRetryTasks: [StreamKind: Task<Void, Never>] = [:]
  private var streamRetryCounts: [StreamKind: Int] = [:]
  private var healthyStreams: Set<StreamKind> = []
  private var streamFailures: [StreamKind: String] = [:]
  private var refreshTasks: [DashboardPage: Task<Void, Never>] = [:]
  private var refreshTokens: [DashboardPage: UUID] = [:]
  private var previousRawConnections: [String: ControllerConnection] = [:]
  private var pausedActiveConnections: [DashboardConnection] = []
  private var pausedClosedConnections: [DashboardConnection] = []
  private var lastConnectionFrameAt: Date?
  private var nextLogIdentifier: UInt64 = 1
  private var usageBaselines: [String: (upload: Int64, download: Int64)] = [:]
  private var version = ControllerVersion()

  public init() {
    gateway = ControlGateway()
    previewMode = Self.previewRequested()
    if previewMode {
      loadPreviewFixtures()
    }
  }

  init(gateway: any DashboardControlGateway, previewMode: Bool = false) {
    self.gateway = gateway
    self.previewMode = previewMode
    if previewMode {
      loadPreviewFixtures()
    }
  }

  public func setVisible(_ visible: Bool) {
    guard isVisible != visible else { return }
    isVisible = visible
    if !visible { stop() }
  }

  public func start() {
    guard isVisible, !isStarted else { return }
    isStarted = true
    if previewMode {
      loadPreviewFixtures()
      return
    }

    for page in [
      DashboardPage.overview, .proxies, .rules, .connections, .config,
    ] {
      scheduleRefresh(page)
    }
    usageState = .loaded
    startAllStreams()
  }

  public func stop() {
    guard isStarted else { return }
    isStarted = false
    for task in streamTasks.values { task.cancel() }
    for task in streamRetryTasks.values { task.cancel() }
    for task in refreshTasks.values { task.cancel() }
    streamTasks.removeAll()
    streamRetryTasks.removeAll()
    streamRetryCounts.removeAll()
    healthyStreams.removeAll()
    streamFailures.removeAll()
    refreshTasks.removeAll()
    refreshTokens.removeAll()
  }

  public func refresh(_ page: DashboardPage) async {
    guard !previewMode else {
      loadPreviewFixtures()
      return
    }
    await refreshPage(page)
  }

  public func dismissActionError() {
    actionError = nil
  }

  public func selectProxy(group: String, node: String) async {
    await performAction {
      try await gateway.selectProxy(group: group, proxy: node)
      try await refreshProxies()
    }
  }

  public func testProxyGroup(_ group: String) async {
    await performAction {
      _ = try await gateway.testProxyGroupDelay(group: group, timeoutMilliseconds: 5_000)
      try await refreshProxies()
    }
  }

  public func refreshProxyProvider(_ provider: String) async {
    await performAction {
      try await gateway.refreshProxyProvider(provider)
      try await refreshProxies()
    }
  }

  public func testProxyProvider(_ provider: String) async {
    await performAction {
      _ = try await gateway.testProxyProvider(provider)
      try await refreshProxies()
    }
  }

  public func setRuleEnabled(_ ruleID: String, enabled: Bool) async {
    guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
    await performAction {
      try await gateway.setRuleDisabled(index: rule.index, disabled: !enabled)
      try await refreshRules()
    }
  }

  public func refreshRuleProvider(_ provider: String) async {
    await performAction {
      try await gateway.refreshRuleProvider(provider)
      try await refreshRules()
    }
  }

  @discardableResult
  public func closeConnection(_ connectionID: String) async -> Bool {
    await performAction {
      try await gateway.closeConnection(id: connectionID)
      let frame = try await gateway.fetchConnections()
      apply(connectionFrame: frame, respectingPause: false)
      if frame.connections.contains(where: { $0.id == connectionID }) {
        throw ActionValidationError.connectionStillActive
      }
    }
  }

  @discardableResult
  public func closeAllConnections() async -> Bool {
    await performAction {
      try await gateway.closeAllConnections()
      let frame = try await gateway.fetchConnections()
      apply(connectionFrame: frame, respectingPause: false)
    }
  }

  public func setConnectionsPaused(_ paused: Bool) {
    guard connectionsPaused != paused else { return }
    if paused {
      pausedActiveConnections = activeConnections
      pausedClosedConnections = closedConnections
    } else {
      pausedActiveConnections.removeAll(keepingCapacity: true)
      pausedClosedConnections.removeAll(keepingCapacity: true)
    }
    connectionsPaused = paused
  }

  public var presentedActiveConnections: [DashboardConnection] {
    connectionsPaused ? pausedActiveConnections : activeConnections
  }

  public var presentedClosedConnections: [DashboardConnection] {
    connectionsPaused ? pausedClosedConnections : closedConnections
  }

  public func setUsageDimension(_ dimension: UsageDimension) async {
    usageDimension = dimension
    rebuildUsage()
  }

  public func usageBreakdown(
    parent: String,
    parentDimension: UsageDimension,
    childDimension: UsageDimension,
    ancestor: String? = nil,
    ancestorDimension: UsageDimension? = nil
  ) -> [UsageRow] {
    var buckets: [String: UsageRow] = [:]
    for connection in closedConnections + activeConnections
    where usageKey(for: connection, dimension: parentDimension) == parent
      && matchesUsageAncestor(
        connection,
        ancestor: ancestor,
        dimension: ancestorDimension
      )
    {
      let baseline = usageBaselines[connection.id]
      let upload = max(connection.uploadBytes - (baseline?.upload ?? 0), 0)
      let download = max(connection.downloadBytes - (baseline?.download ?? 0), 0)
      let name = usageKey(for: connection, dimension: childDimension)
      var row =
        buckets[name]
        ?? UsageRow(name: name, uploadBytes: 0, downloadBytes: 0, connectionCount: 0)
      row.uploadBytes += upload
      row.downloadBytes += download
      row.connectionCount += 1
      buckets[name] = row
    }
    return sortedUsageRows(buckets.values)
  }

  private func matchesUsageAncestor(
    _ connection: DashboardConnection,
    ancestor: String?,
    dimension: UsageDimension?
  ) -> Bool {
    guard let ancestor, let dimension else { return true }
    return usageKey(for: connection, dimension: dimension) == ancestor
  }

  public func setUsageRange(_ range: UsageRange) async {
    usageRange = range
    rebuildUsageHistory()
  }

  public func clearUsage() async {
    closedConnections.removeAll()
    usageBaselines = Dictionary(
      uniqueKeysWithValues: activeConnections.map {
        ($0.id, (upload: $0.uploadBytes, download: $0.downloadBytes))
      })
    trafficHistory.removeAll()
    usageHistory.removeAll()
    rebuildUsage()
  }

  public func setLogsPaused(_ paused: Bool) {
    logsPaused = paused
  }

  public func setLogLevel(_ level: DashboardLogLevel) async {
    guard logLevel != level else { return }
    logLevel = level
    if isStarted, !previewMode { startLogStream() }
  }

  public func clearLogs() async {
    logs.removeAll(keepingCapacity: true)
    updateStreamBackedState(for: .logs)
  }

  public func setMode(_ mode: DashboardProxyMode) async {
    guard let requested = ControllerOutboundMode(rawValue: mode.rawValue.lowercased()) else {
      return
    }
    await performAction {
      let snapshot = try await gateway.applyOutboundMode(requested)
      apply(snapshot: snapshot)
    }
  }

  public func setAllowLANEnabled(_ enabled: Bool) async {
    await patchConfig(.allowLAN(enabled))
  }

  public func setUnifiedDelayEnabled(_ enabled: Bool) async {
    await patchConfig(.unifiedDelay(enabled))
  }

  public func setIPv6Enabled(_ enabled: Bool) async {
    await patchConfig(.ipv6(enabled))
  }

  public func setCoreLogLevel(_ level: ControllerLogLevel) async {
    await patchConfig(.logLevel(level))
  }

  public func setTCPConcurrentEnabled(_ enabled: Bool) async {
    await patchConfig(.tcpConcurrent(enabled))
  }

  public func setFindProcessMode(_ mode: ControllerFindProcessMode) async {
    await patchConfig(.findProcessMode(mode))
  }

  public func reloadConfiguration() async {
    await performAction {
      try await gateway.reloadActiveProfile()
      let snapshot = try await waitForRuntimeSnapshot()
      apply(snapshot: snapshot)
      startAllStreams()
      try await refreshProfileCatalogs()
    }
  }

  public func restartRuntime() async {
    await performAction {
      try await gateway.restartAgent()
      let snapshot = try await waitForRuntimeSnapshot()
      apply(snapshot: snapshot)
      startAllStreams()
      try await refreshProfileCatalogs()
    }
  }

  public func flushDNSCache() async {
    await performAction { try await gateway.flushDNSCache() }
  }

  public func flushFakeIPCache() async {
    await performAction { try await gateway.flushFakeIPCache() }
  }

  public func updateGeoData() async {
    await performAction { try await gateway.updateGeoData() }
  }

  private func scheduleRefresh(_ page: DashboardPage) {
    refreshTasks[page]?.cancel()
    let token = UUID()
    refreshTokens[page] = token
    refreshTasks[page] = Task { [weak self] in
      guard let self else { return }
      await refreshPage(page)
      guard refreshTokens[page] == token else { return }
      refreshTasks[page] = nil
      refreshTokens[page] = nil
    }
  }

  private func refreshPage(_ page: DashboardPage) async {
    switch page {
    case .overview:
      await load(page: page) { try await refreshOverview() }
    case .proxies:
      await load(page: page) { try await refreshProxies() }
    case .rules:
      await load(page: page) { try await refreshRules() }
    case .connections:
      await load(page: page) {
        let frame = try await gateway.fetchConnections()
        apply(connectionFrame: frame, respectingPause: false)
      }
    case .usage:
      rebuildUsage()
      updateStreamBackedState(for: .usage)
    case .logs:
      if isStarted { startLogStream() }
    case .config:
      await load(page: page) {
        apply(config: try await gateway.fetchConfig())
      }
    }
  }

  private func refreshOverview() async throws {
    version = try await gateway.fetchVersion()
    apply(snapshot: try await gateway.fetchSnapshot())
  }

  private func refreshProxies() async throws {
    let catalog = try await gateway.fetchProxies()
    let providers = try await gateway.fetchProxyProviders()
    apply(proxyCatalog: catalog)
    proxyProviders = providers.providers.values.map(makeProxyProvider).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    proxiesState =
      proxyGroups.isEmpty && proxyProviders.isEmpty
      ? .empty(message: "The active profile has no proxy groups.") : .loaded
  }

  private func refreshRules() async throws {
    let catalog = try await gateway.fetchRules()
    let providers = try await gateway.fetchRuleProviders()
    rules = catalog.rules.map {
      DashboardRule(
        id: String($0.index),
        index: $0.index,
        type: $0.type,
        payload: $0.payload,
        target: $0.proxy,
        isEnabled: $0.extra?.disabled != true,
        hitCount: Int(clamping: $0.extra?.hitCount ?? 0),
        missCount: Int(clamping: $0.extra?.missCount ?? 0),
        size: $0.size,
        lastMatchedAt: parseDate($0.extra?.hitAt ?? ""),
        lastUnmatchedAt: parseDate($0.extra?.missAt ?? "")
      )
    }
    ruleProviders = providers.providers.values.map {
      RuleProvider(
        name: $0.name,
        behavior: $0.behavior,
        format: $0.format,
        type: $0.type,
        vehicleType: $0.vehicleType,
        ruleCount: $0.ruleCount,
        updatedAt: parseDate($0.updatedAt)
      )
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    rulesState =
      rules.isEmpty && ruleProviders.isEmpty
      ? .empty(message: "The active profile has no rules.") : .loaded
  }

  private func refreshProfileCatalogs() async throws {
    async let proxies: Void = refreshProxies()
    async let rules: Void = refreshRules()
    _ = try await (proxies, rules)
  }

  private func load(page: DashboardPage, operation: () async throws -> Void) async {
    setState(.loading, for: page)
    do {
      try await operation()
      if state(for: page) == .loading { setState(.loaded, for: page) }
    } catch {
      guard !Task.isCancelled else { return }
      let message = safeErrorMessage(error)
      setState(.failed(message: message), for: page)
      markDegraded(message)
    }
  }

  @discardableResult
  private func performAction(_ operation: () async throws -> Void) async -> Bool {
    guard !previewMode else { return true }
    do {
      try await operation()
      return true
    } catch {
      guard !Task.isCancelled else { return false }
      let message = "Action failed: \(safeErrorMessage(error))"
      actionError = message
      markDegraded(message)
      return false
    }
  }

  private func patchConfig(_ patch: RuntimeConfigPatch) async {
    await performAction {
      try await gateway.patchConfig(patch)
      apply(config: try await gateway.fetchConfig())
    }
  }

  private func waitForRuntimeSnapshot() async throws -> ControllerSnapshot {
    var lastError: Error = ControlGatewayError.missingPayload
    for attempt in 0..<12 {
      do {
        return try await gateway.fetchSnapshot()
      } catch {
        lastError = error
        guard attempt < 11 else { break }
        let delayMilliseconds = min(200 * (1 << min(attempt, 3)), 1_500)
        try await Task.sleep(
          nanoseconds: UInt64(delayMilliseconds) * 1_000_000
        )
      }
    }
    throw lastError
  }

  private func startAllStreams() {
    healthyStreams.removeAll()
    startConnectionStream()
    startTrafficStream()
    startMemoryStream()
    startLogStream()
  }

  private func startConnectionStream() {
    streamTasks[.connections]?.cancel()
    streamTasks[.connections] = Task { [weak self, gateway] in
      do {
        for try await frame in gateway.connectionsStream() {
          guard let self, !Task.isCancelled else { return }
          streamSucceeded(.connections)
          apply(connectionFrame: frame, respectingPause: true)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        streamFailed(error, kind: .connections)
      }
    }
  }

  private func startTrafficStream() {
    streamTasks[.traffic]?.cancel()
    streamTasks[.traffic] = Task { [weak self, gateway] in
      do {
        for try await frame in gateway.trafficStream() {
          guard let self, !Task.isCancelled else { return }
          streamSucceeded(.traffic)
          apply(trafficFrame: frame)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        streamFailed(error, kind: .traffic)
      }
    }
  }

  private func startMemoryStream() {
    streamTasks[.memory]?.cancel()
    streamTasks[.memory] = Task { [weak self, gateway] in
      do {
        for try await frame in gateway.memoryStream() {
          guard let self, !Task.isCancelled else { return }
          streamSucceeded(.memory)
          apply(memoryFrame: frame)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        streamFailed(error, kind: .memory)
      }
    }
  }

  private func startLogStream() {
    streamTasks[.logs]?.cancel()
    if streamFailures[.logs] == nil {
      logsState = .loading
    }
    let level = controllerLogLevel
    streamTasks[.logs] = Task { [weak self, gateway] in
      do {
        for try await frame in gateway.logsStream(level: level) {
          guard let self, !Task.isCancelled else { return }
          streamSucceeded(.logs)
          append(logFrame: frame)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        streamFailed(error, kind: .logs)
      }
    }
  }

  private var controllerLogLevel: ControllerLogLevel {
    switch logLevel {
    case .all, .debug: .debug
    case .info: .info
    case .warning: .warning
    case .error: .error
    }
  }

  private func apply(snapshot: ControllerSnapshot) {
    apply(config: snapshot.configs)
    apply(proxyCatalog: snapshot.proxies)
    coreVersion = version.version.isEmpty ? "Mihomo" : "Mihomo \(version.version)"
    let runtimeStreams: [StreamKind] = [.connections, .traffic, .memory]
    if let message = runtimeStreams.compactMap({ streamFailures[$0] }).first {
      runtimeStatus = .degraded
      runtimeMessage = message
    } else {
      runtimeStatus = .connected
      runtimeMessage =
        "\(coreVersion) • \(configuration.mode.rawValue) • TUN \(configuration.enhancedTUNEnabled ? "On" : "Off")"
    }
    updateStreamBackedState(for: .overview)
    configState = .loaded
    if proxiesState == .loading { proxiesState = proxyGroups.isEmpty ? .loading : .loaded }
  }

  private func apply(config: ControllerConfig) {
    configuration = DashboardConfiguration(
      mode: DashboardProxyMode(rawValue: config.mode.capitalized) ?? .rule,
      enhancedTUNEnabled: config.tun.enable,
      allowLAN: config.allowLAN,
      unifiedDelay: config.unifiedDelay ?? false,
      ipv6Enabled: config.ipv6,
      logLevel: ControllerLogLevel(rawValue: config.logLevel.lowercased()) ?? .info,
      tcpConcurrent: config.tcpConcurrent,
      findProcessMode:
        ControllerFindProcessMode(rawValue: config.findProcessMode.lowercased()) ?? .strict,
      tunStack: DashboardTUNStack(rawValue: displayTUNStack(config.tun.stack)) ?? .mixed,
      networkInterface: config.interfaceName.isEmpty ? "Automatic" : config.interfaceName,
      mixedPort: config.mixedPort ?? 0,
      httpPort: config.port ?? 0,
      socksPort: config.socksPort ?? 0
    )
    configState = .loaded
  }

  private func apply(proxyCatalog: ControllerProxyCatalog) {
    proxyGroups = proxyCatalog.proxies.values
      .filter {
        !$0.hidden && !$0.all.isEmpty
          && $0.name.caseInsensitiveCompare("GLOBAL") != .orderedSame
      }
      .map { group in
        ProxyGroup(
          name: group.name,
          type: group.type,
          selectedNode: group.now.isEmpty ? nil : group.now,
          nodes: group.all.map { name in
            let node = proxyCatalog.proxies[name]
            return ProxyNode(
              name: name,
              type: node?.type ?? "Proxy",
              latencyMilliseconds: node?.history.last?.delay.nonzero,
              isSelected: group.now == name,
              isAlive: node?.alive,
              supportsUDP: node?.udp ?? false
            )
          }
        )
      }
      .sorted { lhs, rhs in
        let lhsSelector = lhs.type.caseInsensitiveCompare("Selector") == .orderedSame
        let rhsSelector = rhs.type.caseInsensitiveCompare("Selector") == .orderedSame
        if lhsSelector != rhsSelector { return lhsSelector }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  private func apply(connectionFrame: ControllerConnectionsFrame, respectingPause: Bool) {
    let now = Date()
    let elapsed = max(now.timeIntervalSince(lastConnectionFrameAt ?? now), 0.001)
    let newIDs = Set(connectionFrame.connections.map(\.id))
    for connection in activeConnections where !newIDs.contains(connection.id) {
      appendClosed(connection)
    }

    activeConnections = connectionFrame.connections.map { raw in
      makeConnection(raw, previous: previousRawConnections[raw.id], elapsed: elapsed)
    }.sorted { $0.startedAt > $1.startedAt }
    previousRawConnections = Dictionary(
      uniqueKeysWithValues: connectionFrame.connections.map {
        ($0.id, $0)
      })
    lastConnectionFrameAt = now
    traffic.uploadTotal = connectionFrame.uploadTotal
    traffic.downloadTotal = connectionFrame.downloadTotal
    traffic.activeConnections = activeConnections.count
    appendBounded(
      MetricPoint(time: now, value: Double(activeConnections.count)),
      to: &connectionHistory
    )
    rebuildUsage()
    updateStreamBackedState(for: .connections)
    updateStreamBackedState(for: .usage)
    if connectionsPaused, !respectingPause {
      pausedActiveConnections = activeConnections
      pausedClosedConnections = closedConnections
    }
  }

  private func apply(trafficFrame: ControllerTrafficFrame) {
    traffic.uploadSpeed = max(trafficFrame.up, 0)
    traffic.downloadSpeed = max(trafficFrame.down, 0)
    let point = TrafficPoint(
      time: Date(),
      upload: Double(max(trafficFrame.up, 0)),
      download: Double(max(trafficFrame.down, 0))
    )
    appendBounded(point, to: &trafficHistory)
    rebuildUsageHistory()
  }

  private func apply(memoryFrame: ControllerMemoryFrame) {
    traffic.memoryBytes = max(memoryFrame.inuse, 0)
    appendBounded(
      MetricPoint(time: Date(), value: Double(max(memoryFrame.inuse, 0))),
      to: &memoryHistory
    )
  }

  private func append(logFrame: ControllerLogFrame) {
    guard !logsPaused else { return }
    let entry = DashboardLogEntry(
      id: nextLogIdentifier,
      timestamp: Date(),
      level: dashboardLogLevel(logFrame.type),
      message: DashboardLogRedaction.redact(logFrame.payload)
    )
    nextLogIdentifier &+= 1
    logs.append(entry)
    if logs.count > Self.maximumLogs {
      logs.removeFirst(logs.count - Self.maximumLogs)
    }
    updateStreamBackedState(for: .logs)
  }

  private func makeConnection(
    _ raw: ControllerConnection,
    previous: ControllerConnection?,
    elapsed: TimeInterval
  ) -> DashboardConnection {
    let metadata = raw.metadata
    let host = firstNonempty(metadata.host, metadata.sniffHost, metadata.destinationIP, "Unknown")
    let destination = firstNonempty(
      metadata.remoteDestination,
      joinedAddress(metadata.destinationIP, port: metadata.destinationPort),
      host
    )
    let uploadSpeed =
      previous.map {
        Int64(Double(max(raw.upload - $0.upload, 0)) / elapsed)
      } ?? 0
    let downloadSpeed =
      previous.map {
        Int64(Double(max(raw.download - $0.download, 0)) / elapsed)
      } ?? 0
    return DashboardConnection(
      id: raw.id,
      host: host,
      destination: destination,
      network: metadata.network.uppercased(),
      connectionType: metadata.type,
      source: firstNonempty(metadata.sourceIP, metadata.inboundIP, "Local device"),
      sourcePort: metadata.sourcePort,
      destinationIP: metadata.destinationIP,
      destinationPort: metadata.destinationPort,
      user: firstNonempty(metadata.inboundUser, metadata.uid.map(String.init) ?? "", "Local user"),
      process: metadata.process.isEmpty ? nil : metadata.process,
      processPath: metadata.processPath.isEmpty ? nil : metadata.processPath,
      sniffHost: metadata.sniffHost.isEmpty ? nil : metadata.sniffHost,
      inboundName: firstNonempty(metadata.inboundName, metadata.type).nilIfEmpty,
      dnsMode: metadata.dnsMode,
      inboundIP: metadata.inboundIP,
      inboundPort: metadata.inboundPort,
      uid: metadata.uid,
      rule: raw.rule,
      rulePayload: raw.rulePayload,
      specialProxy: metadata.specialProxy,
      specialRules: metadata.specialRules,
      chains: raw.chains,
      uploadBytes: raw.upload,
      downloadBytes: raw.download,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      startedAt: parseDate(raw.start) ?? Date()
    )
  }

  private func makeProxyProvider(_ provider: ControllerProxyProvider) -> ProxyProvider {
    let info = provider.subscriptionInfo
    let usedBytes = info.map { ($0.download ?? 0) + ($0.upload ?? 0) }
    let nodes = provider.proxies.enumerated().map { index, proxy in
      ProxyNode(
        name: firstNonempty(proxy.name, "Unnamed \(index + 1)"),
        type: firstNonempty(proxy.type, "Proxy"),
        latencyMilliseconds: proxy.history.last?.delay.nonzero,
        isAlive: proxy.alive,
        supportsUDP: proxy.udp
      )
    }
    let expiresAt = info?.expire.flatMap { expire in
      expire > 0 ? Date(timeIntervalSince1970: TimeInterval(expire)) : nil
    }
    return ProxyProvider(
      name: provider.name,
      vehicleType: provider.vehicleType,
      updatedAt: parseDate(provider.updatedAt),
      nodeCount: provider.proxies.count,
      usedBytes: usedBytes,
      totalBytes: info?.total,
      expiresAt: expiresAt,
      nodes: nodes
    )
  }

  private func rebuildUsage() {
    var buckets: [String: UsageRow] = [:]
    for connection in closedConnections + activeConnections {
      let baseline = usageBaselines[connection.id]
      let upload = max(connection.uploadBytes - (baseline?.upload ?? 0), 0)
      let download = max(connection.downloadBytes - (baseline?.download ?? 0), 0)
      let name = usageKey(for: connection, dimension: usageDimension)
      var row =
        buckets[name]
        ?? UsageRow(
          name: name,
          uploadBytes: 0,
          downloadBytes: 0,
          connectionCount: 0
        )
      row.uploadBytes += upload
      row.downloadBytes += download
      row.connectionCount += 1
      buckets[name] = row
    }
    usageRows = sortedUsageRows(buckets.values)
  }

  private func usageKey(
    for connection: DashboardConnection,
    dimension: UsageDimension
  ) -> String {
    switch dimension {
    case .device: return firstNonempty(connection.source, "Local device")
    case .user: return firstNonempty(connection.user, "Local user")
    case .host: return firstNonempty(connection.host, connection.destination, "Unknown")
    case .proxy: return connection.chains.first ?? "DIRECT"
    case .process: return firstNonempty(connection.process ?? "", "Unknown process")
    }
  }

  private func sortedUsageRows<S: Sequence>(_ rows: S) -> [UsageRow]
  where S.Element == UsageRow {
    rows.sorted {
      let lhs = $0.uploadBytes + $0.downloadBytes
      let rhs = $1.uploadBytes + $1.downloadBytes
      return lhs == rhs
        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
        : lhs > rhs
    }
  }

  private func rebuildUsageHistory() {
    let cutoff = Date().addingTimeInterval(-usageRange.seconds)
    usageHistory = trafficHistory.filter { $0.time >= cutoff }
  }

  private func appendClosed(_ connection: DashboardConnection) {
    guard !closedConnections.contains(where: { $0.id == connection.id }) else { return }
    closedConnections.insert(connection, at: 0)
    if closedConnections.count > Self.maximumClosedConnections {
      closedConnections.removeLast(closedConnections.count - Self.maximumClosedConnections)
    }
  }

  private func streamFailed(_ error: Error, kind: StreamKind) {
    guard isStarted else { return }
    healthyStreams.remove(kind)
    let message = "Live data interrupted: \(safeErrorMessage(error))"
    streamFailures[kind] = message
    for page in streamBackedPages(for: kind) {
      updateStreamBackedState(for: page)
    }
    markDegraded(message)
    let failures = min((streamRetryCounts[kind] ?? 0) + 1, 6)
    streamRetryCounts[kind] = failures
    let delaySeconds = min(1 << (failures - 1), 30)
    streamRetryTasks[kind]?.cancel()
    streamRetryTasks[kind] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
      guard let self, isStarted, !Task.isCancelled else { return }
      streamRetryTasks[kind] = nil
      switch kind {
      case .connections: startConnectionStream()
      case .traffic: startTrafficStream()
      case .memory: startMemoryStream()
      case .logs: startLogStream()
      }
    }
  }

  private func streamSucceeded(_ kind: StreamKind) {
    healthyStreams.insert(kind)
    streamFailures[kind] = nil
    streamRetryCounts[kind] = 0
    streamRetryTasks[kind]?.cancel()
    streamRetryTasks[kind] = nil
    for page in streamBackedPages(for: kind) {
      updateStreamBackedState(for: page)
    }
    let runtimeStreams: Set<StreamKind> = [.connections, .traffic, .memory]
    if runtimeStreams.isSubset(of: healthyStreams),
      runtimeStatus != .connected,
      refreshTasks[.overview] == nil
    {
      scheduleRefresh(.overview)
    }
  }

  private func streamBackedPages(for kind: StreamKind) -> [DashboardPage] {
    switch kind {
    case .connections: [.connections, .usage]
    case .traffic: [.overview, .usage]
    case .memory: [.overview]
    case .logs: [.logs]
    }
  }

  private func streamDependencies(for page: DashboardPage) -> [StreamKind] {
    switch page {
    case .overview: [.connections, .traffic, .memory]
    case .connections: [.connections]
    case .usage: [.connections, .traffic]
    case .logs: [.logs]
    case .proxies, .rules, .config: []
    }
  }

  private func updateStreamBackedState(for page: DashboardPage) {
    if let message = streamDependencies(for: page).compactMap({ streamFailures[$0] }).first {
      setState(.failed(message: message), for: page)
    } else {
      setState(.loaded, for: page)
    }
  }

  private func markDegraded(_ message: String) {
    runtimeStatus = runtimeStatus == .disconnected ? .disconnected : .degraded
    runtimeMessage = message
  }

  private func safeErrorMessage(_ error: Error) -> String {
    DashboardLogRedaction.redact(error.localizedDescription)
  }

  private func state(for page: DashboardPage) -> DashboardLoadState {
    switch page {
    case .overview: overviewState
    case .proxies: proxiesState
    case .rules: rulesState
    case .connections: connectionsState
    case .usage: usageState
    case .logs: logsState
    case .config: configState
    }
  }

  private func setState(_ state: DashboardLoadState, for page: DashboardPage) {
    switch page {
    case .overview: overviewState = state
    case .proxies: proxiesState = state
    case .rules: rulesState = state
    case .connections: connectionsState = state
    case .usage: usageState = state
    case .logs: logsState = state
    case .config: configState = state
    }
  }

  private func appendBounded<Value>(_ value: Value, to values: inout [Value]) {
    values.append(value)
    if values.count > Self.maximumTrendPoints {
      values.removeFirst(values.count - Self.maximumTrendPoints)
    }
  }

  private func dashboardLogLevel(_ value: String) -> DashboardLogLevel {
    switch value.lowercased() {
    case "debug": .debug
    case "warning", "warn": .warning
    case "error", "fatal": .error
    default: .info
    }
  }

  private func displayTUNStack(_ value: String) -> String {
    switch value.lowercased() {
    case "system": "System"
    case "gvisor": "gVisor"
    default: "Mixed"
    }
  }

  private func joinedAddress(_ address: String, port: String) -> String {
    if address.isEmpty { return "" }
    return port.isEmpty ? address : "\(address):\(port)"
  }

  private func firstNonempty(_ values: String...) -> String {
    values.first { !$0.isEmpty } ?? ""
  }

  private func parseDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func previewRequested(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    executableURL: URL? = Bundle.main.executableURL,
    developmentUpdatesDisabled: Bool = Bundle.main.object(
      forInfoDictionaryKey: "MihomoBoxDevelopmentUpdatesDisabled"
    ) as? Bool == true
  ) -> Bool {
    let requested =
      environment["MIHOMO_NATIVE_UI_PREVIEW"] == "1" || arguments.contains("--native-ui-preview")
    guard requested, let executableURL else {
      return false
    }
    let resolved = executableURL.resolvingSymlinksInPath().standardizedFileURL
    let components = resolved.pathComponents
    if let buildIndex = components.firstIndex(of: ".build") {
      return buildIndex > 0 && components[buildIndex - 1] == "mihomo-app"
    }
    guard developmentUpdatesDisabled,
      components.suffix(4) == ["MihomoBox.app", "Contents", "MacOS", "mihomo-app"]
    else { return false }
    return components.dropLast(4).last == "build"
  }

  private func loadPreviewFixtures() {
    runtimeStatus = .connected
    coreVersion = "Mihomo v1.19.28"
    runtimeMessage = "\(coreVersion) • Rule • TUN On"
    configuration = DashboardConfiguration()
    traffic = TrafficSnapshot(
      uploadSpeed: 684_000,
      downloadSpeed: 4_820_000,
      uploadTotal: 8_730_000_000,
      downloadTotal: 42_680_000_000,
      activeConnections: 18,
      memoryBytes: 92_300_000
    )
    let now = Date()
    var previewTraffic: [TrafficPoint] = []
    var previewMemory: [MetricPoint] = []
    var previewConnections: [MetricPoint] = []
    for index in 0..<48 {
      let time = now.addingTimeInterval(Double(index - 48) * 2)
      let upload = 180_000 + (index * 91_337) % 1_400_000
      let download = 900_000 + (index * 617_123) % 7_200_000
      let memory = 72_000_000 + (index * 811_111) % 26_000_000
      previewTraffic.append(
        TrafficPoint(
          time: time,
          upload: Double(upload),
          download: Double(download)
        ))
      previewMemory.append(MetricPoint(time: time, value: Double(memory)))
      previewConnections.append(
        MetricPoint(
          time: time,
          value: Double(8 + (index * 7) % 23)
        ))
    }
    trafficHistory = previewTraffic
    memoryHistory = previewMemory
    connectionHistory = previewConnections
    usageHistory = trafficHistory

    proxyGroups = [
      ProxyGroup(
        name: "Auto Select",
        type: "URLTest",
        selectedNode: "Singapore",
        nodes: [
          ProxyNode(
            name: "Hong Kong", type: "Shadowsocks", latencyMilliseconds: 85, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Japan", type: "VMess", latencyMilliseconds: 120, isAlive: true, supportsUDP: true
          ),
          ProxyNode(
            name: "Singapore", type: "Trojan", latencyMilliseconds: 65, isSelected: true,
            isAlive: true, supportsUDP: true),
          ProxyNode(
            name: "United States", type: "Hysteria2", latencyMilliseconds: 180, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Taiwan", type: "VLESS", latencyMilliseconds: 95, isAlive: true, supportsUDP: true
          ),
        ]
      ),
      ProxyGroup(
        name: "Proxy",
        type: "Selector",
        selectedNode: "Auto Select",
        nodes: [
          ProxyNode(
            name: "Auto Select", type: "URLTest", latencyMilliseconds: 65, isSelected: true,
            isAlive: true, supportsUDP: true),
          ProxyNode(name: "DIRECT", type: "Direct", isAlive: true, supportsUDP: true),
          ProxyNode(
            name: "Hong Kong", type: "Shadowsocks", latencyMilliseconds: 85, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Japan", type: "VMess", latencyMilliseconds: 120, isAlive: true, supportsUDP: true
          ),
          ProxyNode(
            name: "Singapore", type: "Trojan", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "United States", type: "Hysteria2", latencyMilliseconds: 180, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Taiwan", type: "VLESS", latencyMilliseconds: 95, isAlive: true, supportsUDP: true
          ),
        ]
      ),
      ProxyGroup(
        name: "Streaming",
        type: "Selector",
        selectedNode: "Japan",
        nodes: [
          ProxyNode(
            name: "Proxy", type: "Selector", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
          ProxyNode(name: "DIRECT", type: "Direct", isAlive: true, supportsUDP: true),
          ProxyNode(
            name: "Hong Kong", type: "Shadowsocks", latencyMilliseconds: 85, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Japan", type: "VMess", latencyMilliseconds: 120, isSelected: true, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Singapore", type: "Trojan", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Taiwan", type: "VLESS", latencyMilliseconds: 95, isAlive: true, supportsUDP: true
          ),
        ]
      ),
      ProxyGroup(
        name: "AI Services",
        type: "Selector",
        selectedNode: "United States",
        nodes: [
          ProxyNode(
            name: "Proxy", type: "Selector", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "United States", type: "Hysteria2", latencyMilliseconds: 180, isSelected: true,
            isAlive: true, supportsUDP: true),
          ProxyNode(
            name: "Japan", type: "VMess", latencyMilliseconds: 120, isAlive: true, supportsUDP: true
          ),
          ProxyNode(
            name: "Singapore", type: "Trojan", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
        ]
      ),
    ]
    proxyProviders = [
      ProxyProvider(
        name: "Primary Subscription",
        vehicleType: "HTTP",
        updatedAt: now.addingTimeInterval(-1_800),
        nodeCount: 5,
        usedBytes: 148_000_000_000,
        totalBytes: 1_000_000_000_000,
        expiresAt: now.addingTimeInterval(86_400 * 28),
        nodes: [
          ProxyNode(
            name: "Hong Kong", type: "Shadowsocks", latencyMilliseconds: 85, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Japan", type: "VMess", latencyMilliseconds: 120, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Singapore", type: "Trojan", latencyMilliseconds: 65, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "United States", type: "Hysteria2", latencyMilliseconds: 180, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Taiwan", type: "VLESS", latencyMilliseconds: 95, isAlive: true,
            supportsUDP: true),
        ]
      ),
      ProxyProvider(
        name: "Fallback Subscription",
        vehicleType: "HTTP",
        updatedAt: now.addingTimeInterval(-4_200),
        nodeCount: 3,
        usedBytes: 42_000_000_000,
        totalBytes: 500_000_000_000,
        expiresAt: now.addingTimeInterval(86_400 * 12),
        nodes: [
          ProxyNode(
            name: "Fallback HK", type: "Shadowsocks", latencyMilliseconds: 102, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Fallback JP", type: "Trojan", latencyMilliseconds: 146, isAlive: true,
            supportsUDP: true),
          ProxyNode(
            name: "Fallback US", type: "VLESS", latencyMilliseconds: 221, isAlive: false,
            supportsUDP: true),
        ]
      ),
    ]
    rules = [
      DashboardRule(
        id: "0", index: 0, type: "DOMAIN-SUFFIX", payload: "google.com", target: "Proxy",
        hitCount: 128, missCount: 3, size: 156, lastMatchedAt: now.addingTimeInterval(-300),
        lastUnmatchedAt: now.addingTimeInterval(-7_200)),
      DashboardRule(
        id: "1", index: 1, type: "DOMAIN-SUFFIX", payload: "googleapis.com", target: "Proxy",
        hitCount: 14, missCount: 2, size: 89, lastMatchedAt: now.addingTimeInterval(-120),
        lastUnmatchedAt: now.addingTimeInterval(-360)),
      DashboardRule(
        id: "2", index: 2, type: "DOMAIN-SUFFIX", payload: "gstatic.com", target: "Proxy",
        hitCount: 21, missCount: 3, size: 234, lastMatchedAt: now.addingTimeInterval(-180),
        lastUnmatchedAt: now.addingTimeInterval(-480)),
      DashboardRule(
        id: "3", index: 3, type: "DOMAIN-SUFFIX", payload: "github.com", target: "Proxy",
        hitCount: 28, missCount: 4, size: 178, lastMatchedAt: now.addingTimeInterval(-240),
        lastUnmatchedAt: now.addingTimeInterval(-540)),
      DashboardRule(
        id: "4", index: 4, type: "DOMAIN-SUFFIX", payload: "githubusercontent.com", target: "Proxy",
        hitCount: 0, missCount: 6, size: 445, lastUnmatchedAt: now.addingTimeInterval(-660)),
      DashboardRule(
        id: "5", index: 5, type: "DOMAIN-SUFFIX", payload: "openai.com", target: "AI Services",
        hitCount: 42, missCount: 7, size: 67, lastMatchedAt: now.addingTimeInterval(-360),
        lastUnmatchedAt: now.addingTimeInterval(-720)),
      DashboardRule(
        id: "6", index: 6, type: "DOMAIN-SUFFIX", payload: "anthropic.com", target: "AI Services",
        hitCount: 49, missCount: 8, size: 34, lastMatchedAt: now.addingTimeInterval(-420),
        lastUnmatchedAt: now.addingTimeInterval(-840)),
      DashboardRule(
        id: "7", index: 7, type: "DOMAIN-SUFFIX", payload: "claude.ai", target: "AI Services",
        hitCount: 56, missCount: 9, size: 23, lastMatchedAt: now.addingTimeInterval(-480),
        lastUnmatchedAt: now.addingTimeInterval(-900)),
      DashboardRule(
        id: "8", index: 8, type: "DOMAIN-SUFFIX", payload: "netflix.com", target: "Streaming",
        hitCount: 0, missCount: 10, size: 512, lastUnmatchedAt: now.addingTimeInterval(-1_020)),
      DashboardRule(
        id: "9", index: 9, type: "MATCH", payload: "", target: "Proxy", hitCount: 6_731,
        missCount: 0, size: 1),
    ]
    ruleProviders = [
      RuleProvider(
        name: "private", behavior: "domain", format: "mrs", type: "Rule", vehicleType: "HTTP",
        ruleCount: 384, updatedAt: now.addingTimeInterval(-3_600)),
      RuleProvider(
        name: "applications", behavior: "classical", format: "yaml", type: "Rule",
        vehicleType: "HTTP", ruleCount: 1_892, updatedAt: now.addingTimeInterval(-7_200)),
      RuleProvider(
        name: "streaming", behavior: "domain", format: "mrs", type: "Rule", vehicleType: "HTTP",
        ruleCount: 624, updatedAt: now.addingTimeInterval(-5_400)),
    ]
    activeConnections = [
      DashboardConnection(
        id: "preview-1", host: "api.github.com", destination: "140.82.112.6:443",
        network: "TCP", connectionType: "HTTP", source: "192.168.1.24",
        sourcePort: "50031", destinationIP: "140.82.112.6", destinationPort: "443",
        user: "local", process: "Code",
        processPath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        sniffHost: "api.github.com", inboundName: "TUN",
        dnsMode: "fake-ip", inboundIP: "198.18.0.1", inboundPort: "0", uid: 501,
        rule: "DomainSuffix", rulePayload: "github.com", specialProxy: "Auto Select",
        specialRules: "PROCESS-NAME,Code", chains: ["Singapore", "Auto Select", "Proxy"],
        uploadBytes: 1_820_000, downloadBytes: 18_640_000, uploadSpeed: 42_000,
        downloadSpeed: 620_000, startedAt: now.addingTimeInterval(-183)
      ),
      DashboardConnection(
        id: "preview-2", host: "www.youtube.com", destination: "142.250.191.110:443",
        network: "UDP", connectionType: "QUIC", source: "192.168.1.24",
        sourcePort: "50034", destinationIP: "142.250.191.110", destinationPort: "443",
        user: "local", process: "Safari",
        processPath: "/Applications/Safari.app/Contents/MacOS/Safari",
        sniffHost: "www.youtube.com", inboundName: "TUN",
        dnsMode: "fake-ip", inboundIP: "198.18.0.1", inboundPort: "0", uid: 501,
        rule: "RuleSet", rulePayload: "streaming", specialProxy: "Streaming",
        specialRules: "DOMAIN-SUFFIX,youtube.com", chains: ["Japan", "Streaming"],
        uploadBytes: 3_420_000, downloadBytes: 92_300_000, uploadSpeed: 92_000,
        downloadSpeed: 3_840_000, startedAt: now.addingTimeInterval(-521)
      ),
      DashboardConnection(
        id: "preview-3", host: "gateway.icloud.com", destination: "17.248.190.64:443",
        network: "TCP", connectionType: "HTTPS", source: "192.168.1.24",
        sourcePort: "50036", destinationIP: "17.248.190.64", destinationPort: "443",
        user: "local", process: "cloudd",
        processPath: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd",
        sniffHost: "gateway.icloud.com", inboundName: "TUN",
        dnsMode: "redir-host", inboundIP: "198.18.0.1", inboundPort: "0", uid: 501,
        rule: "DomainSuffix", rulePayload: "icloud.com", specialRules: "SYSTEM",
        chains: ["DIRECT"], uploadBytes: 480_000,
        downloadBytes: 1_920_000, uploadSpeed: 8_000, downloadSpeed: 31_000,
        startedAt: now.addingTimeInterval(-74)
      ),
    ]
    closedConnections = []
    logs = [
      DashboardLogEntry(
        id: 1, timestamp: now.addingTimeInterval(-24), level: .info,
        message: "[TCP] 192.168.1.100:50031 → github.com:443 using Proxy[Auto Select[Singapore]]"),
      DashboardLogEntry(
        id: 2, timestamp: now.addingTimeInterval(-22), level: .info,
        message: "[DNS] resolved api.openai.com to 104.18.33.45"),
      DashboardLogEntry(
        id: 3, timestamp: now.addingTimeInterval(-20), level: .debug,
        message: "[Proxy] Singapore latency: 65 ms"),
      DashboardLogEntry(
        id: 4, timestamp: now.addingTimeInterval(-18), level: .info,
        message: "[UDP] 192.168.1.100:50034 → www.youtube.com:443 using Streaming[Japan]"),
      DashboardLogEntry(
        id: 5, timestamp: now.addingTimeInterval(-16), level: .warning,
        message: "[TCP] connection to example.net:443 timed out using Proxy[United States]"),
      DashboardLogEntry(
        id: 6, timestamp: now.addingTimeInterval(-14), level: .info,
        message: "[TUN] 192.168.1.100 → claude.ai using AI Services[United States]"),
      DashboardLogEntry(
        id: 7, timestamp: now.addingTimeInterval(-12), level: .debug,
        message: "[DNS] cache hit for www.google.com"),
      DashboardLogEntry(
        id: 8, timestamp: now.addingTimeInterval(-10), level: .info,
        message: "[QUIC] 192.168.1.100:50039 → discord.com:443 using Streaming[Japan]"),
      DashboardLogEntry(
        id: 9, timestamp: now.addingTimeInterval(-8), level: .info,
        message: "[TCP] 192.168.1.100:50041 → raw.githubusercontent.com:443 using Proxy[Hong Kong]"),
      DashboardLogEntry(
        id: 10, timestamp: now.addingTimeInterval(-6), level: .debug,
        message: "[Proxy] Japan latency: 120 ms"),
      DashboardLogEntry(
        id: 11, timestamp: now.addingTimeInterval(-4), level: .warning,
        message: "[UDP] connection to 104.18.12.191:443 timed out"),
      DashboardLogEntry(
        id: 12, timestamp: now.addingTimeInterval(-2), level: .info,
        message: "[DNS] resolved www.twitch.tv to 151.101.2.167"),
    ]
    nextLogIdentifier = 13
    rebuildUsage()
    for page in DashboardPage.allCases { setState(.loaded, for: page) }
  }
}

extension Int {
  fileprivate var nonzero: Int? { self > 0 ? self : nil }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension UsageRange {
  fileprivate var seconds: TimeInterval {
    switch self {
    case .hour: 3_600
    case .day: 86_400
    case .week: 7 * 86_400
    case .month: 30 * 86_400
    }
  }
}
