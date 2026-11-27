import XCTest
@testable import MihomoControl

final class LaunchDaemonDefinitionTests: XCTestCase {
  private func plist(_ processType: String?, format: PropertyListSerialization.PropertyListFormat = .xml)
    throws -> Data
  {
    var definition: [String: Any] = [
      "Label": "dev.linsheng.mihomo.daemon",
      "RunAtLoad": true,
      "ThrottleInterval": 5,
      "KeepAlive": ["SuccessfulExit": false],
    ]
    definition["ProcessType"] = processType
    return try PropertyListSerialization.data(fromPropertyList: definition, format: format, options: 0)
  }

  func testRepositoryDefinitionUsesTheStandardProcessClass() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try XCTUnwrap(
      LaunchDaemonDefinition.load(
        repository.appendingPathComponent("deploy/dev.linsheng.mihomo.daemon.plist")
      )
    )
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(data), "standard")
    XCTAssertEqual(LaunchDaemonDefinition.state(installed: data, bundled: data), .current)
  }

  func testFormattingDifferencesAreCurrent() throws {
    XCTAssertEqual(
      LaunchDaemonDefinition.state(
        installed: try plist("Standard", format: .binary),
        bundled: try plist("Standard")
      ),
      .current
    )
  }

  func testOlderProcessClassIsOutdated() throws {
    XCTAssertEqual(
      LaunchDaemonDefinition.state(installed: try plist("Background"), bundled: try plist("Standard")),
      .outdated
    )
    XCTAssertEqual(
      LaunchDaemonDefinition.state(installed: try plist(nil), bundled: try plist("Standard")),
      .outdated
    )
  }

  func testMalformedInstalledDefinitionIsOutdated() throws {
    XCTAssertEqual(
      LaunchDaemonDefinition.state(installed: Data("not a plist".utf8), bundled: try plist("Standard")),
      .outdated
    )
  }

  func testMissingDefinitionsRecommendNothing() throws {
    XCTAssertEqual(LaunchDaemonDefinition.state(installed: nil, bundled: try plist("Standard")), .unknown)
    XCTAssertEqual(LaunchDaemonDefinition.state(installed: try plist("Background"), bundled: nil), .unknown)
    XCTAssertEqual(
      LaunchDaemonDefinition.state(installed: try plist("Background"), bundled: Data("x".utf8)),
      .unknown
    )
  }

  func testProcessTypeTokensAreFixed() throws {
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(try plist("Background")), "background")
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(try plist("Interactive")), "interactive")
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(try plist("Custom value")), "other")
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(try plist(nil)), "unset")
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(Data("x".utf8)), "malformed")
    XCTAssertEqual(LaunchDaemonDefinition.processTypeToken(nil), "unreadable")
  }

  func testLoadRejectsSymbolicLinksAndMissingFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("daemon.plist")
    try plist("Standard").write(to: file)
    let link = directory.appendingPathComponent("link.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    XCTAssertNotNil(LaunchDaemonDefinition.load(file))
    XCTAssertNil(LaunchDaemonDefinition.load(link))
    XCTAssertNil(LaunchDaemonDefinition.load(directory.appendingPathComponent("absent.plist")))
  }
}
