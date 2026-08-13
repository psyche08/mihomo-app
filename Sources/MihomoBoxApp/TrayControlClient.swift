import Foundation
import MihomoBoxUI
import MihomoControl

protocol AppControlSession: AnyObject, Sendable {
  func send(_ request: ControlRequest) throws -> ControlResponse
}

extension MihomoControlSession: AppControlSession {}

typealias AppControlSessionFactory = @Sendable () throws -> any AppControlSession

struct TrayControlPoll: Sendable {
  var agentRunning: Bool
  var controllerReachable: Bool
  var enhancedTUN: Bool
  var networkHealthy: Bool?
  var systemDNSManaged: Bool?
  var healthTUNEnabled: Bool?
  var outboundMode: TrayOutboundMode
  var proxies: [TrayProxyNode]
  var profiles: [String]
  var activeProfile: String?
}

enum TrayControlError: Error, LocalizedError {
  case missingPayload
  case invalidResponse
  case readbackMismatch(String)

  var errorDescription: String? {
    switch self {
    case .missingPayload: "the daemon returned an empty response"
    case .invalidResponse: "the daemon returned an invalid tray response"
    case .readbackMismatch(let action): "the daemon did not confirm \(action)"
    }
  }
}

/// Retained, serialized XPC access for the App shell.
///
/// The gateway remains the owner of selector-chain safety. This actor owns the
/// remaining lifecycle/profile/component operations and their mandatory
/// daemon-owned readback. It never starts `mihomoboxctl` or talks to a
/// controller endpoint directly.
actor TrayControlClient {
  private let makeSession: AppControlSessionFactory
  private let gateway: ControlGateway
  private var session: (any AppControlSession)?

  init(
    makeSession: @escaping AppControlSessionFactory = { try MihomoControlSession() },
    gateway: ControlGateway = ControlGateway()
  ) {
    self.makeSession = makeSession
    self.gateway = gateway
  }

  func poll() throws -> TrayControlPoll {
    let payload = try send(ControlRequest(operation: .trayState), retryReadOnce: true)
    guard !payload.isEmpty else { throw TrayControlError.missingPayload }
    return try Self.decodePoll(payload)
  }

  func enableEnhancedTUN() throws -> TrayControlPoll {
    _ = try send(
      ControlRequest(operation: .setTUN, arguments: ["enabled": "true"]),
      retryReadOnce: false
    )
    let observed = try poll()
    guard observed.controllerReachable, observed.enhancedTUN else {
      throw TrayControlError.readbackMismatch("Enhanced TUN")
    }
    return observed
  }

  func startAgent() throws -> TrayControlPoll? {
    _ = try send(ControlRequest(operation: .startAgent), retryReadOnce: false)
    return try? poll()
  }

  func stopAgentAndRestore() async throws -> TrayControlPoll {
    _ = try send(ControlRequest(operation: .stopAgent), retryReadOnce: false)
    for attempt in 0..<30 {
      if let observed = try? poll(),
        !observed.agentRunning, !observed.controllerReachable,
        observed.healthTUNEnabled == false, observed.systemDNSManaged == false,
        observed.networkHealthy == true
      {
        return observed
      }
      if attempt < 29 {
        try await Task.sleep(for: .milliseconds(500))
      }
    }
    throw TrayControlError.readbackMismatch("the network restore")
  }

  func setOutboundMode(_ mode: TrayOutboundMode) async throws -> TrayControlPoll {
    let mapped = ControllerOutboundMode(rawValue: mode.rawValue) ?? .rule
    _ = try await gateway.applyOutboundModeWhileHoldingAppMutation(mapped)
    // The daemon already completed mutation and authoritative readback in one
    // serialized transaction. This poll is display refresh only: another
    // signed client may legitimately change mode after the transaction, and
    // the tray must show that newer truth rather than undoing or rejecting it.
    return try poll()
  }

  func selectProxy(group: String, name: String) async throws -> TrayControlPoll {
    try await gateway.selectProxyWhileHoldingAppMutation(group: group, proxy: name)
    return try poll()
  }

  func testDelays(names: [String]) throws -> Int {
    guard !names.isEmpty else { return 0 }
    let payload = try JSONEncoder().encode(names)
    let result = try send(
      ControlRequest(operation: .testDelay, payload: payload),
      retryReadOnce: false
    )
    return (try? JSONDecoder().decode(DelayResult.self, from: result).succeeded) ?? 0
  }

  func listProfiles() throws -> ProfileList {
    let payload = try send(ControlRequest(operation: .listProfiles), retryReadOnce: true)
    guard !payload.isEmpty else { throw TrayControlError.missingPayload }
    return try JSONDecoder().decode(ProfileList.self, from: payload)
  }

  func importProfile(name: String, bytes: Data, activate: Bool) throws -> ProfileList {
    try profileOperation(
      ControlRequest(
        operation: .importProfile,
        arguments: ["name": name, "activate": String(activate)],
        payload: bytes
      )
    )
  }

  func switchProfile(name: String) throws -> ProfileList {
    try profileOperation(
      ControlRequest(operation: .switchProfile, arguments: ["name": name])
    )
  }

  func reloadProfile() throws -> ProfileList {
    try profileOperation(ControlRequest(operation: .reloadProfile))
  }

  func componentStatus() throws -> ComponentStatus {
    let payload = try send(ControlRequest(operation: .componentStatus), retryReadOnce: true)
    guard !payload.isEmpty else { throw TrayControlError.missingPayload }
    return try JSONDecoder().decode(ComponentStatus.self, from: payload)
  }

  func upgradeComponents(_ package: ComponentUpdatePackage, daemonWillRestart: Bool) throws {
    do {
      _ = try send(
        ControlRequest(operation: .upgradeComponents, payload: try package.encoded()),
        retryReadOnce: false
      )
    } catch let error as ControlError where daemonWillRestart && error.isDisconnection {
      return
    }
  }

  private func profileOperation(_ request: ControlRequest) throws -> ProfileList {
    let payload = try send(request, retryReadOnce: false)
    guard !payload.isEmpty else { throw TrayControlError.missingPayload }
    return try JSONDecoder().decode(ProfileList.self, from: payload)
  }

  private func send(_ request: ControlRequest, retryReadOnce: Bool) throws -> Data {
    let attempts = retryReadOnce ? 2 : 1
    for attempt in 0..<attempts {
      do {
        if session == nil { session = try makeSession() }
        return try session?.send(request).payload ?? Data()
      } catch let error as ControlError where error.isDisconnection {
        session = nil
        if attempt + 1 == attempts { throw error }
      }
    }
    throw ControlError.connectionFailed
  }

  static func decodePoll(_ data: Data) throws -> TrayControlPoll {
    let envelope = try JSONDecoder().decode(TrayStateEnvelope.self, from: data)
    guard let snapshot = envelope.snapshot else {
      return TrayControlPoll(
        agentRunning: envelope.agentRunning,
        controllerReachable: false,
        enhancedTUN: false,
        networkHealthy: envelope.health?.networkConsistent,
        systemDNSManaged: envelope.health?.systemDNSManaged,
        healthTUNEnabled: envelope.health?.tunEnabled,
        outboundMode: .rule,
        proxies: [],
        profiles: envelope.profiles.profiles,
        activeProfile: envelope.profiles.activeProfile
      )
    }

    let groups = snapshot.proxies.proxies.filter { !$0.value.all.isEmpty }
    let groupNames = Set(groups.keys)
    var indexes: [String: Int] = [:]
    var nodes: [TrayProxyNode] = []
    for (groupName, group) in groups.sorted(by: { $0.key < $1.key })
    where groupName.caseInsensitiveCompare("GLOBAL") != .orderedSame {
      for name in group.all where !isBuiltin(name) && !groupNames.contains(name) {
        let delay = snapshot.proxies.proxies[name]?.history.last?.delay
        let selected = group.now == name
        if let index = indexes[name] {
          if nodes[index].delayMilliseconds == nil { nodes[index].delayMilliseconds = delay }
          if selected {
            nodes[index].group = groupName
            nodes[index].isSelected = true
          }
        } else {
          indexes[name] = nodes.count
          nodes.append(
            TrayProxyNode(
              group: groupName,
              name: name,
              delayMilliseconds: delay.flatMap { $0 > 0 ? $0 : nil },
              isSelected: selected
            ))
        }
      }
    }

    return TrayControlPoll(
      agentRunning: envelope.agentRunning,
      controllerReachable: true,
      enhancedTUN: snapshot.configs.tun.enable,
      networkHealthy: envelope.health?.networkConsistent,
      systemDNSManaged: envelope.health?.systemDNSManaged,
      healthTUNEnabled: envelope.health?.tunEnabled,
      outboundMode: TrayOutboundMode(rawValue: snapshot.configs.mode.lowercased()) ?? .rule,
      proxies: nodes,
      profiles: envelope.profiles.profiles,
      activeProfile: envelope.profiles.activeProfile
    )
  }

  private static func isBuiltin(_ name: String) -> Bool {
    ["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(name.uppercased())
  }
}

struct ProfileList: Codable, Equatable, Sendable {
  var profiles: [String]
  var activeProfile: String?

  enum CodingKeys: String, CodingKey {
    case profiles
    case activeProfile = "active_profile"
  }
}

private struct DelayResult: Decodable { var succeeded: Int }
private struct TrayStateEnvelope: Decodable {
  var agentRunning: Bool
  var snapshot: RuntimeSnapshotEnvelope?
  var profiles: ProfileList
  var health: TrayHealth?

  enum CodingKeys: String, CodingKey {
    case agentRunning = "agent_running"
    case snapshot, profiles, health
  }
}
private struct TrayHealth: Decodable {
  var controllerReachable: Bool?
  var tunEnabled: Bool?
  var systemDNSManaged: Bool?
  var networkConsistent: Bool
  enum CodingKeys: String, CodingKey {
    case controllerReachable = "controller_reachable"
    case tunEnabled = "tun_enabled"
    case systemDNSManaged = "system_dns_managed"
    case networkConsistent = "network_consistent"
  }
}
private struct RuntimeSnapshotEnvelope: Decodable {
  var configs: RuntimeConfigs
  var proxies: RuntimeProxyCatalog
}
private struct RuntimeConfigs: Decodable {
  var mode: String
  var tun: RuntimeTUN
}
private struct RuntimeTUN: Decodable { var enable: Bool }
private struct RuntimeProxyCatalog: Decodable { var proxies: [String: RuntimeProxy] }
private struct RuntimeProxy: Decodable {
  var now: String
  var all: [String]
  var history: [RuntimeDelay]

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    now = try values.decodeIfPresent(String.self, forKey: .now) ?? ""
    all = try values.decodeIfPresent([String].self, forKey: .all) ?? []
    history = try values.decodeIfPresent([RuntimeDelay].self, forKey: .history) ?? []
  }

  enum CodingKeys: String, CodingKey { case now, all, history }
}
private struct RuntimeDelay: Decodable { var delay: Int }
