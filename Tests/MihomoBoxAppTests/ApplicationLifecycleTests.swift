import AppKit
import MihomoBoxUI
import XCTest

@testable import MihomoBoxApp

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
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
  func switchProfile(named name: String) async throws {}
  func reloadProfile() async throws {}
  func installOrRepairDaemon() async throws {}
  func openDiagnosticLogs() {}
  func checkForUpdates() {}
}
