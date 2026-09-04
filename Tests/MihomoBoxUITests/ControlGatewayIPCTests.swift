import Foundation
import MihomoControl
import XCTest

@testable import MihomoBoxUI

final class ControlGatewayIPCTests: XCTestCase {
  func testReadRequestsMapToTypedXPCOperationsAndDecodePayloads() async throws {
    let session = ScriptedControlSession(steps: [
      .success(json: #"{"version":"v1.19.30","meta":true}"#),
      .success(json: #"{"mode":"rule","allow-lan":true,"tun":{"enable":true}}"#),
    ])
    let factory = ControlSessionFactoryBox(sessions: [session])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    let version = try await gateway.fetchVersion()
    let config = try await gateway.fetchConfig()

    XCTAssertEqual(version.version, "v1.19.30")
    XCTAssertTrue(version.meta)
    XCTAssertEqual(config.mode, "rule")
    XCTAssertTrue(config.allowLAN)
    XCTAssertTrue(config.tun.enable)
    XCTAssertEqual(factory.makeCount, 1, "ordinary reads should reuse one retained XPC session")

    let requests = session.recordedRequests
    XCTAssertEqual(requests.count, 2)
    assertRequest(requests[0], operation: .controllerVersion)
    assertRequest(
      requests[1],
      operation: .controllerRequest,
      arguments: ["method": "GET", "target": "/configs"]
    )
  }

  func testReadReconnectsOnceAfterDisconnection() async throws {
    let disconnected = ScriptedControlSession(steps: [.failure(.connectionFailed)])
    let recovered = ScriptedControlSession(steps: [
      .success(json: #"{"version":"v1.19.30"}"#)
    ])
    let factory = ControlSessionFactoryBox(sessions: [disconnected, recovered])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    let version = try await gateway.fetchVersion()

    XCTAssertEqual(version.version, "v1.19.30")
    XCTAssertEqual(factory.makeCount, 2)
    XCTAssertEqual(disconnected.recordedRequests.map(\.operation), [.controllerVersion])
    XCTAssertEqual(recovered.recordedRequests.map(\.operation), [.controllerVersion])
  }

  func testRuntimeConfigMutationsMapExactRequestArgumentsAndBodies() async throws {
    let cases: [(RuntimeConfigPatch, String)] = [
      (.allowLAN(true), #"{"allow-lan":true}"#),
      (.logLevel(.debug), #"{"log-level":"debug"}"#),
      (.tcpConcurrent(true), #"{"tcp-concurrent":true}"#),
      (.findProcessMode(.always), #"{"find-process-mode":"always"}"#),
    ]
    let session = ScriptedControlSession(
      steps: cases.map { _ in .success() }
    )
    let factory = ControlSessionFactoryBox(sessions: [session])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    for (patch, _) in cases {
      try await gateway.patchConfig(patch)
    }

    XCTAssertEqual(session.recordedRequests.count, cases.count)
    for (request, expected) in zip(session.recordedRequests, cases.map(\.1)) {
      assertRequest(
        request,
        operation: .controllerRequest,
        arguments: ["method": "PATCH", "target": "/configs"],
        expectsPayload: true
      )
      let body = try XCTUnwrap(request.payload)
      XCTAssertEqual(String(data: body, encoding: .utf8), expected)
    }
  }

  func testMutationDoesNotRetryAfterDisconnection() async {
    let disconnected = ScriptedControlSession(steps: [.failure(.connectionFailed)])
    let unused = ScriptedControlSession(steps: [.success()])
    let factory = ControlSessionFactoryBox(sessions: [disconnected, unused])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    do {
      try await gateway.patchConfig(.allowLAN(true))
      XCTFail("a disconnected mutation must fail instead of being replayed")
    } catch let error as ControlError {
      XCTAssertTrue(error.isDisconnection)
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(disconnected.recordedRequests.count, 1)
    XCTAssertTrue(unused.recordedRequests.isEmpty)
  }

  func testProxySelectionDecodesDaemonAuthoritativeTransactionResult() async throws {
    let after = """
      {
        "configs":{"mode":"rule"},
        "proxies":{"proxies":{
          "Auto":{"type":"Selector","now":"Node B","all":["Node A","Node B"]},
          "Node A":{"type":"VLESS"},
          "Node B":{"type":"VLESS"}
        }}
      }
      """
    let session = ScriptedControlSession(steps: [.success(json: after)])
    let factory = ControlSessionFactoryBox(sessions: [session])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    try await gateway.selectProxy(group: "Auto", proxy: "Node B")

    let requests = session.recordedRequests
    XCTAssertEqual(requests.count, 1)
    assertRequest(
      requests[0],
      operation: .selectProxy,
      arguments: ["group": "Auto", "proxy": "Node B"]
    )
  }

  func testProxyProviderRefreshUsesTypedDaemonMutationAfterNonGlobalReadback() async throws {
    let session = ScriptedControlSession(steps: [
      .success(json: routeSnapshot(mode: "rule", globalNow: "Auto")),
      .success(),
    ])
    let factory = ControlSessionFactoryBox(sessions: [session])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    try await gateway.refreshProxyProvider("Subscription")

    XCTAssertEqual(session.recordedRequests.map(\.operation), [
      .snapshot, .refreshProxyProvider,
    ])
    assertRequest(
      session.recordedRequests[1],
      operation: .refreshProxyProvider,
      arguments: ["name": "Subscription"]
    )
  }

  func testRouteMutationsRemainWholeTransactionsAcrossGatewayInstances() async throws {
    let firstMutationEntered = expectation(description: "first route mutation entered")
    let session = InterleavingRouteControlSession {
      firstMutationEntered.fulfill()
    }
    let factory = ControlSessionFactoryBox(sessions: [session, session])
    let trayGateway = ControlGateway(makeSession: { try factory.makeSession() })
    let dashboardGateway = ControlGateway(makeSession: { try factory.makeSession() })

    let modeTask = Task { try await trayGateway.applyOutboundMode(.global) }
    await fulfillment(of: [firstMutationEntered], timeout: 2)

    let selectionTask = Task {
      try await dashboardGateway.selectProxy(group: "Auto", proxy: "Node B")
    }
    let providerTask = Task { () -> String in
      do {
        try await dashboardGateway.refreshProxyProvider("Subscription")
        return "success"
      } catch let error as ControlGatewayError {
        return String(describing: error)
      } catch {
        return "unexpected: \(error)"
      }
    }

    // The first typed XPC mutation is deliberately blocked. Competing App
    // entry points must stay behind the process gate, while the daemon owns the
    // complete route transaction represented by that single request.
    try await Task.sleep(nanoseconds: 50_000_000)
    session.releaseFirstMutation()

    let modeSnapshot = try await modeTask.value
    try await selectionTask.value
    let providerResult = await providerTask.value

    XCTAssertEqual(modeSnapshot.configs.mode, "global")
    XCTAssertTrue(modeSnapshot.globalRoutesThroughProxy)
    XCTAssertEqual(
      providerResult,
      String(describing: ControlGatewayError.proxyProviderRefreshRequiresNonGlobalMode)
    )

    let operations = session.recordedRequests.map(\.operation)
    XCTAssertGreaterThanOrEqual(operations.count, 3)
    XCTAssertEqual(
      Array(operations.prefix(3)),
      [.setOutboundMode, .selectProxy, .snapshot],
      "a competing selector or provider transaction interleaved with Global mode"
    )
    XCTAssertEqual(factory.makeCount, 2)
  }

  func testUnsafeGlobalFailureIsOwnedByDaemonWithoutClientRollbackOrStop() async throws {
    let session = ScriptedControlSession(steps: [
      .failure(.rejected("the unsafe Global runtime was stopped"))
    ])
    let factory = ControlSessionFactoryBox(sessions: [session])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    do {
      _ = try await gateway.applyOutboundMode(.global)
      XCTFail("an unsafe Global result must be rejected by the daemon")
    } catch let error as ControlError {
      guard case let .rejected(message) = error else {
        return XCTFail("unexpected control error: \(error)")
      }
      XCTAssertEqual(message, "the unsafe Global runtime was stopped")
    }

    XCTAssertEqual(session.recordedRequests.map(\.operation), [.setOutboundMode])
    XCTAssertEqual(factory.makeCount, 1, "a rejected mutation must not be replayed")
  }

  func testStreamUsesIndependentSessionAndClosesItOnCancellation() async throws {
    let ordinarySession = ScriptedControlSession(steps: [
      .success(json: #"{"version":"v1.19.30"}"#)
    ])
    let streamClosed = expectation(description: "controller stream closed")
    let streamSession = BlockingStreamControlSession(
      frame: Data(#"{"up":123,"down":456}"#.utf8),
      onClose: { streamClosed.fulfill() }
    )
    let factory = ControlSessionFactoryBox(sessions: [ordinarySession, streamSession])
    let gateway = ControlGateway(makeSession: { try factory.makeSession() })

    _ = try await gateway.fetchVersion()
    let frameReceived = expectation(description: "traffic frame received")
    let receivedFrame = LockedBox<ControllerTrafficFrame>()
    let consumer = Task {
      do {
        for try await frame in gateway.trafficStream() {
          receivedFrame.value = frame
          frameReceived.fulfill()
        }
      } catch is CancellationError {
        // Expected when the consuming task terminates the AsyncThrowingStream.
      } catch {
        if !Task.isCancelled {
          XCTFail("unexpected stream error: \(error)")
        }
      }
    }

    await fulfillment(of: [frameReceived], timeout: 2)
    consumer.cancel()
    await fulfillment(of: [streamClosed], timeout: 2)
    _ = await consumer.result

    XCTAssertEqual(receivedFrame.value, ControllerTrafficFrame(up: 123, down: 456))
    XCTAssertEqual(factory.makeCount, 2)
    XCTAssertEqual(ordinarySession.recordedRequests.map(\.operation), [.controllerVersion])

    let streamRequests = streamSession.recordedRequests
    XCTAssertEqual(streamRequests.first?.operation, .controllerStreamOpen)
    XCTAssertEqual(streamRequests.first?.arguments, ["target": "/traffic"])
    XCTAssertTrue(streamRequests.contains { $0.operation == .controllerStreamNext })
    XCTAssertEqual(streamRequests.last?.operation, .controllerStreamClose)
    XCTAssertEqual(
      streamRequests.last?.arguments,
      ["session": BlockingStreamControlSession.identifier]
    )
  }

  private func assertRequest(
    _ request: ControlRequest,
    operation: ControlOperation,
    arguments: [String: String] = [:],
    expectsPayload: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(request.version, mihomoControlProtocolVersion, file: file, line: line)
    XCTAssertEqual(request.operation, operation, file: file, line: line)
    XCTAssertEqual(request.arguments, arguments, file: file, line: line)
    if expectsPayload {
      XCTAssertNotNil(request.payload, file: file, line: line)
    } else {
      XCTAssertNil(request.payload, file: file, line: line)
    }
  }

  private func routeSnapshot(mode: String, globalNow: String) -> String {
    """
    {
      "configs":{"mode":"\(mode)"},
      "proxies":{"proxies":{
        "GLOBAL":{"type":"Selector","now":"\(globalNow)","all":["DIRECT","Node A"]},
        "Node A":{"type":"VLESS"},
        "DIRECT":{"type":"Direct"}
      }}
    }
    """
  }
}

private final class ScriptedControlSession: ControlSessionProtocol, @unchecked Sendable {
  enum Step {
    case success(payload: Data?)
    case failure(ControlError)

    static func success(json: String? = nil) -> Step {
      .success(payload: json.map { Data($0.utf8) })
    }
  }

  private let lock = NSLock()
  private var steps: [Step]
  private var requests: [ControlRequest] = []

  init(steps: [Step]) {
    self.steps = steps
  }

  var recordedRequests: [ControlRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func send(_ request: ControlRequest) throws -> ControlResponse {
    lock.lock()
    requests.append(request)
    guard !steps.isEmpty else {
      lock.unlock()
      throw ControlError.invalidReply
    }
    let step = steps.removeFirst()
    lock.unlock()

    switch step {
    case .success(let payload):
      return ControlResponse(success: true, payload: payload)
    case .failure(let error):
      throw error
    }
  }
}

private final class BlockingStreamControlSession: ControlSessionProtocol, @unchecked Sendable {
  static let identifier = "89E72B2F-1DC0-4F7E-AAC6-3BCA27B2D557"

  private let condition = NSCondition()
  private let frame: Data
  private let onClose: () -> Void
  private var requests: [ControlRequest] = []
  private var nextCount = 0
  private var closed = false

  init(frame: Data, onClose: @escaping () -> Void) {
    self.frame = frame
    self.onClose = onClose
  }

  var recordedRequests: [ControlRequest] {
    condition.lock()
    defer { condition.unlock() }
    return requests
  }

  func send(_ request: ControlRequest) throws -> ControlResponse {
    condition.lock()
    requests.append(request)
    switch request.operation {
    case .controllerStreamOpen:
      condition.unlock()
      let payload = Data(#"{"session":"89E72B2F-1DC0-4F7E-AAC6-3BCA27B2D557"}"#.utf8)
      return ControlResponse(success: true, payload: payload)
    case .controllerStreamNext:
      nextCount += 1
      if nextCount == 1 {
        condition.unlock()
        return ControlResponse(success: true, payload: frame)
      }
      while !closed {
        condition.wait()
      }
      condition.unlock()
      throw ControlError.connectionFailed
    case .controllerStreamClose:
      closed = true
      condition.broadcast()
      condition.unlock()
      onClose()
      return ControlResponse(success: true)
    default:
      condition.unlock()
      throw ControlError.invalidReply
    }
  }
}

private final class InterleavingRouteControlSession: ControlSessionProtocol, @unchecked Sendable {
  private let condition = NSCondition()
  private let onFirstMutation: () -> Void
  private var requests: [ControlRequest] = []
  private var firstMutationReleased = false
  private var firstMutationObserved = false
  private var mode = "rule"
  private var autoSelection = "Node A"

  init(onFirstMutation: @escaping () -> Void) {
    self.onFirstMutation = onFirstMutation
  }

  var recordedRequests: [ControlRequest] {
    condition.lock()
    defer { condition.unlock() }
    return requests
  }

  func releaseFirstMutation() {
    condition.lock()
    firstMutationReleased = true
    condition.broadcast()
    condition.unlock()
  }

  func send(_ request: ControlRequest) throws -> ControlResponse {
    condition.lock()
    requests.append(request)
    switch request.operation {
    case .snapshot:
      let snapshotMode = mode
      let snapshotAutoSelection = autoSelection
      condition.unlock()
      let payload = try snapshotPayload(mode: snapshotMode, autoSelection: snapshotAutoSelection)
      return ControlResponse(success: true, payload: payload)
    case .setOutboundMode:
      guard let requested = request.arguments["mode"] else {
        condition.unlock()
        throw ControlError.invalidReply
      }
      if !firstMutationObserved {
        firstMutationObserved = true
        onFirstMutation()
        while !firstMutationReleased { condition.wait() }
      }
      mode = requested
      let snapshotMode = mode
      let snapshotAutoSelection = autoSelection
      condition.unlock()
      return ControlResponse(
        success: true,
        payload: try snapshotPayload(mode: snapshotMode, autoSelection: snapshotAutoSelection)
      )
    case .selectProxy:
      guard request.arguments["group"] == "Auto",
        let proxy = request.arguments["proxy"]
      else {
        condition.unlock()
        throw ControlError.invalidReply
      }
      autoSelection = proxy
      let snapshotMode = mode
      let snapshotAutoSelection = autoSelection
      condition.unlock()
      return ControlResponse(
        success: true,
        payload: try snapshotPayload(mode: snapshotMode, autoSelection: snapshotAutoSelection)
      )
    case .refreshProxyProvider:
      guard request.arguments == ["name": "Subscription"] else {
        condition.unlock()
        throw ControlError.invalidReply
      }
      condition.unlock()
      return ControlResponse(success: true)
    default:
      condition.unlock()
      throw ControlError.invalidReply
    }
  }

  private func snapshotPayload(mode: String, autoSelection: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "configs": ["mode": mode],
        "proxies": [
          "proxies": [
            "GLOBAL": [
              "type": "Selector", "now": "Auto", "all": ["Auto"],
            ],
            "Auto": [
              "type": "Selector", "now": autoSelection,
              "all": ["Node A", "Node B"],
            ],
            "Node A": ["type": "VLESS"],
            "Node B": ["type": "VLESS"],
          ]
        ],
      ],
      options: [.sortedKeys]
    )
  }
}

private final class ControlSessionFactoryBox: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [any ControlSessionProtocol]
  private var count = 0

  init(sessions: [any ControlSessionProtocol]) {
    self.sessions = sessions
  }

  var makeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func makeSession() throws -> any ControlSessionProtocol {
    lock.lock()
    defer { lock.unlock() }
    guard !sessions.isEmpty else { throw ControlError.connectionFailed }
    count += 1
    return sessions.removeFirst()
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value?

  init(_ value: Value? = nil) {
    storage = value
  }

  var value: Value? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
