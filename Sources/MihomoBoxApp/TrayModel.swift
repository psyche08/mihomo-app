import Foundation

enum DaemonProtocolCompatibility: Equatable, Sendable {
  case unknown
  case compatible
  case legacyRepairRequired(peerVersion: Int)
  case appUpdateRequired(peerVersion: Int)
  case incompatible(peerVersion: Int)

  var requiresRepair: Bool {
    if case .legacyRepairRequired = self {
      return true
    }
    return false
  }

  var blocksControlActions: Bool {
    switch self {
    case .unknown, .compatible:
      false
    case .legacyRepairRequired, .appUpdateRequired, .incompatible:
      true
    }
  }

  var allowsExplicitInstaller: Bool {
    switch self {
    case .unknown, .compatible, .legacyRepairRequired:
      true
    case .appUpdateRequired, .incompatible:
      false
    }
  }
}

enum TrayOutboundMode: String, CaseIterable, Sendable {
  case rule
  case global
  case direct

  var title: String {
    switch self {
    case .rule: "Rule"
    case .global: "Global"
    case .direct: "Direct"
    }
  }
}

struct TrayProxyID: Hashable, Sendable {
  var group: String
  var name: String
}

struct TrayProxyNode: Equatable, Sendable {
  var group: String
  var name: String
  var delayMilliseconds: Int?
  var isSelected: Bool

  init(
    group: String,
    name: String,
    delayMilliseconds: Int? = nil,
    isSelected: Bool = false
  ) {
    self.group = group
    self.name = name
    self.delayMilliseconds = delayMilliseconds
    self.isSelected = isSelected
  }

  var id: TrayProxyID {
    TrayProxyID(group: group, name: name)
  }

  var menuTitle: String {
    "\(name)    \(Self.delayLabel(delayMilliseconds))"
  }

  static func delayLabel(_ delay: Int?) -> String {
    switch delay {
    case let value? where value > 0 && value <= 300:
      "🟢 \(value) ms"
    case let value? where value > 300 && value <= 800:
      "🟠 \(value) ms"
    case let value? where value > 800:
      "🔴 \(value) ms"
    default:
      "⚪ --"
    }
  }
}

/// A credential-free projection of the authenticated XPC runtime state.
///
/// The tray never receives a controller URL or secret. Service implementations
/// translate only typed daemon results into this value.
struct TraySnapshot: Equatable, Sendable {
  var daemonCompatibility: DaemonProtocolCompatibility
  var controllerReachable: Bool
  var daemonReachable: Bool
  var agentRunning: Bool
  var enhancedTUN: Bool
  var tunOperationInFlight: Bool
  var mutationOperationInFlight: Bool
  var networkHealthy: Bool?
  var systemDNSManaged: Bool?
  var healthTUNEnabled: Bool?
  var outboundMode: TrayOutboundMode
  var proxies: [TrayProxyNode]
  var profiles: [String]
  var activeProfile: String?
  var profileOperationInFlight: Bool
  var profileActionsAvailable: Bool
  var installationActionsAvailable: Bool
  var enhancedTUNActionAvailable: Bool
  var actionError: String?

  init(
    daemonCompatibility: DaemonProtocolCompatibility = .unknown,
    controllerReachable: Bool = false,
    daemonReachable: Bool = false,
    agentRunning: Bool = false,
    enhancedTUN: Bool = false,
    tunOperationInFlight: Bool = false,
    mutationOperationInFlight: Bool = false,
    networkHealthy: Bool? = nil,
    systemDNSManaged: Bool? = nil,
    healthTUNEnabled: Bool? = nil,
    outboundMode: TrayOutboundMode = .rule,
    proxies: [TrayProxyNode] = [],
    profiles: [String] = [],
    activeProfile: String? = nil,
    profileOperationInFlight: Bool = false,
    profileActionsAvailable: Bool = true,
    installationActionsAvailable: Bool = false,
    enhancedTUNActionAvailable: Bool = true,
    actionError: String? = nil
  ) {
    self.daemonCompatibility = daemonCompatibility
    self.controllerReachable = controllerReachable
    self.daemonReachable = daemonReachable
    self.agentRunning = agentRunning
    self.enhancedTUN = enhancedTUN
    self.tunOperationInFlight = tunOperationInFlight
    self.mutationOperationInFlight = mutationOperationInFlight
    self.networkHealthy = networkHealthy
    self.systemDNSManaged = systemDNSManaged
    self.healthTUNEnabled = healthTUNEnabled
    self.outboundMode = outboundMode
    self.proxies = proxies
    self.profiles = profiles
    self.activeProfile = activeProfile
    self.profileOperationInFlight = profileOperationInFlight
    self.profileActionsAvailable = profileActionsAvailable
    self.installationActionsAvailable = installationActionsAvailable
    self.enhancedTUNActionAvailable = enhancedTUNActionAvailable
    self.actionError = actionError
  }

