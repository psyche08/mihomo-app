import AppKit
import Foundation
import Sparkle

/// Thin typed Sparkle 2.9.4 owner. Update verification, download, installation
/// and relaunch remain inside Sparkle.
@MainActor
final class SparkleUpdateController {
  private let bundle: Bundle
  private var controller: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  var isAvailable: Bool { Self.validConfiguration(in: bundle) }
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
