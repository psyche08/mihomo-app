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

  func testPollDoesNotRetryAuthenticatedProtocolMismatch() async throws {
    let session = ProtocolMismatchSession()
    let client = TrayControlClient(makeSession: { session })

    do {
      _ = try await client.poll()
      XCTFail("expected protocol mismatch")
    } catch let error as ControlError {
      guard case .protocolVersionMismatch(let expected, let received) = error else {
        return XCTFail("unexpected control error: \(error)")
      }
      XCTAssertEqual(expected, mihomoControlProtocolVersion)
      XCTAssertEqual(received, 1)
      XCTAssertTrue(error.isLegacyDaemonProtocol)
      XCTAssertFalse(error.isDisconnection)
    }
    XCTAssertEqual(session.operations, [.trayState])
  }

  func testInstalledProfileEditUsesDaemonActiveStateInsteadOfLocalMirror() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-profile-authority-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("profiles")
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try Data("mode: rule\n".utf8).write(to: profiles.appendingPathComponent("local.yaml"))
    try Data("local.yaml\n".utf8).write(to: root.appendingPathComponent("active-profile"))

    let payload = Data(
      #"{"profiles":["local.yaml","remote.yaml"],"active_profile":"remote.yaml"}"#.utf8
    )
    let session = QueueSession(responses: [
      ControlResponse(success: true, payload: payload),
      ControlResponse(success: true, payload: payload),
    ])
    let client = TrayControlClient(makeSession: { session })
    let coordinator = ProfileCoordinator(control: client, root: root)

    let remoteActive = try await coordinator.editedProfileIsActive(
      named: "remote.yaml",
      daemonInstalled: true
    )
    let localActive = try await coordinator.editedProfileIsActive(
      named: "local.yaml",
      daemonInstalled: true
    )
    XCTAssertTrue(remoteActive)
    XCTAssertFalse(localActive)
    XCTAssertEqual(session.operations, [.listProfiles, .listProfiles])
  }

  func testLocalDoHStatusUsesAuthenticatedTypedResponse() async throws {
    let expected = LocalDoHStatus(
      serverPrepared: true,
      profileInstalled: false,
      profileInspectionSucceeded: true,
      runtimeHealthy: true,
      systemDNSManaged: false,
      installedDomainCount: 12
    )
    let session = QueueSession(responses: [
      ControlResponse(success: true, payload: try JSONEncoder().encode(expected))
    ])
    let client = TrayControlClient(makeSession: { session })

    let observed = try await client.localDoHStatus()

    XCTAssertEqual(observed, expected)
    XCTAssertEqual(session.operations, [.localDoHStatus])
  }

  func testLocalDoHInstallationReturnsCountsButNoDomains() async throws {
    let expected = LocalDoHPlanSummary(
      domainCount: 5_123,
      omittedRuleCount: 2,
      exactDomainApproximationCount: 3,
      expandedGeoSiteRuleCount: 7,
      unrepresentableGeoSiteEntryCount: 11,
      invertedGeoSiteRuleCount: 1
    )
    let encoded = try JSONEncoder().encode(expected)
    XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: ".com"))
    let session = QueueSession(responses: [
      ControlResponse(success: true, payload: encoded)
    ])
    let client = TrayControlClient(makeSession: { session })

    let observed = try await client.installLocalDoH()
    XCTAssertEqual(observed, expected)
    XCTAssertEqual(session.operations, [.installLocalDoH])
  }

  func testLocalDoHRemovalUsesAuthenticatedTypedMutation() async throws {
    let session = QueueSession(responses: [ControlResponse(success: true)])
    let client = TrayControlClient(makeSession: { session })

    try await client.removeLocalDoH()

    XCTAssertEqual(session.operations, [.removeLocalDoH])
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

private final class ProtocolMismatchSession: AppControlSession, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var operations: [ControlOperation] = []

  func send(_ request: ControlRequest) throws -> ControlResponse {
    lock.lock()
    operations.append(request.operation)
    lock.unlock()
    throw ControlError.protocolVersionMismatch(
      expected: mihomoControlProtocolVersion,
      received: 1
    )
  }
}
