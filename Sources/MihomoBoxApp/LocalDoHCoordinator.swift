import AppKit
import Foundation
import MihomoBoxUI
import MihomoControl

@MainActor
final class LocalDoHCoordinator: DashboardLocalDoHService {
  private static let deviceManagementURL = URL(
    string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
  )!
  private let control: TrayControlClient

  init(control: TrayControlClient = TrayControlClient()) {
    self.control = control
  }

  func status() async -> DashboardLocalDoHStatus {
    do {
      let root = try await control.localDoHStatus()
      return DashboardLocalDoHStatus(
        available: true,
        statusVerified: root.profileInspectionSucceeded,
        serverPrepared: root.serverPrepared,
        profileInstalled: root.profileInstalled,
        runtimeHealthy: root.runtimeHealthy,
        systemDNSManaged: root.systemDNSManaged,
        installedDomainCount: root.installedDomainCount > 0
          ? root.installedDomainCount : root.preparedDomainCount
      )
    } catch {
      return DashboardLocalDoHStatus(
        available: false,
        statusVerified: false
      )
    }
  }

  func prepare() async throws -> LocalDoHPlanSummary {
    let summary = try await control.installLocalDoH()
    let url = URL(fileURLWithPath: LocalDoHProfileDocument.managedProfilePath)
    let profileOpened = NSWorkspace.shared.open(url)
    let settingsOpened = NSWorkspace.shared.open(Self.deviceManagementURL)
    guard profileOpened && settingsOpened else {
      throw NSError(
        domain: "MihomoBoxLocalDoH",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The local DoH profile was generated, but macOS did not open Device Management."
        ]
      )
    }
    return summary
  }

  func remove() async throws {
    try await control.removeLocalDoH()
  }

  func openDeviceManagement() async throws {
    guard NSWorkspace.shared.open(Self.deviceManagementURL) else {
      throw NSError(
        domain: "MihomoBoxLocalDoH",
        code: 4,
        userInfo: [
          NSLocalizedDescriptionKey:
            "macOS did not open General > Device Management in System Settings."
        ]
      )
    }
  }
}
