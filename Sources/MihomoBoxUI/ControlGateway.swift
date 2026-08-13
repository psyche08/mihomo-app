import Foundation
import MihomoControl

public enum ControlGatewayError: Error, Equatable, LocalizedError, Sendable {
  case invalidControllerName
  case invalidTimeout
  case missingPayload
  case invalidStreamSession
  case streamFrameTooLarge(Int)
  case noGlobalProxy
  case outboundModeReadbackMismatch
  case invalidProxySelection
  case proxySelectionReadbackMismatch
  case proxyProviderRefreshRequiresNonGlobalMode
  case unsafeGlobalRuntimeStopped
  case unsafeGlobalFailClosedStopFailed

  public var errorDescription: String? {
    switch self {
    case .invalidControllerName:
      return "the controller name is invalid"
    case .invalidTimeout:
      return "the latency timeout is invalid"
    case .missingPayload:
      return "the controller returned an empty response"
    case .invalidStreamSession:
      return "the daemon returned an invalid controller stream session"
    case .streamFrameTooLarge(let length):
      return "the controller stream frame exceeds 16 MiB (\(length) bytes)"
    case .noGlobalProxy:
      return "Global mode has no route through a proxy"
    case .outboundModeReadbackMismatch:
      return "the controller did not apply the requested outbound mode safely"
    case .invalidProxySelection:
      return "the proxy selection would break the active Global route"
    case .proxySelectionReadbackMismatch:
      return "the controller did not apply the proxy selection safely"
    case .proxyProviderRefreshRequiresNonGlobalMode:
      return "switch out of Global mode before refreshing a proxy provider"
    case .unsafeGlobalRuntimeStopped:
      return "the runtime had no safe Global proxy route and was stopped"
    case .unsafeGlobalFailClosedStopFailed:
      return "the runtime had no safe Global proxy route and could not be stopped"
    }
  }
}

public enum ControllerOutboundMode: String, Codable, CaseIterable, Sendable {
  case rule
  case global
  case direct
}

public enum ControllerLogLevel: String, Codable, CaseIterable, Sendable {
  case silent
  case error
  case warning
  case info
  case debug
}

public enum ControllerFindProcessMode: String, Codable, CaseIterable, Sendable {
  case off
  case strict
  case always
}

/// The only general runtime fields the native UI may hot-patch.
///
/// Controller identity, DNS recursion-boundary settings and every TUN field are
/// deliberately unrepresentable. Enhanced TUN remains owned by its dedicated
/// lifecycle operation instead of a generic `/configs` patch.
public enum RuntimeConfigPatch: Equatable, Sendable {
  case allowLAN(Bool)
  case ipv6(Bool)
  case logLevel(ControllerLogLevel)
  case unifiedDelay(Bool)
  case tcpConcurrent(Bool)
  case findProcessMode(ControllerFindProcessMode)

  func encodedPayload() throws -> Data {
    let object: [String: Any]
    switch self {
    case .allowLAN(let value): object = ["allow-lan": value]
    case .ipv6(let value): object = ["ipv6": value]
    case .logLevel(let value): object = ["log-level": value.rawValue]
    case .unifiedDelay(let value): object = ["unified-delay": value]
    case .tcpConcurrent(let value): object = ["tcp-concurrent": value]
    case .findProcessMode(let value): object = ["find-process-mode": value.rawValue]
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

public struct ControllerDelayResult: Codable, Equatable, Sendable {
  public var delay: Int

  public init(delay: Int = 0) {
    self.delay = delay
  }

  enum CodingKeys: String, CodingKey { case delay }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    delay = try container.decodeIfPresent(Int.self, forKey: .delay) ?? 0
  }
}

protocol ControlSessionProtocol: AnyObject, Sendable {
  func send(_ request: ControlRequest) throws -> ControlResponse
}

extension MihomoControlSession: ControlSessionProtocol {}

typealias ControlSessionFactory = @Sendable () throws -> any ControlSessionProtocol

/// Serializes controller mutations whose safety depends on a before/after
/// snapshot. The actor itself may re-enter while an operation is suspended,
/// so `held` and the FIFO continuations form the actual non-reentrant gate.
private actor ControllerMutationGate {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func withLock<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      held = false
      return
    }
    waiters.removeFirst().resume()
  }
}