  var networkStatusTitle: String {
    if let actionError, !actionError.isEmpty {
      return actionError
    }
    if tunOperationInFlight {
      return enhancedTUN ? "Network: Stopping…" : "Network: Starting…"
    }
    if profileOperationInFlight {
      return "Network: Applying profile…"
    }
    if mutationOperationInFlight {
      return "Network: Applying change…"
    }
    switch daemonCompatibility {
    case .legacyRepairRequired:
      return "Network: Daemon upgrade required"
    case .appUpdateRequired:
      return "Network: App update required"
    case .incompatible:
      return "Network: Protocol incompatible"
    case .unknown, .compatible:
      break
    }
    if daemonReachable, !agentRunning {
      if !controllerReachable, healthTUNEnabled == false,
        systemDNSManaged == false, networkHealthy == true
      {
        return "Network: Stopped — DNS restored"
      }
      return "Network: Stopped — restore unconfirmed"
    }
    guard controllerReachable else {
      return "Network: Daemon unavailable"
    }
    if networkHealthy == true {
      return "Network: Healthy"
    }
    return "Network: Inconsistent"
  }

  var tooltip: String {
    switch daemonCompatibility {
    case .legacyRepairRequired:
      return "MihomoBox · daemon repair required"
    case .appUpdateRequired:
      return "MihomoBox · app update required"
    case .incompatible:
      return "MihomoBox · protocol incompatible"
    case .unknown, .compatible:
      break
    }
    if daemonReachable, !agentRunning {
      return networkStatusTitle.contains("DNS restored")
        ? "MihomoBox · service stopped, DNS restored"
        : "MihomoBox · service stopped, restore unconfirmed"
    }
    if controllerReachable && networkHealthy == true {
      return "MihomoBox · network healthy"
    }
    if controllerReachable {
      return "MihomoBox · network inconsistent"
    }
    return "MihomoBox · daemon unavailable"
  }

  /// Everything that requires replacing an NSMenu. Latency is intentionally
  /// absent: those labels are safe to repaint in place while AppKit is tracking
  /// a submenu, whereas replacing the menu would collapse it under the cursor.
  var menuSignature: TrayMenuSignature {
    TrayMenuSignature(
      daemonCompatibility: daemonCompatibility,
      controllerReachable: controllerReachable,
      daemonReachable: daemonReachable,
      agentRunning: agentRunning,
      enhancedTUN: enhancedTUN,
      tunOperationInFlight: tunOperationInFlight,
      mutationOperationInFlight: mutationOperationInFlight,
      networkHealthy: networkHealthy,
      systemDNSManaged: systemDNSManaged,
      healthTUNEnabled: healthTUNEnabled,
      outboundMode: outboundMode,
      proxies: proxies.map {
        TrayMenuProxySignature(id: $0.id, isSelected: $0.isSelected)
      },
      profiles: profiles,
      activeProfile: activeProfile,
      profileOperationInFlight: profileOperationInFlight,
      profileActionsAvailable: profileActionsAvailable,
      installationActionsAvailable: installationActionsAvailable,
      enhancedTUNActionAvailable: enhancedTUNActionAvailable,
      actionError: actionError
    )
  }
}

struct TrayMenuProxySignature: Equatable, Sendable {
  var id: TrayProxyID
  var isSelected: Bool
}

struct TrayMenuSignature: Equatable, Sendable {
  var daemonCompatibility: DaemonProtocolCompatibility
  var controllerReachable: Bool
  var daemonReachable: Bool
  var agentRunning: Bool
  var enhancedTUN: Bool
  var tunOperationInFlight: Bool
  var mutationOperationInFlight: Bool
  var networkHealthy: Bool?
  var systemDNSManaged: Bool?
  var healthTUNEnabled: Bool?
  var outboundMode: TrayOutboundMode
  var proxies: [TrayMenuProxySignature]
  var profiles: [String]
  var activeProfile: String?
  var profileOperationInFlight: Bool
  var profileActionsAvailable: Bool
  var installationActionsAvailable: Bool
  var enhancedTUNActionAvailable: Bool
  var actionError: String?
}

enum TrayMenuUpdateDecision: Equatable, Sendable {
  case repaintDelaysOnly
  case rebuildNow
  case repaintDelaysAndDeferRebuild
}

enum TrayMenuUpdatePolicy {
  static func decision(
    rendered: TraySnapshot?,
    incoming: TraySnapshot,
    isTracking: Bool
  ) -> TrayMenuUpdateDecision {
    guard let rendered else { return .rebuildNow }
    guard rendered.menuSignature != incoming.menuSignature else {
      return .repaintDelaysOnly
    }
    return isTracking ? .repaintDelaysAndDeferRebuild : .rebuildNow
  }
}

