import AppKit
import Foundation
import MihomoBoxUI

@MainActor
final class LocalDoHCoordinator: DashboardLocalDoHService {
  private static let preparedMarker = URL(
    fileURLWithPath: "/Library/Application Support/Mihomo App/local-doh-enabled"
  )
  private let installer: InstallerCoordinator
  private let fileManager: FileManager

  init(
    installer: InstallerCoordinator = InstallerCoordinator(),
    fileManager: FileManager = .default
  ) {
    self.installer = installer
    self.fileManager = fileManager
  }

  func status() async -> DashboardLocalDoHStatus {
    let plan = try? storedPlan()
    return DashboardLocalDoHStatus(
      available: await installer.installationActionsAvailable,
      prepared: fileManager.fileExists(atPath: Self.preparedMarker.path),
      installedDomainCount: plan?.domains.count ?? 0
    )
  }

  func prepare(plan: LocalDoHDomainPlan) async throws {
    let profileData = try LocalDoHProfileDocument.data(for: plan)
    try await installer.prepareLocalDoH()
    let url = try profileURL()
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try profileData.write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    guard NSWorkspace.shared.open(url) else {
      throw NSError(
        domain: "MihomoBoxLocalDoH",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The local DoH profile was generated, but macOS did not open Device Management."
        ]
      )
    }
  }

  func remove() async throws {
    try await installer.removeLocalDoH()
    let url = try profileURL()
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  func openDeviceManagement() async throws {
    guard NSWorkspace.shared.open(LocalDoHProfileDocument.deviceManagementURL) else {
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

  private func profileURL() throws -> URL {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw NSError(
        domain: "MihomoBoxLocalDoH",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."]
      )
    }
    return base.appendingPathComponent("MihomoBox", isDirectory: true)
      .appendingPathComponent("MihomoBox-Local-DoH.mobileconfig")
  }

  private func storedPlan() throws -> LocalDoHDomainPlan {
    let data = try Data(contentsOf: profileURL())
    let value = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    guard let profile = value as? [String: Any],
      let payloads = profile["PayloadContent"] as? [[String: Any]],
      let first = payloads.first,
      let settings = first["DNSSettings"] as? [String: Any],
      let domains = settings["SupplementalMatchDomains"] as? [String]
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return LocalDoHDomainPlan(domains: domains)
  }
}
