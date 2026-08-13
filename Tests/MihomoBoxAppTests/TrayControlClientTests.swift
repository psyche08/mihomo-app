import Foundation
import MihomoControl
import XCTest

@testable import MihomoBoxApp

final class TrayControlClientTests: XCTestCase {
  func testStartAgentAcceptsDelayedControllerReadiness() async throws {
    let session = QueueSession(responses: [
      ControlResponse(success: true),
      ControlResponse(success: false, error: "controller not ready"),
    ])
    let client = TrayControlClient(makeSession: { session })
    let immediate = try await client.startAgent()
    XCTAssertNil(immediate)
    XCTAssertEqual(session.operations, [.startAgent, .trayState])
  }

  func testEnableTUNRequiresPositiveReadback() async throws {
    let poll = Data(
      #"""
      {
        "agent_running":true,
        "snapshot":{"configs":{"mode":"Rule","tun":{"enable":false}},"proxies":{"proxies":{}}},
        "profiles":{"profiles":["a.yaml"],"active_profile":"a.yaml"},
        "health":{"network_consistent":true}
      }
      """#.utf8)
    let session = QueueSession(responses: [
      ControlResponse(success: true),
      ControlResponse(success: true, payload: poll),
    ])
    let client = TrayControlClient(makeSession: { session })
    do {
      _ = try await client.enableEnhancedTUN()
      XCTFail("expected readback mismatch")
    } catch let error as TrayControlError {
      guard case .readbackMismatch = error else { return XCTFail("wrong error") }
    }
  }

  func testPassivePollRetainsLastGoodDelayByNodeAcrossDisplayGroupChanges() {
    let previous = [
      TrayProxyNode(group: "Fallback", name: "Tokyo", delayMilliseconds: 86),
      TrayProxyNode(group: "Auto", name: "Never measured"),
    ]
    let incoming = [
      TrayProxyNode(group: "Auto", name: "Tokyo", isSelected: true),
      TrayProxyNode(group: "Fallback", name: "Never measured"),
      TrayProxyNode(group: "Auto", name: "Fresh", delayMilliseconds: 41),
    ]

    let retained = TrayStateCoordinator.retainingKnownDelays(
      in: incoming,
      from: previous
    )

    XCTAssertEqual(retained[0].delayMilliseconds, 86)
    XCTAssertNil(retained[1].delayMilliseconds)
    XCTAssertEqual(retained[2].delayMilliseconds, 41)
    XCTAssertEqual(retained[0].group, "Auto")
    XCTAssertTrue(retained[0].isSelected)
  }
}

private final class QueueSession: AppControlSession, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [ControlResponse]
  private(set) var operations: [ControlOperation] = []

  init(responses: [ControlResponse]) { self.responses = responses }

  func send(_ request: ControlRequest) throws -> ControlResponse {
    lock.lock()
    defer { lock.unlock() }
    operations.append(request.operation)
    guard !responses.isEmpty else { throw ControlError.connectionFailed }
    let response = responses.removeFirst()
    if !response.success { throw ControlError.rejected(response.error ?? "rejected") }
    return response
  }
}