enum TrayUpdateAvailabilityPolicy {
  static func isEnabled(canCheckForUpdates: Bool) -> Bool {
    canCheckForUpdates
  }
}

enum TrayPollingPolicy {
  static let startupFastAttempts = 20

  static func interval(
    controllerReachable: Bool,
    startupAttempt: Int
  ) -> Duration {
    if !controllerReachable, startupAttempt < startupFastAttempts {
      return .milliseconds(500)
    }
    // Opening the menu and completing a mutation both request an immediate
    // refresh. The background loop only keeps tooltip/state reasonably fresh.
    return controllerReachable ? .seconds(30) : .seconds(10)
  }
}

enum TrayEnhancedTUNClickDecision: Equatable, Sendable {
  case request(enabled: Bool)
  case refreshAuthoritatively
}

enum TrayEnhancedTUNClickPolicy {
  static func decision(
    displayedEnhancedTUN: Bool,
    latestEnhancedTUN: Bool
  ) -> TrayEnhancedTUNClickDecision {
    guard displayedEnhancedTUN == latestEnhancedTUN else {
      return .refreshAuthoritatively
    }
    return .request(enabled: !latestEnhancedTUN)
  }
}

enum TrayMenuActionPolicy {
  static func controllerActionEnabled(_ snapshot: TraySnapshot) -> Bool {
    !snapshot.daemonCompatibility.blocksControlActions
      && snapshot.controllerReachable
      && !snapshot.mutationOperationInFlight
  }

  static func enhancedTUNEnabled(_ snapshot: TraySnapshot) -> Bool {
    !snapshot.daemonCompatibility.blocksControlActions
      && !snapshot.mutationOperationInFlight
      && !snapshot.profileOperationInFlight
      && !snapshot.tunOperationInFlight
      && snapshot.enhancedTUNActionAvailable
  }

  static func profileActionEnabled(_ snapshot: TraySnapshot) -> Bool {
    !snapshot.daemonCompatibility.blocksControlActions
      && snapshot.profileActionsAvailable
      && !snapshot.mutationOperationInFlight
      && !snapshot.profileOperationInFlight
  }

  static func profileReloadEnabled(_ snapshot: TraySnapshot) -> Bool {
    !snapshot.daemonCompatibility.blocksControlActions
      && snapshot.activeProfile != nil
      && snapshot.controllerReachable
      && !snapshot.mutationOperationInFlight
      && !snapshot.profileOperationInFlight
  }

  static func installerEnabled(_ snapshot: TraySnapshot) -> Bool {
    snapshot.daemonCompatibility.allowsExplicitInstaller
      && snapshot.installationActionsAvailable
      && !snapshot.mutationOperationInFlight
  }
}

enum TrayDaemonMenuPolicy {
  static func showsUpgradeAction(_ snapshot: TraySnapshot) -> Bool {
    snapshot.daemonCompatibility.requiresRepair
  }

  static func installerTitle(_ snapshot: TraySnapshot) -> String {
    if snapshot.daemonCompatibility.requiresRepair {
      return "Install / Repair Daemon… (Required)"
    }
    return "Install / Repair Daemon…"
  }
}

/// Typed boundary between AppKit and the authenticated XPC-backed state
/// coordinator. Implementations own polling, readback and action-error state.
@MainActor
protocol TrayService: AnyObject {
  var onSnapshot: (@MainActor (TraySnapshot) -> Void)? { get set }
  var currentSnapshot: TraySnapshot { get }
  var canCheckForUpdates: Bool { get }

  func start()
  func stop()
  func menuWillOpen()
  func refresh(authoritative: Bool)

  func setEnhancedTUNEnabled(_ enabled: Bool) async throws
  func setOutboundMode(_ mode: TrayOutboundMode) async throws
  func selectProxy(group: String, name: String) async throws
  func testProxyDelays() async throws
  func importLocalProfile() async throws
  func importHTTPProfile() async throws
  func switchProfile(named name: String) async throws
  func reloadProfile() async throws
  func installOrRepairDaemon(requireLegacy: Bool) async throws
  func openDiagnosticLogs()
  func checkForUpdates()
}

/// Process-level jobs are intentionally separate from the tray and window.
/// Stopping them cancels only user-process work such as update checks and
/// component reconciliation; it must never stop the root agent or Mihomo.
@MainActor
protocol AppShellCoordinating: AnyObject {
  var trayService: any TrayService { get }

  func startBackgroundServices()
  func stopBackgroundServices()
}