private final class RetainedControlChannel: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.native-controller")
  private let makeSession: ControlSessionFactory
  private var session: (any ControlSessionProtocol)?

  init(makeSession: @escaping ControlSessionFactory) {
    self.makeSession = makeSession
  }

  func send(_ request: ControlRequest, retryReadOnDisconnect: Bool) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          let payload = try perform(request, retryReadOnDisconnect: retryReadOnDisconnect)
          continuation.resume(returning: payload)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func perform(_ request: ControlRequest, retryReadOnDisconnect: Bool) throws -> Data {
    let attempts = retryReadOnDisconnect ? 2 : 1
    for attempt in 0..<attempts {
      do {
        if session == nil { session = try makeSession() }
        return try session?.send(request).payload ?? Data()
      } catch let error as ControlError where error.isDisconnection {
        session = nil
        if attempt + 1 == attempts { throw error }
      } catch {
        throw error
      }
    }
    throw ControlError.connectionFailed
  }
}

private struct ControllerStreamOpenResponse: Decodable {
  let session: String
}

private final class ControllerStreamWorker<Element: Decodable & Sendable>: @unchecked Sendable {
  typealias Continuation = AsyncThrowingStream<Element, Error>.Continuation

  static var maximumFrameBytes: Int { 16 * 1_024 * 1_024 }

  private let target: String
  private let makeSession: ControlSessionFactory
  private let queue: DispatchQueue
  private let cancellationQueue: DispatchQueue
  private let lock = NSLock()
  private var session: (any ControlSessionProtocol)?
  private var identifier: String?
  private var cancelled = false

  init(target: String, makeSession: @escaping ControlSessionFactory) {
    self.target = target
    self.makeSession = makeSession
    queue = DispatchQueue(label: "dev.linsheng.mihomo-app.controller-stream.\(UUID().uuidString)")
    cancellationQueue = DispatchQueue(
      label: "dev.linsheng.mihomo-app.controller-stream-close.\(UUID().uuidString)"
    )
  }

