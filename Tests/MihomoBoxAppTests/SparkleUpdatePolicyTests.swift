import Foundation
import XCTest

@testable import MihomoBoxApp

final class SparkleUpdatePolicyTests: XCTestCase {
  func testDevelopmentOrIncompleteConfigurationFailsClosed() throws {
    let empty = try BundleFixture(info: [:])
    defer { empty.remove() }
    XCTAssertFalse(SparkleUpdateController.validConfiguration(in: empty.bundle))

    let placeholder = try BundleFixture(info: [
      "SUPublicEDKey": "placeholder",
      "SUFeedURL": "https://example.com/appcast.xml",
      "SUVerifyUpdateBeforeExtraction": true,
      "SURequireSignedFeed": true,
      "SUSignedFeedFailureExpirationInterval": 0,
    ])
    defer { placeholder.remove() }
    XCTAssertFalse(SparkleUpdateController.validConfiguration(in: placeholder.bundle))

    let development = try BundleFixture(info: [
      "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "SUFeedURL": "https://example.com/appcast.xml",
      "SUVerifyUpdateBeforeExtraction": true,
      "SURequireSignedFeed": true,
      "SUSignedFeedFailureExpirationInterval": 0,
      "MihomoBoxDevelopmentUpdatesDisabled": true,
    ])
    defer { development.remove() }
    XCTAssertFalse(SparkleUpdateController.validConfiguration(in: development.bundle))
  }

  func testSignedHTTPSFeedWithZeroFallbackIsAccepted() throws {
    let valid = try BundleFixture(info: [
      "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
      "SUFeedURL": "https://example.com/appcast.xml",
      "SUVerifyUpdateBeforeExtraction": true,
      "SURequireSignedFeed": true,
      "SUSignedFeedFailureExpirationInterval": 0,
    ])
    defer { valid.remove() }
    XCTAssertTrue(SparkleUpdateController.validConfiguration(in: valid.bundle))
  }

  func testHTTPOrUnsignedFeedIsRejected() throws {
    let fixture = try BundleFixture(info: [
      "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
      "SUFeedURL": "http://example.com/appcast.xml",
      "SUVerifyUpdateBeforeExtraction": true,
      "SURequireSignedFeed": false,
      "SUSignedFeedFailureExpirationInterval": 0,
    ])
    defer { fixture.remove() }
    XCTAssertFalse(SparkleUpdateController.validConfiguration(in: fixture.bundle))
  }

  func testAutomaticUpdatesDefaultOnAndPersistedUserChoiceWins() throws {
    let fixture = try BundleFixture(info: [
      "SUEnableAutomaticChecks": true,
      "SUAutomaticallyUpdate": true,
    ])
    defer { fixture.remove() }
    let suite = "dev.linsheng.mihomo-app.tests.updates.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertTrue(
      SparkleUpdateController.automaticUpdatesEnabled(
        in: fixture.bundle,
        defaults: defaults
      )
    )

    defaults.set(false, forKey: "SUEnableAutomaticChecks")
    defaults.set(false, forKey: "SUAutomaticallyUpdate")
    XCTAssertFalse(
      SparkleUpdateController.automaticUpdatesEnabled(
        in: fixture.bundle,
        defaults: defaults
      )
    )
  }
}

private struct BundleFixture {
  let root: URL
  let bundle: Bundle

  init(info: [String: Any]) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-sparkle-\(UUID().uuidString).bundle")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var dictionary = info
    dictionary["CFBundleIdentifier"] = "dev.linsheng.mihomo-app.tests.\(UUID().uuidString)"
    dictionary["CFBundlePackageType"] = "BNDL"
    let data = try PropertyListSerialization.data(
      fromPropertyList: dictionary,
      format: .xml,
      options: 0
    )
    try data.write(to: root.appendingPathComponent("Info.plist"))
    guard let bundle = Bundle(url: root) else { throw CocoaError(.fileReadCorruptFile) }
    self.bundle = bundle
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
