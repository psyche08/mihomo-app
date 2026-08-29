import AppKit
import Foundation
import MihomoBoxUI
import Sparkle

/// Thin typed Sparkle 2.9.4 owner. Update verification, download, installation
/// and relaunch remain inside Sparkle.
@MainActor
final class SparkleUpdateController: DashboardUpdatePreference {
  private let bundle: Bundle
  private let defaults: UserDefaults
  private var controller: SPUStandardUpdaterController?

  init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
    self.bundle = bundle
    self.defaults = defaults
  }

  var isAvailable: Bool { Self.validConfiguration(in: bundle) }
  var automaticUpdatesAvailable: Bool { isAvailable }
  var automaticUpdatesEnabled: Bool {
    guard isAvailable else { return false }
    if let updater = controller?.updater {
      return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }
    return Self.automaticUpdatesEnabled(in: bundle, defaults: defaults)
  }
  var canCheckForUpdates: Bool {
    guard isAvailable else { return false }
    return controller?.updater.canCheckForUpdates ?? false
  }

  func start() {
    guard controller == nil, isAvailable else {
      if !isAvailable { AppLog.info("event=app_update result=disabled_configuration") }
      return
    }
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    AppLog.info("event=app_update phase=started")
  }

  func stop() {
    controller = nil
  }

  func checkForUpdates() {
    guard isAvailable else { return }
    if controller == nil { start() }
    controller?.checkForUpdates(nil)
  }

  func setAutomaticUpdatesEnabled(_ enabled: Bool) {
    guard isAvailable else { return }
    if controller == nil { start() }
    guard let updater = controller?.updater else { return }
    // These are Sparkle's own persisted settings. Do not mirror them into a
    // second preference, which could drift from Sparkle's scheduler.
    if enabled {
      // Downloads are allowed only after automatic checks are enabled.
      updater.automaticallyChecksForUpdates = true
      updater.automaticallyDownloadsUpdates = true
    } else {
      // Sparkle ignores a download-setting write once checks are already off,
      // so persist the download preference first.
      updater.automaticallyDownloadsUpdates = false
      updater.automaticallyChecksForUpdates = false
    }
    AppLog.info("event=app_update preference=automatic enabled=\(enabled)")
  }

  nonisolated static func automaticUpdatesEnabled(
    in bundle: Bundle,
    defaults: UserDefaults
  ) -> Bool {
    func value(for key: String) -> Bool {
      if defaults.object(forKey: key) != nil {
        return defaults.bool(forKey: key)
      }
      return (bundle.infoDictionary?[key] as? NSNumber)?.boolValue == true
    }
    return value(for: "SUEnableAutomaticChecks")
      && value(for: "SUAutomaticallyUpdate")
  }

  nonisolated static func validConfiguration(in bundle: Bundle) -> Bool {
    let info = bundle.infoDictionary ?? [:]
    guard info["MihomoBoxDevelopmentUpdatesDisabled"] as? Bool != true,
      let key = info["SUPublicEDKey"] as? String,
      isRealPublicKey(key),
      let feed = info["SUFeedURL"] as? String,
      let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host != nil,
      info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      info["SURequireSignedFeed"] as? Bool == true,
      (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0
    else { return false }
    return true
  }

  nonisolated private static func isRealPublicKey(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.lowercased().contains("placeholder"),
      trimmed != "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      let data = Data(base64Encoded: trimmed), data.count == 32,
      data.contains(where: { $0 != 0 })
    else { return false }
    return true
  }
}
