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
          ? root.installedDomainCount : root.preparedDomainCount,
        globalDNSFallback: root.globalDNSFallback,
        fallbackProfileRemovalRequired: root.fallbackProfileRemovalRequired,
        certificateTrusted: root.certificateTrusted
      )
    } catch {
      return DashboardLocalDoHStatus(
        available: false,
        statusVerified: false
      )
    }
  }

  func prepare() async throws -> LocalDoHPlanSummary {
    try confirmTrust(preparing: true)
    let summary = try await control.installLocalDoH()
    try await LocalDoHPreparationFlow.finish(
      trust: { try await self.authorizePreparedCertificate() },
      openProfile: { try self.openPreparedProfile() }
    )
    return summary
  }

  private func openPreparedProfile() throws {
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
  }

  func trustCertificate() async throws {
    try confirmTrust(preparing: false)
    try await authorizePreparedCertificate()
  }

  private func authorizePreparedCertificate() async throws {
    if try await control.localDoHStatus().certificateTrusted == true { return }
    let certificate = try await control.prepareLocalDoHCertificateTrust()
    try await LocalDoHCertificateTrust.authorize(certificate)
    try await control.verifyLocalDoHCertificateTrust()
  }

  func setDNSMode(_ mode: DNSIntegrationMode) async throws {
    if mode == .globalDNS {
      let alert = NSAlert()
      alert.messageText = "Switch to Global DNS?"
      alert.informativeText = "This enables Enhanced TUN and uses 198.18.0.1 for system DNS. "
        + "MihomoBox will remove only its own DoH profile and release port 443. "
        + "The certificate and private key are retained. Switching back requires profile installation in System Settings."
      alert.addButton(withTitle: "Use Global DNS")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
    }
    try await control.setDNSMode(mode)
  }

  func openKeychainAccess() async throws {
    // Open the system UI only; never unlock a keychain or collect a password.
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else {
      throw NSError(domain: "MihomoBoxLocalDoH", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Open Keychain Access manually to review SSL trust."])
    }
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }

  private func confirmTrust(preparing: Bool) throws {
    let alert = NSAlert()
    alert.messageText = preparing ? "Prepare Local DoH and trust its certificate?" : "Trust the Local DoH certificate?"
    alert.informativeText = "The installed root helper will install this Mac's MihomoBox Local DoH Root CA "
      + "in the System keychain. The App then asks macOS to authorize SSL trust for 127.0.0.1 for all users, not code-signing or mail trust. "
      + "Approve any macOS authorization dialog; MihomoBox never requests your password itself. "
      + (preparing ? "This prepares Local DoH standby and restores any managed Global DNS. Then approve the DNS profile in System Settings." : "")
    alert.addButton(withTitle: preparing ? "Prepare & Trust" : "Trust for SSL")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
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

@MainActor
enum LocalDoHPreparationFlow {
  static func finish(trust: () async throws -> Void, openProfile: () throws -> Void) async throws {
    var trustFailure: Error?
    do { try await trust() }
    catch { trustFailure = error }
    // Profile review is still available after denial or cancellation. Installing
    // the profile never implies trust or a successful Local DoH activation.
    try openProfile()
    if let trustFailure { throw trustFailure }
  }
}
