import AppKit
import MihomoBoxUI

@MainActor
protocol ApplicationStatusItemControlling: AnyObject {
  func start()
  func stop()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let coordinator: any AppShellCoordinating
  private let mainWindow: any NativeWindowControlling
  private let showWindowAtLaunch: Bool
  private var statusItemController: (any ApplicationStatusItemControlling)?
  private var didStart = false
  private var didTearDown = false

  init(
    coordinator: any AppShellCoordinating,
    mainWindow: (any NativeWindowControlling)? = nil,
    showWindowAtLaunch: Bool = ProcessInfo.processInfo.arguments.contains("--smoke-show-window")
      || ProcessInfo.processInfo.environment["MIHOMO_APP_SMOKE_SHOW_WINDOW"] != nil,
    statusItemController: (any ApplicationStatusItemControlling)? = nil
  ) {
    self.coordinator = coordinator
    self.mainWindow = mainWindow ?? NativeWindowFacade.shared
    self.showWindowAtLaunch = showWindowAtLaunch
    self.statusItemController = statusItemController
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    start()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    tearDown()
  }

  /// Kept separate from the delegate callback so lifecycle tests can verify
  /// exactly what this user process owns without starting NSApplication.run().
  func start() {
    guard !didStart else { return }
    didStart = true

    if statusItemController == nil {
      statusItemController = StatusItemController(
        service: coordinator.trayService,
        mainWindow: mainWindow,
        onExit: { [weak self] in self?.requestTermination() }
      )
    }

    coordinator.startBackgroundServices()
    AppStartupTimeline.mark(.backgroundServicesStarted)
    statusItemController?.start()
    AppStartupTimeline.mark(.statusItemReady)

    if showWindowAtLaunch {
      _ = mainWindow.show()
    }
  }

  func requestTermination() {
    tearDown()
    NSApp.terminate(nil)
  }

  func tearDown() {
    guard !didTearDown else { return }
    didTearDown = true

    statusItemController?.stop()
    statusItemController = nil
    mainWindow.shutdown()
    coordinator.stopBackgroundServices()

    // Deliberately no agent.stop call here. The root LaunchDaemon continues to
    // own Mihomo, Enhanced TUN, DNS and restoration after the UI exits.
  }
}