  func start(_ continuation: Continuation) {
    queue.async { [self] in
      do {
        let ownedSession = try makeSession()
        guard install(ownedSession) else {
          continuation.finish()
          return
        }

        let opened = try ownedSession.send(
          ControlRequest(
            operation: .controllerStreamOpen,
            arguments: ["target": target]
          )
        ).payload
        guard let opened,
          let response = try? JSONDecoder().decode(ControllerStreamOpenResponse.self, from: opened),
          UUID(uuidString: response.session) != nil
        else {
          throw ControlGatewayError.invalidStreamSession
        }
        guard install(identifier: response.session) else {
          close(response.session, on: ownedSession)
          continuation.finish()
          return
        }

        while !isCancelled {
          let frame =
            try ownedSession.send(
              ControlRequest(
                operation: .controllerStreamNext,
                arguments: ["session": response.session]
              )
            ).payload ?? Data()
          guard frame.count <= Self.maximumFrameBytes else {
            throw ControlGatewayError.streamFrameTooLarge(frame.count)
          }
          let value = try JSONDecoder().decode(Element.self, from: frame)
          if case .terminated = continuation.yield(value) {
            cancel()
            return
          }
        }
        closeStoredStream()
        continuation.finish()
      } catch {
        let wasCancelled = isCancelled
        closeStoredStream()
        if wasCancelled {
          continuation.finish()
        } else {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func cancel() {
    let closeState: ((any ControlSessionProtocol), String)?
    lock.lock()
    cancelled = true
    if let session, let identifier {
      closeState = (session, identifier)
      self.session = nil
      self.identifier = nil
    } else {
      closeState = nil
    }
    lock.unlock()

    if let (session, identifier) = closeState {
      cancellationQueue.async { [self] in
        close(identifier, on: session)
      }
    }
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  private func install(_ session: any ControlSessionProtocol) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return false }
    self.session = session
    return true
  }

  private func install(identifier: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return false }
    self.identifier = identifier
    return true
  }

  private func closeStoredStream() {
    let closeState: ((any ControlSessionProtocol), String)?
    lock.lock()
    if let session, let identifier {
      closeState = (session, identifier)
    } else {
      closeState = nil
    }
    session = nil
    identifier = nil
    lock.unlock()

    if let (session, identifier) = closeState {
      close(identifier, on: session)
    }
  }

  private func close(_ identifier: String, on session: any ControlSessionProtocol) {
    _ = try? session.send(
      ControlRequest(
        operation: .controllerStreamClose,
        arguments: ["session": identifier]
      ))
  }
}

/// Typed native access to the fixed controller contract.
///
/// No caller can supply a controller endpoint, secret, arbitrary path, latency
/// URL or raw request body. The root daemon remains responsible for injecting
/// the controller credential and validating the fixed native UI allowlist.
public final class ControlGateway: @unchecked Sendable {
  private static let maximumControllerNameBytes = 1_024

  private let makeSession: ControlSessionFactory
  private let channel: RetainedControlChannel
  private let mutationGate = ControllerMutationGate()

  public init() {
    let factory: ControlSessionFactory = { try MihomoControlSession() }
    makeSession = factory
    channel = RetainedControlChannel(makeSession: factory)
  }

  init(makeSession: @escaping ControlSessionFactory) {
    self.makeSession = makeSession
    channel = RetainedControlChannel(makeSession: makeSession)
  }

  public func fetchVersion() async throws -> ControllerVersion {
    try await decode(
      ControllerVersion.self,
      request: ControlRequest(operation: .controllerVersion),
      retryReadOnDisconnect: true
    )
  }

  public func fetchSnapshot() async throws -> ControllerSnapshot {
    try await decode(
      ControllerSnapshot.self,
      request: ControlRequest(operation: .snapshot),
      retryReadOnDisconnect: true
    )
  }

  public func fetchConfig() async throws -> ControllerConfig {
    try await controllerGET("/configs", as: ControllerConfig.self)
  }

  public func fetchProxies() async throws -> ControllerProxyCatalog {
    try await controllerGET("/proxies", as: ControllerProxyCatalog.self)
  }

  public func fetchProxyProviders() async throws -> ControllerProxyProviderCatalog {
    try await decode(
      ControllerProxyProviderCatalog.self,
      request: ControlRequest(operation: .listProxyProviders),
      retryReadOnDisconnect: true
    )
  }

  public func fetchRules() async throws -> ControllerRuleCatalog {
    try await decode(
      ControllerRuleCatalog.self,
      request: ControlRequest(operation: .listRules),
      retryReadOnDisconnect: true
    )
  }

  public func fetchRuleProviders() async throws -> ControllerRuleProviderCatalog {
    try await decode(
      ControllerRuleProviderCatalog.self,
      request: ControlRequest(operation: .listRuleProviders),
      retryReadOnDisconnect: true
    )
  }

  public func fetchConnections() async throws -> ControllerConnectionsFrame {
    try await decode(
      ControllerConnectionsFrame.self,
      request: ControlRequest(operation: .listConnections),
      retryReadOnDisconnect: true
    )
  }

  /// Applies an outbound mode and verifies controller-owned runtime truth.
  /// Global mode first ensures the built-in GLOBAL selector resolves through
  /// a real proxy rather than DIRECT/REJECT/PASS or a selector cycle.
  public func applyOutboundMode(_ mode: ControllerOutboundMode) async throws -> ControllerSnapshot {
    try await mutationGate.withLock { [self] in
      try await applyOutboundModeLocked(mode)
    }
  }

  private func applyOutboundModeLocked(
    _ mode: ControllerOutboundMode
  ) async throws -> ControllerSnapshot {
    let before = mode == .global ? try await fetchSnapshot() : nil
    if let before {
      guard let target = before.globalProxyTarget else {
        throw ControlGatewayError.noGlobalProxy
      }
      if before.globalGroup?.now != target {
        try await selectProxyLocked(group: "GLOBAL", proxy: target)
      }
    }

    try await setOutboundModeUnchecked(mode)
    let observed = try await fetchSnapshot()
    guard observed.configs.mode.caseInsensitiveCompare(mode.rawValue) == .orderedSame,
      mode != .global || observed.globalRoutesThroughProxy
    else {
      if mode == .global, let before {
        try await restorePriorRouteOrStop(before)
      }
      throw ControlGatewayError.outboundModeReadbackMismatch
    }
    return observed
  }

  private func setOutboundModeUnchecked(_ mode: ControllerOutboundMode) async throws {
    try await sendMutation(
      ControlRequest(
        operation: .setOutboundMode,
        arguments: ["mode": mode.rawValue]
      ))
  }

  /// Restores the complete route that preceded a failed Global transition.
  /// A non-Global mode is restored before its selector because that makes even
  /// a DIRECT prior selector safe. A prior Global route restores its known-good
  /// selector first. The readback is mandatory; inability to confirm recovery
  /// stops the daemon-owned runtime rather than leaving Global on DIRECT.
  private func restorePriorRouteOrStop(_ prior: ControllerSnapshot) async throws {
    if await restorePriorRoute(prior) {
      return
    }
    do {
      try await sendMutation(ControlRequest(operation: .stopAgent))
    } catch {
      throw ControlGatewayError.unsafeGlobalFailClosedStopFailed
    }
    throw ControlGatewayError.unsafeGlobalRuntimeStopped
  }

  private func restorePriorRoute(_ prior: ControllerSnapshot) async -> Bool {
    guard
      let priorMode = ControllerOutboundMode(rawValue: prior.configs.mode.lowercased()),
      priorMode != .global || prior.globalRoutesThroughProxy
    else {
      return false
    }

    let priorGlobalGroup = prior.globalGroup
    let priorGlobalSelection = priorGlobalGroup?.now ?? ""
    let priorGlobalGroupName =
      priorGlobalGroup?.name.isEmpty == false
      ? priorGlobalGroup?.name ?? "GLOBAL" : "GLOBAL"

    do {
      if priorMode != .global {
        try await setOutboundModeUnchecked(priorMode)
      }
      if !priorGlobalSelection.isEmpty {
        try await sendMutation(
          ControlRequest(
            operation: .selectProxy,
            arguments: ["group": priorGlobalGroupName, "proxy": priorGlobalSelection]
          ))
      }
      if priorMode == .global {
        try await setOutboundModeUnchecked(.global)
      }

      let restored = try await fetchSnapshot()
      guard restored.configs.mode.caseInsensitiveCompare(priorMode.rawValue) == .orderedSame else {
        return false
      }
      if !priorGlobalSelection.isEmpty,
        restored.globalGroup?.now != priorGlobalSelection
      {
        return false
      }
      return priorMode != .global || restored.globalRoutesThroughProxy
    } catch {
      return false
    }
  }

  public func patchConfig(_ patch: RuntimeConfigPatch) async throws {
    try await controllerMutation(
      method: "PATCH",
      target: "/configs",
      body: try patch.encodedPayload()
    )
  }

  public func selectProxy(group: String, proxy: String) async throws {
    try await mutationGate.withLock { [self] in
      try await selectProxyLocked(group: group, proxy: proxy)
    }
  }

  private func selectProxyLocked(group: String, proxy: String) async throws {
    try validateName(group)
    try validateName(proxy)
    let before = try await fetchSnapshot()
    guard let proposed = before.selecting(group: group, proxy: proxy),
      before.configs.mode.caseInsensitiveCompare("global") != .orderedSame
        || proposed.globalRoutesThroughProxy
    else {
      throw ControlGatewayError.invalidProxySelection
    }

    try await sendMutation(
      ControlRequest(
        operation: .selectProxy,
        arguments: ["group": group, "proxy": proxy]
      ))
    let observed = try await fetchSnapshot()
    guard observed.proxy(named: group)?.now == proxy,
      observed.configs.mode.caseInsensitiveCompare("global") != .orderedSame
        || observed.globalRoutesThroughProxy
    else {
      if observed.configs.mode.caseInsensitiveCompare("global") == .orderedSame,
        !observed.globalRoutesThroughProxy
      {
        try await restorePriorRouteOrStop(before)
      } else if let previous = before.proxy(named: group)?.now, !previous.isEmpty {
        try? await sendMutation(
          ControlRequest(
            operation: .selectProxy,
            arguments: ["group": group, "proxy": previous]
          ))
      }
      throw ControlGatewayError.proxySelectionReadbackMismatch
    }
  }

  public func testProxyDelay(
    name: String,
    provider: String? = nil,
    timeoutMilliseconds: Int = 5_000
  ) async throws -> ControllerDelayResult {
    let name = try encodedName(name)
    let path: String
    if let provider {
      path = "/providers/proxies/\(try encodedName(provider))/\(name)/healthcheck"
    } else {
      path = "/proxies/\(name)/delay"
    }
    return try await controllerGET(
      try delayTarget(path: path, timeoutMilliseconds: timeoutMilliseconds),
      as: ControllerDelayResult.self
    )
  }

  public func testProxyGroupDelay(
    group: String,
    timeoutMilliseconds: Int = 5_000
  ) async throws -> [String: Int] {
    let path = "/group/\(try encodedName(group))/delay"
    return try await controllerGET(
      try delayTarget(path: path, timeoutMilliseconds: timeoutMilliseconds),
      as: [String: Int].self
    )
  }

  public func refreshProxyProvider(_ name: String) async throws {
    let name = try encodedName(name)
    try await mutationGate.withLock { [self] in
      let before = try await fetchSnapshot()
      guard before.configs.mode.caseInsensitiveCompare("global") != .orderedSame else {
        throw ControlGatewayError.proxyProviderRefreshRequiresNonGlobalMode
      }
      try await controllerMutation(method: "PUT", target: "/providers/proxies/\(name)")
    }
  }

  public func testProxyProvider(_ name: String) async throws -> [String: Int] {
    let name = try encodedName(name)
    let payload = try await controllerRequest(
      method: "GET",
      target: "/providers/proxies/\(name)/healthcheck",
      retryReadOnDisconnect: true
    )
    guard !payload.isEmpty else { return [:] }
    return try JSONDecoder().decode([String: Int].self, from: payload)
  }

  public func refreshRuleProvider(_ name: String) async throws {
    let name = try encodedName(name)
    try await controllerMutation(method: "PUT", target: "/providers/rules/\(name)")
  }

  public func setRuleDisabled(index: Int, disabled: Bool) async throws {
    guard index >= 0 else { throw ControlGatewayError.invalidControllerName }
    let body = try JSONSerialization.data(
      withJSONObject: [String(index): disabled],
      options: [.sortedKeys]
    )
    try await controllerMutation(method: "PATCH", target: "/rules/disable", body: body)
  }

  public func closeConnection(id: String) async throws {
    let id = try encodedName(id)
    try await controllerMutation(method: "DELETE", target: "/connections/\(id)")
  }

  public func closeAllConnections() async throws {
    try await sendMutation(ControlRequest(operation: .closeAllConnections))
  }

  public func flushFakeIPCache() async throws {
    try await controllerMutation(method: "POST", target: "/cache/fakeip/flush")
  }

  public func flushDNSCache() async throws {
    try await controllerMutation(method: "POST", target: "/cache/dns/flush")
  }

  public func updateGeoData() async throws {
    try await controllerMutation(method: "POST", target: "/configs/geo")
  }

  public func reloadActiveProfile() async throws {
    try await sendMutation(ControlRequest(operation: .reloadProfile))
  }

  public func restartAgent() async throws {
    try await sendMutation(ControlRequest(operation: .restartAgent))
  }

  func stopAgentForUnsafeGlobal() async throws {
    try await sendMutation(ControlRequest(operation: .stopAgent))
  }

  public func connectionsStream() -> AsyncThrowingStream<ControllerConnectionsFrame, Error> {
    stream(target: "/connections", bufferingPolicy: .bufferingNewest(1))
  }

  public func trafficStream() -> AsyncThrowingStream<ControllerTrafficFrame, Error> {
    stream(target: "/traffic", bufferingPolicy: .bufferingNewest(1))
  }

  public func memoryStream() -> AsyncThrowingStream<ControllerMemoryFrame, Error> {
    stream(target: "/memory", bufferingPolicy: .bufferingNewest(1))
  }

  public func logsStream(
    level: ControllerLogLevel
  ) -> AsyncThrowingStream<ControllerLogFrame, Error> {
    stream(target: "/logs?level=\(level.rawValue)", bufferingPolicy: .bufferingNewest(512))
  }

  private func stream<Element: Decodable & Sendable>(
    target: String,
    bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy
  ) -> AsyncThrowingStream<Element, Error> {
    let worker = ControllerStreamWorker<Element>(target: target, makeSession: makeSession)
    return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
      continuation.onTermination = { @Sendable _ in worker.cancel() }
      worker.start(continuation)
    }
  }

  private func controllerGET<Value: Decodable>(
    _ target: String,
    as type: Value.Type
  ) async throws -> Value {
    let payload = try await controllerRequest(
      method: "GET",
      target: target,
      retryReadOnDisconnect: true
    )
    guard !payload.isEmpty else { throw ControlGatewayError.missingPayload }
    return try JSONDecoder().decode(type, from: payload)
  }

  private func controllerMutation(method: String, target: String, body: Data? = nil) async throws {
    _ = try await controllerRequest(
      method: method,
      target: target,
      body: body,
      retryReadOnDisconnect: false
    )
  }

  private func controllerRequest(
    method: String,
    target: String,
    body: Data? = nil,
    retryReadOnDisconnect: Bool
  ) async throws -> Data {
    try await channel.send(
      ControlRequest(
        operation: .controllerRequest,
        arguments: ["method": method, "target": target],
        payload: body
      ),
      retryReadOnDisconnect: retryReadOnDisconnect
    )
  }

  private func sendMutation(_ request: ControlRequest) async throws {
    _ = try await channel.send(request, retryReadOnDisconnect: false)
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type,
    request: ControlRequest,
    retryReadOnDisconnect: Bool
  ) async throws -> Value {
    let payload = try await channel.send(request, retryReadOnDisconnect: retryReadOnDisconnect)
    guard !payload.isEmpty else { throw ControlGatewayError.missingPayload }
    return try JSONDecoder().decode(type, from: payload)
  }

  private func delayTarget(path: String, timeoutMilliseconds: Int) throws -> String {
    guard ControllerRequestPolicy.delayTimeoutRange.contains(timeoutMilliseconds) else {
      throw ControlGatewayError.invalidTimeout
    }
    var components = URLComponents()
    components.percentEncodedPath = path
    components.queryItems = [
      URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
      URLQueryItem(name: "url", value: ControllerRequestPolicy.latencyProbe),
    ]
    guard let target = components.string else {
      throw ControlGatewayError.invalidControllerName
    }
    return target
  }

  private func encodedName(_ value: String) throws -> String {
    try validateName(value)
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw ControlGatewayError.invalidControllerName
    }
    return encoded
  }

