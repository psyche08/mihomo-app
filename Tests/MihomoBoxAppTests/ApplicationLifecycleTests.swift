import AppKit
import MihomoBoxUI
import XCTest

@testable import MihomoBoxApp

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
  func testVersionMenuUsesBundleShortVersion() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-version-\(UUID().uuidString).bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "dev.linsheng.mihomo-app.version-tests",
      "CFBundlePackageType": "BNDL",
      "CFBundleShortVersionString": "0.8.4",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try data.write(to: root.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: root))

    XCTAssertEqual(AppVersionMenuPolicy.title(bundle: bundle), "Version 0.8.4")
  }

  func testVersionMenuFailsClosedWhenBundleVersionIsMissing() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-version-missing-\(UUID().uuidString).bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "dev.linsheng.mihomo-app.version-tests.missing",
      "CFBundlePackageType": "BNDL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try data.write(to: root.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: root))

    XCTAssertEqual(AppVersionMenuPolicy.title(bundle: bundle), "Version unavailable")
  }

  func testStartAndTearDownAreIdempotentAndLeaveManagedAgentAlone() {
    let service = LifecycleTrayService()
    let coordinator = LifecycleCoordinator(trayService: service)
    let window = LifecycleWindow()
    let statusItem = LifecycleStatusItem(service: service)
    let delegate = AppDelegate(
      coordinator: coordinator,
      mainWindow: window,
      showWindowAtLaunch: false,
      statusItemController: statusItem
    )

    delegate.start()
    delegate.start()
    delegate.tearDown()
    delegate.tearDown()

    XCTAssertEqual(coordinator.backgroundStartCount, 1)
    XCTAssertEqual(coordinator.backgroundStopCount, 1)
    XCTAssertEqual(statusItem.startCount, 1)
    XCTAssertEqual(statusItem.stopCount, 1)
    XCTAssertEqual(window.shutdownCount, 1)
    XCTAssertEqual(window.showCount, 0)
  }
}

@MainActor
private final class LifecycleStatusItem: ApplicationStatusItemControlling {
  private let service: LifecycleTrayService
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(service: LifecycleTrayService) {
    self.service = service
  }

  func start() {
    startCount += 1
    service.start()
  }

  func stop() {
    stopCount += 1
    service.stop()
  }
}

@MainActor
private final class LifecycleCoordinator: AppShellCoordinating {
  let trayService: any TrayService
  private(set) var backgroundStartCount = 0
  private(set) var backgroundStopCount = 0

  init(trayService: any TrayService) {
    self.trayService = trayService
  }

  func startBackgroundServices() { backgroundStartCount += 1 }
  func stopBackgroundServices() { backgroundStopCount += 1 }
}

@MainActor
private final class LifecycleWindow: NativeWindowControlling {
  private(set) var showCount = 0
  private(set) var shutdownCount = 0

  func show() -> Bool {
    showCount += 1
    return true
  }

  func hide() {}
  func shutdown() { shutdownCount += 1 }
}

@MainActor
private final class LifecycleTrayService: TrayService {
  var onSnapshot: (@MainActor (TraySnapshot) -> Void)?
  var currentSnapshot = TraySnapshot()
  var canCheckForUpdates = false
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func start() { startCount += 1 }
  func stop() { stopCount += 1 }
  func menuWillOpen() {}
  func refresh(authoritative: Bool) {}
  func setEnhancedTUNEnabled(_ enabled: Bool) async throws {}
  func setOutboundMode(_ mode: TrayOutboundMode) async throws {}
  func selectProxy(group: String, name: String) async throws {}
  func testProxyDelays() async throws {}
  func importLocalProfile() async throws {}
  func importHTTPProfile() async throws {}
  func editProfile(named name: String) async throws {}
  func switchProfile(named name: String) async throws {}
  func reloadProfile() async throws {}
  func installOrRepairDaemon(requireLegacy: Bool) async throws {}
  func uninstallHelper() async throws {}
  func openDiagnosticLogs() {}
  func checkForUpdates() {}
}
