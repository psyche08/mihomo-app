import Foundation
import MihomoControl

public enum DashboardLocalDoHPhase: Equatable, Sendable {
  case unavailable
  case statusUnavailable
  case off
  case awaitingApproval
  case active
  case degraded
}

public struct DashboardLocalDoHStatus: Equatable, Sendable {
  public var available: Bool
  public var statusVerified: Bool
  public var serverPrepared: Bool
  public var profileInstalled: Bool
  public var runtimeHealthy: Bool
  public var systemDNSManaged: Bool?
  public var installedDomainCount: Int

  public init(
    available: Bool,
    statusVerified: Bool = true,
    serverPrepared: Bool = false,
    profileInstalled: Bool = false,
    runtimeHealthy: Bool = false,
    systemDNSManaged: Bool? = nil,
    installedDomainCount: Int = 0
  ) {
    self.available = available
    self.statusVerified = statusVerified
    self.serverPrepared = serverPrepared
    self.profileInstalled = profileInstalled
    self.runtimeHealthy = runtimeHealthy
    self.systemDNSManaged = systemDNSManaged
    self.installedDomainCount = installedDomainCount
  }

  public var phase: DashboardLocalDoHPhase {
    guard available else { return .unavailable }
    guard statusVerified else { return .statusUnavailable }
    if serverPrepared && profileInstalled && runtimeHealthy { return .active }
    if serverPrepared && !profileInstalled && runtimeHealthy { return .awaitingApproval }
    if serverPrepared || profileInstalled { return .degraded }
    return .off
  }
}

@MainActor
public protocol DashboardLocalDoHService: AnyObject {
  func status() async -> DashboardLocalDoHStatus
  func prepare() async throws -> LocalDoHPlanSummary
  func openDeviceManagement() async throws
  func remove() async throws
}