  private func validateName(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= Self.maximumControllerNameBytes,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ControlGatewayError.invalidControllerName
    }
  }
}

extension ControllerSnapshot {
  fileprivate var globalGroup: ControllerProxy? {
    if let exact = proxies.proxies["GLOBAL"] { return exact }
    return proxies.proxies.first { key, _ in
      key.caseInsensitiveCompare("GLOBAL") == .orderedSame
    }?.value
  }

  var globalProxyTarget: String? {
    guard let globalGroup else { return nil }
    if !globalGroup.now.isEmpty, targetRoutesThroughProxy(globalGroup.now, visited: []) {
      return globalGroup.now
    }

    let nestedGroup = globalGroup.all.first { candidate in
      guard let group = proxy(named: candidate), !group.all.isEmpty,
        candidate.caseInsensitiveCompare("GLOBAL") != .orderedSame
      else {
        return false
      }
      return targetRoutesThroughProxy(candidate, visited: [])
    }
    return nestedGroup
      ?? globalGroup.all.first {
        targetRoutesThroughProxy($0, visited: [])
      }
  }

  var globalRoutesThroughProxy: Bool {
    guard let globalGroup, !globalGroup.now.isEmpty else { return false }
    return targetRoutesThroughProxy(globalGroup.now, visited: [])
  }

  func proxy(named name: String) -> ControllerProxy? {
    proxies.proxies[name]
  }

  func selecting(group name: String, proxy target: String) -> ControllerSnapshot? {
    guard var group = proxies.proxies[name], group.all.contains(target) else {
      return nil
    }
    group.now = target
    var copy = self
    copy.proxies.proxies[name] = group
    return copy
  }

  private func targetRoutesThroughProxy(_ target: String, visited: Set<String>) -> Bool {
    let builtins = Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS"])
    guard !builtins.contains(target.uppercased()) else { return false }
    guard let group = proxy(named: target) else { return false }
    guard !group.all.isEmpty else { return true }

    let key = group.name
    guard !visited.contains(key), !group.now.isEmpty else { return false }
    var nextVisited = visited
    nextVisited.insert(key)
    return targetRoutesThroughProxy(group.now, visited: nextVisited)
  }
}
