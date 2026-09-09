import AppKit
import Foundation
import MihomoBoxUI
import MihomoControl

@MainActor
final class LocalDoHCoordinator: DashboardLocalDoHService {
  private static let deviceManagementURL = URL(
    string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
  )!
  private let installer: InstallerCoordinator
  private let control: TrayControlClient

  init(
    installer: InstallerCoordinator = InstallerCoordinator(),
    control: TrayControlClient = TrayControlClient()
  ) {
    self.installer = installer
    self.control = control
  }

  func status() async -> DashboardLocalDoHStatus {
    let available = await installer.installationActionsAvailable
    do {
      let root = try await control.localDoHStatus()
      return DashboardLocalDoHStatus(
        available: available,
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
        available: available,
        statusVerified: false
      )
    }
  }

  func prepare() async throws -> LocalDoHPlanSummary {
    let summary = try await control.prepareLocalDoHProfile()
    try await installer.prepareLocalDoH()
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
    try await installer.removeLocalDoH()
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
