import Foundation
import XCTest

@testable import MihomoBoxApp

final class ComponentBuildManifestTests: XCTestCase {
  func testParsesAllManagedComponentDigestsForMatchingVersion() throws {
    let daemon = String(repeating: "a", count: 64)
    let agent = String(repeating: "B", count: 64)
    let mihomo = String(repeating: "9", count: 64)
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "Version": "0.8.4",
        "MihomoDaemonSHA256": daemon,
        "MihomoAgentSHA256": agent,
        "MihomoSHA256": mihomo,
      ],
      format: .binary,
      options: 0
    )

    XCTAssertEqual(
      ComponentBuildManifest.componentDigests(from: data, expectedVersion: "0.8.4"),
      [
        "mihomo-daemon": daemon,
        "mihomo-agent": agent.lowercased(),
        "mihomo": mihomo,
      ]
    )
  }

  func testRejectsWrongVersionMissingDigestAndNonHexDigest() throws {
    let valid = String(repeating: "a", count: 64)
    let base = [
      "Version": "0.8.4",
      "MihomoDaemonSHA256": valid,
      "MihomoAgentSHA256": valid,
      "MihomoSHA256": valid,
    ]
    let validData = try plist(base)
    XCTAssertNil(
      ComponentBuildManifest.componentDigests(from: validData, expectedVersion: "9.9.9")
    )

    var missing = base
    missing["MihomoAgentSHA256"] = nil
    XCTAssertNil(
      ComponentBuildManifest.componentDigests(
        from: try plist(missing),
        expectedVersion: "0.8.4"
      )
    )

    var nonHex = base
    nonHex["MihomoSHA256"] = String(repeating: "z", count: 64)
    XCTAssertNil(
      ComponentBuildManifest.componentDigests(
        from: try plist(nonHex),
        expectedVersion: "0.8.4"
      )
    )
  }

  private func plist(_ value: [String: String]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: value,
      format: .binary,
      options: 0
    )
  }
}
