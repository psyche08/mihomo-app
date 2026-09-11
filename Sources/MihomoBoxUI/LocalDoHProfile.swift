import Foundation
import MihomoControl

public enum DashboardLocalDoHPhase: Equatable, Sendable {
  case unavailable
  case statusUnavailable
  case off
  case awaitingApproval
  case certificateUntrusted
  case active
  case degraded
  case globalDNSFallback
  case fallbackNeedsProfileRemoval
  case fallbackUnavailable
}

public struct DashboardLocalDoHStatus: Equatable, Sendable {
  public var available: Bool
  public var statusVerified: Bool
  public var serverPrepared: Bool
  public var profileInstalled: Bool
  public var runtimeHealthy: Bool
  public var certificateTrusted: Bool?
  public var systemDNSManaged: Bool?
  public var installedDomainCount: Int
  public var globalDNSFallback: Bool
  public var fallbackProfileRemovalRequired: Bool

  public var confirmedDNSMode: DNSIntegrationMode? {
    guard available, statusVerified else { return nil }
    if globalDNSFallback {
      return !profileInstalled && !fallbackProfileRemovalRequired
        && systemDNSManaged == true ? .globalDNS : nil
    }
    return serverPrepared && profileInstalled && certificateTrusted == true
      && runtimeHealthy ? .localDoH : nil
  }

  public init(
    available: Bool,
    statusVerified: Bool = true,
    serverPrepared: Bool = false,
    profileInstalled: Bool = false,
    runtimeHealthy: Bool = false,
    systemDNSManaged: Bool? = nil,
    installedDomainCount: Int = 0,
    globalDNSFallback: Bool = false,
    fallbackProfileRemovalRequired: Bool = false,
    certificateTrusted: Bool? = nil
  ) {
    self.available = available
    self.statusVerified = statusVerified
    self.serverPrepared = serverPrepared
    self.profileInstalled = profileInstalled
    self.runtimeHealthy = runtimeHealthy
    self.certificateTrusted = certificateTrusted
    self.systemDNSManaged = systemDNSManaged
    self.installedDomainCount = installedDomainCount
    self.globalDNSFallback = globalDNSFallback
    self.fallbackProfileRemovalRequired = fallbackProfileRemovalRequired
  }

  public var phase: DashboardLocalDoHPhase {
    guard available else { return .unavailable }
    if globalDNSFallback {
      if fallbackProfileRemovalRequired { return .fallbackNeedsProfileRemoval }
      return systemDNSManaged == true ? .globalDNSFallback : .fallbackUnavailable
    }
    guard statusVerified else { return .statusUnavailable }
    if serverPrepared && profileInstalled && certificateTrusted == false {
      return .certificateUntrusted
    }
    if serverPrepared && profileInstalled && runtimeHealthy && certificateTrusted == true { return .active }
    if serverPrepared && !profileInstalled { return .awaitingApproval }
    if serverPrepared || profileInstalled { return .degraded }
    return .off
  }
}

@MainActor
public protocol DashboardLocalDoHService: AnyObject {
  func status() async -> DashboardLocalDoHStatus
  func prepare() async throws -> LocalDoHPlanSummary
  func trustCertificate() async throws
  func setDNSMode(_ mode: DNSIntegrationMode) async throws
  func openKeychainAccess() async throws
  func openDeviceManagement() async throws
}
