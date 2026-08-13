import Foundation
import XCTest

@testable import MihomoBoxApp

final class LoginAutostartControllerTests: XCTestCase {
  func testDefaultWaitsForHealthyTunnelAndInstalledApp() async throws {
    let fixture = try Fixture(name: "health")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home,
      executable: fixture.installedExecutable
    )
    try await assertOutcome(
      .notHealthy,
      controller: controller,
      enhancedTUN: false,
      networkHealthy: true
    )
    try await assertOutcome(
      .notHealthy,
      controller: controller,
      networkHealthy: nil
    )
  }

  func testInitialDefaultIsAtomicPrivateAndIdempotent() async throws {
    let fixture = try Fixture(name: "initial")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home, executable: fixture.installedExecutable)
    try await assertOutcome(.applied, controller: controller)
    try await assertOutcome(.alreadyApplied, controller: controller)
    XCTAssertEqual(try fixture.permissions(fixture.agent), 0o644)
    XCTAssertEqual(try fixture.permissions(fixture.state), 0o600)
    XCTAssertEqual(
      try fixture.agentBundleIdentifiers(),
      ["dev.linsheng.mihomo-app"]
    )
  }

  func testRemovedLoginItemIsAUserOverride() async throws {
    let fixture = try Fixture(name: "removed")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home, executable: fixture.installedExecutable)
    _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
    try FileManager.default.removeItem(at: fixture.agent)
    try await assertOutcome(.userDisabled, controller: controller)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
  }

  func testPreexistingModifiedEntryIsNotOverwritten() async throws {
    let fixture = try Fixture(name: "modified")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.agent.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("not a plist".utf8).write(to: fixture.agent)
    let controller = LoginAutostartController(
      home: fixture.home, executable: fixture.installedExecutable)
    try await assertOutcome(.userConfigured, controller: controller)
    XCTAssertEqual(try Data(contentsOf: fixture.agent), Data("not a plist".utf8))
  }

  func testSymlinkEntryIsNeverFollowedOrOverwritten() async throws {
    let fixture = try Fixture(name: "symlink")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.agent.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let target = fixture.root.appendingPathComponent("target")
    try Data("owned".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.agent, withDestinationURL: target)
    let controller = LoginAutostartController(
      home: fixture.home, executable: fixture.installedExecutable)
    try await assertOutcome(.userConfigured, controller: controller)
    XCTAssertEqual(try Data(contentsOf: target), Data("owned".utf8))
  }

  func testOnlyApplicationsAndUserApplicationsBundlesAreEligible() async throws {
    let fixture = try Fixture(name: "installed-boundary")
    defer { fixture.remove() }

    for path in [
      "/Volumes/MihomoBox/MihomoBox.app/Contents/MacOS/mihomo-app",
      "/private/var/folders/AppTranslocation/MihomoBox.app/Contents/MacOS/mihomo-app",
      fixture.home.appendingPathComponent("project/MihomoBox.app/Contents/MacOS/mihomo-app").path,
    ] {
      let controller = LoginAutostartController(
        home: fixture.home,
        executable: URL(fileURLWithPath: path)
      )
      try await assertOutcome(.notInstalled, controller: controller)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
  }

  func testMovingEnabledAppRepairsAgentAndState() async throws {
    let fixture = try Fixture(name: "moved")
    defer { fixture.remove() }
    let original = fixture.installedExecutable
    let moved = try fixture.makeExecutable(
      bundleRelativePath: "Applications/Network/MihomoBox.app"
    )

    try await assertOutcome(
      .applied,
      controller: LoginAutostartController(home: fixture.home, executable: original)
    )
    try await assertOutcome(
      .repairedMovedApp,
      controller: LoginAutostartController(home: fixture.home, executable: moved)
    )
    XCTAssertEqual(try fixture.agentExecutable(), moved.path)
    XCTAssertEqual(try fixture.stateExecutable(), moved.path)
  }

  func testPartialMoveRepairsStateBeforeAnotherMove() async throws {
    let fixture = try Fixture(name: "partial-move")
    defer { fixture.remove() }
    let original = fixture.installedExecutable
    let moved = try fixture.makeExecutable(
      bundleRelativePath: "Applications/Network/MihomoBox.app"
    )
    let movedAgain = try fixture.makeExecutable(
      bundleRelativePath: "Applications/Network/Tools/MihomoBox.app"
    )
    _ = try await LoginAutostartController(home: fixture.home, executable: original)
      .applyIfHealthy(enhancedTUN: true, networkHealthy: true)

    // Simulate termination after the LaunchAgent rename but before the state
    // record commit. The next launch must finish that transaction first.
    try fixture.writeAgent(executable: moved.path)
    XCTAssertEqual(try fixture.stateExecutable(), original.path)
    try await assertOutcome(
      .repairedMovedApp,
      controller: LoginAutostartController(home: fixture.home, executable: moved)
    )
    XCTAssertEqual(try fixture.stateExecutable(), moved.path)

    try await assertOutcome(
      .repairedMovedApp,
      controller: LoginAutostartController(home: fixture.home, executable: movedAgain)
    )
    XCTAssertEqual(try fixture.agentExecutable(), movedAgain.path)
    XCTAssertEqual(try fixture.stateExecutable(), movedAgain.path)
  }

  func testStateFailureRollsBackAgentContentsAndExistingMode() async throws {
    enum InjectedFailure: Error { case stateWrite }

    let fixture = try Fixture(name: "rollback")
    defer { fixture.remove() }
    let original = fixture.installedExecutable
    let moved = try fixture.makeExecutable(
      bundleRelativePath: "Applications/Network/MihomoBox.app"
    )
    _ = try await LoginAutostartController(home: fixture.home, executable: original)
      .applyIfHealthy(enhancedTUN: true, networkHealthy: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fixture.agent.path
    )
    let originalState = try Data(contentsOf: fixture.state)

    let controller = LoginAutostartController(
      home: fixture.home,
      executable: moved,
      beforeWrite: { target in
        if case .state = target { throw InjectedFailure.stateWrite }
      }
    )
    do {
      _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
      XCTFail("state write failure must abort the move")
    } catch InjectedFailure.stateWrite {}

    XCTAssertEqual(try fixture.agentExecutable(), original.path)
    XCTAssertEqual(try Data(contentsOf: fixture.state), originalState)
    XCTAssertEqual(try fixture.permissions(fixture.agent), 0o600)
  }

  func testInitialStateFailureRemovesNewAgent() async throws {
    enum InjectedFailure: Error { case stateWrite }

    let fixture = try Fixture(name: "initial-rollback")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home,
      executable: fixture.installedExecutable,
      beforeWrite: { target in
        if case .state = target { throw InjectedFailure.stateWrite }
      }
    )
    do {
      _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
      XCTFail("state write failure must abort the initial default")
    } catch InjectedFailure.stateWrite {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
  }

  func testExistingValidEntryKeepsItsModeWhenStateIsAdopted() async throws {
    let fixture = try Fixture(name: "existing-mode")
    defer { fixture.remove() }
    try fixture.writeAgent(executable: fixture.installedExecutable.path, mode: 0o600)

    try await assertOutcome(
      .applied,
      controller: LoginAutostartController(
        home: fixture.home,
        executable: fixture.installedExecutable
      )
    )
    XCTAssertEqual(try fixture.permissions(fixture.agent), 0o600)
    XCTAssertEqual(try fixture.stateExecutable(), fixture.installedExecutable.path)
  }

  func testExtraProgramAndUnknownKeysAreNeverAcceptedAsDefaultEntry() async throws {
    for (name, key, value) in [
      ("extra-program", "Program", "/usr/bin/false"),
      ("unknown-key", "KeepAlive", "unexpected"),
    ] {
      let fixture = try Fixture(name: name)
      defer { fixture.remove() }
      try fixture.writeAgent(
        executable: fixture.installedExecutable.path,
        extra: [key: value]
      )
      let controller = LoginAutostartController(
        home: fixture.home,
        executable: fixture.installedExecutable
      )
      try await assertOutcome(.userConfigured, controller: controller)
      XCTAssertEqual(try fixture.agentValue(key), value)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }
  }

  func testUnknownKeyAddedAfterDefaultIsPreservedAndReportedModified() async throws {
    let fixture = try Fixture(name: "modified-after-default")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home,
      executable: fixture.installedExecutable
    )
    _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
    try fixture.addAgentValue("/usr/bin/false", forKey: "Program")

    do {
      _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
      XCTFail("a user-modified default entry must not be overwritten")
    } catch LoginAutostartError.modifiedEntry {}
    XCTAssertEqual(try fixture.agentValue("Program"), "/usr/bin/false")
  }

  func testUnknownStateKeyFailsClosedWithoutChangingAgent() async throws {
    let fixture = try Fixture(name: "unknown-state")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home,
      executable: fixture.installedExecutable
    )
    _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
    let originalAgent = try Data(contentsOf: fixture.agent)
    try fixture.addStateValue("unexpected", forKey: "owner")

    do {
      _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
      XCTFail("unknown state fields must fail closed")
    } catch LoginAutostartError.invalidState {}
    XCTAssertEqual(try Data(contentsOf: fixture.agent), originalAgent)
    XCTAssertEqual(try fixture.stateValue("owner") as? String, "unexpected")
  }

  func testCorruptStateFailsClosedWithoutChangingAgent() async throws {
    let fixture = try Fixture(name: "corrupt-state")
    defer { fixture.remove() }
    let controller = LoginAutostartController(
      home: fixture.home,
      executable: fixture.installedExecutable
    )
    _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
    let originalAgent = try Data(contentsOf: fixture.agent)
    try Data("not json".utf8).write(to: fixture.state, options: .atomic)

    do {
      _ = try await controller.applyIfHealthy(enhancedTUN: true, networkHealthy: true)
      XCTFail("corrupt state must fail closed")
    } catch LoginAutostartError.invalidState {}
    XCTAssertEqual(try Data(contentsOf: fixture.agent), originalAgent)
    XCTAssertEqual(try Data(contentsOf: fixture.state), Data("not json".utf8))
  }

  func testPlistSerializationPreservesSpecialCharactersInAppPath() async throws {
    let fixture = try Fixture(name: "special-path")
    defer { fixture.remove() }
    let executable = try fixture.makeExecutable(
      bundleRelativePath: "Applications/A&B Network's.app"
    )
    let controller = LoginAutostartController(home: fixture.home, executable: executable)

    try await assertOutcome(.applied, controller: controller)
    XCTAssertEqual(try fixture.agentExecutable(), executable.path)
    XCTAssertEqual(try fixture.stateExecutable(), executable.path)
  }

  private func assertOutcome(
    _ expected: LoginAutostartOutcome,
    controller: LoginAutostartController,
    enhancedTUN: Bool = true,
    networkHealthy: Bool? = true,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let actual = try await controller.applyIfHealthy(
      enhancedTUN: enhancedTUN,
      networkHealthy: networkHealthy
    )
    XCTAssertEqual(actual, expected, file: file, line: line)
  }
}

private struct Fixture {
  let root: URL
  let home: URL
  let installedExecutable: URL

  init(name: String) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-login-\(name)-\(UUID().uuidString)")
    home = root.appendingPathComponent("home")
    installedExecutable = home.appendingPathComponent(
      "Applications/MihomoBox.app/Contents/MacOS/mihomo-app"
    )
    try FileManager.default.createDirectory(
      at: installedExecutable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: installedExecutable)
  }

  var agent: URL {
    home.appendingPathComponent("Library/LaunchAgents/dev.linsheng.mihomo-app.plist")
  }
  var state: URL {
    home.appendingPathComponent(
      "Library/Application Support/MihomoBox/.login-autostart-default.json"
    )
  }

  func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
  }

  func makeExecutable(bundleRelativePath: String) throws -> URL {
    let executable = home.appendingPathComponent(bundleRelativePath)
      .appendingPathComponent("Contents/MacOS/mihomo-app")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: executable)
    return executable
  }

  func writeAgent(
    executable: String,
    mode: Int = 0o644,
    extra: [String: Any] = [:]
  ) throws {
    var value: [String: Any] = [
      "Label": "dev.linsheng.mihomo-app",
      "ProgramArguments": [executable],
      "RunAtLoad": true,
      "AssociatedBundleIdentifiers": ["dev.linsheng.mihomo-app"],
    ]
    for (key, item) in extra { value[key] = item }
    try FileManager.default.createDirectory(
      at: agent.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(
      fromPropertyList: value,
      format: .xml,
      options: 0
    )
    try data.write(to: agent, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: agent.path)
  }

  func addAgentValue(_ value: Any, forKey key: String) throws {
    var dictionary = try agentDictionary()
    dictionary[key] = value
    let data = try PropertyListSerialization.data(
      fromPropertyList: dictionary,
      format: .xml,
      options: 0
    )
    try data.write(to: agent, options: .atomic)
  }

  func agentExecutable() throws -> String? {
    (try agentDictionary()["ProgramArguments"] as? [String])?.first
  }

  func agentValue(_ key: String) throws -> String? {
    try agentDictionary()[key] as? String
  }

  func agentBundleIdentifiers() throws -> [String]? {
    try agentDictionary()["AssociatedBundleIdentifiers"] as? [String]
  }

  func stateExecutable() throws -> String? {
    try stateDictionary()["executable"] as? String
  }

  func addStateValue(_ value: Any, forKey key: String) throws {
    var dictionary = try stateDictionary()
    dictionary[key] = value
    var data = try JSONSerialization.data(
      withJSONObject: dictionary,
      options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    try data.write(to: state, options: .atomic)
  }

  func stateValue(_ key: String) throws -> Any? {
    try stateDictionary()[key]
  }

  private func agentDictionary() throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: agent),
      options: [],
      format: nil
    )
    return object as? [String: Any] ?? [:]
  }

  private func stateDictionary() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: state))
    return object as? [String: Any] ?? [:]
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
