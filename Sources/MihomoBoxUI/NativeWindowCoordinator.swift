import AppKit
import Dispatch
import SwiftUI

enum NativeWindowGeometry {
  static let initialContentSize = NSSize(width: 1_280, height: 820)
  static let minimumContentSize = NSSize(width: 900, height: 600)
  static let frameAutosaveName = "MihomoBox.MainWindow"

  /// Fits a restored frame onto the screen containing most of it. If that
  /// screen is no longer connected, the fallback screen is used instead.
  static func constrainedFrame(
    _ proposedFrame: NSRect,
    minimumSize: NSSize,
    defaultSize: NSSize,
    visibleFrames: [NSRect],
    fallbackVisibleFrame: NSRect?
  ) -> NSRect? {
    let screens = visibleFrames.filter(isUsable)
    guard !screens.isEmpty else { return nil }

    let target = bestScreen(
      for: proposedFrame,
      screens: screens,
      fallback: fallbackVisibleFrame
    )
    let requestedWidth = positiveFinite(proposedFrame.width) ?? defaultSize.width
    let requestedHeight = positiveFinite(proposedFrame.height) ?? defaultSize.height
    let minimumWidth = positiveFinite(minimumSize.width) ?? 1
    let minimumHeight = positiveFinite(minimumSize.height) ?? 1
    let width = min(max(requestedWidth, minimumWidth), target.width)
    let height = min(max(requestedHeight, minimumHeight), target.height)

    let centeredX = target.midX - width / 2
    let centeredY = target.midY - height / 2
    let requestedX = proposedFrame.origin.x.isFinite ? proposedFrame.origin.x : centeredX
    let requestedY = proposedFrame.origin.y.isFinite ? proposedFrame.origin.y : centeredY
    let origin = NSPoint(
      x: min(max(requestedX, target.minX), target.maxX - width),
      y: min(max(requestedY, target.minY), target.maxY - height)
    )
    return NSRect(origin: origin, size: NSSize(width: width, height: height))
  }

  private static func bestScreen(
    for frame: NSRect,
    screens: [NSRect],
    fallback: NSRect?
  ) -> NSRect {
    if isUsable(frame) {
      let intersections = screens.map { screen in
        (screen, intersectionArea(frame, screen))
      }
      if let best = intersections.max(by: { $0.1 < $1.1 }), best.1 > 0 {
        return best.0
      }
    }

    if let fallback, isUsable(fallback) {
      return fallback
    }
    return screens[0]
  }

  private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
  }

  private static func isUsable(_ rect: NSRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && positiveFinite(rect.width) != nil && positiveFinite(rect.height) != nil
  }

  private static func positiveFinite(_ value: CGFloat) -> CGFloat? {
    value.isFinite && value > 0 ? value : nil
  }
}

enum NativeWindowHosting {
  @MainActor
  static func configure<Content: View>(_ controller: NSHostingController<Content>) {
    // The AppKit window owns sizing. SwiftUI should fill the content area but
    // must not resize the window when a dashboard page changes its ideal size.
    controller.sizingOptions = []
    controller.view.autoresizingMask = [.width, .height]
  }
}

/// Owns the one native main window inside MihomoBox's AppKit application.
///
/// The application target owns the single `NSApplication` and its accessory
/// event loop. This coordinator owns only the lazy SwiftUI window and never
/// creates an application or a second process lifecycle.
@MainActor
final class NativeWindowCoordinator: NSObject, NSWindowDelegate {
  static let shared = NativeWindowCoordinator()

  /// `start` and `stop` must be idempotent. `RootView()` observes this same
  /// shared store, so hiding the window can suspend streams without throwing
  /// away the view hierarchy.
  private let dashboardStore = DashboardStore.shared
  private var window: NSWindow?

  private override init() {
    super.init()
  }

  @discardableResult
  func show() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))

    let window = existingOrCreateWindow()
    dashboardStore.setVisible(true)
    dashboardStore.start()

    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    constrainFrameToVisibleScreens(window)

    // Do not change NSApp.activationPolicy here. The AppKit application shell
    // intentionally keeps MihomoBox as an accessory/menu-bar application.
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    return window.isVisible
  }

  func hide() {
    dispatchPrecondition(condition: .onQueue(.main))

    dashboardStore.setVisible(false)
    dashboardStore.stop()
    saveFrame(window)
    window?.orderOut(nil)
  }

  func shutdown() {
    dispatchPrecondition(condition: .onQueue(.main))

    dashboardStore.setVisible(false)
    dashboardStore.stop()

    guard let window else { return }
    saveFrame(window)
    window.delegate = nil
    window.orderOut(nil)
    window.contentViewController = nil
    window.close()
    self.window = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  func windowDidMiniaturize(_ notification: Notification) {
    dashboardStore.setVisible(false)
    dashboardStore.stop()
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    dashboardStore.setVisible(true)
    dashboardStore.start()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard let resizedWindow = notification.object as? NSWindow, resizedWindow === window else {
      return
    }
    saveFrame(resizedWindow)
  }

  private func existingOrCreateWindow() -> NSWindow {
    if let window {
      return window
    }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NativeWindowGeometry.initialContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MihomoBox"
    window.contentMinSize = NativeWindowGeometry.minimumContentSize
    let hostingController = NSHostingController(rootView: RootView())
    NativeWindowHosting.configure(hostingController)
    window.contentViewController = hostingController
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    _ = window.setFrameUsingName(NativeWindowGeometry.frameAutosaveName)
    _ = window.setFrameAutosaveName(NativeWindowGeometry.frameAutosaveName)
    constrainFrameToVisibleScreens(window)
    saveFrame(window)

    self.window = window
    return window
  }

  private func constrainFrameToVisibleScreens(_ window: NSWindow) {
    guard !window.styleMask.contains(.fullScreen) else { return }

    let minimumFrameSize = window.frameRect(
      forContentRect: NSRect(origin: .zero, size: NativeWindowGeometry.minimumContentSize)
    ).size
    let defaultFrameSize = window.frameRect(
      forContentRect: NSRect(origin: .zero, size: NativeWindowGeometry.initialContentSize)
    ).size
    let screens = NSScreen.screens.map(\.visibleFrame)
    let fallbackScreen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    guard
      let constrainedFrame = NativeWindowGeometry.constrainedFrame(
        window.frame,
        minimumSize: minimumFrameSize,
        defaultSize: defaultFrameSize,
        visibleFrames: screens,
        fallbackVisibleFrame: fallbackScreen
      ),
      constrainedFrame != window.frame
    else { return }

    window.setFrame(constrainedFrame, display: false)
  }

  private func saveFrame(_ window: NSWindow?) {
    guard let window, !window.styleMask.contains(.fullScreen) else { return }
    window.saveFrame(usingName: NativeWindowGeometry.frameAutosaveName)
  }
}

@MainActor
public protocol NativeWindowControlling: AnyObject {
  @discardableResult func show() -> Bool
  func hide()
  func shutdown()
}

/// Typed in-process facade used by the AppKit shell. Keeping the coordinator
/// itself private to this module prevents lifecycle code from reaching into
/// the SwiftUI store or window internals.
@MainActor
public final class NativeWindowFacade: NativeWindowControlling {
  public static let shared = NativeWindowFacade()

  private init() {}

  @discardableResult
  public func show() -> Bool {
    NativeWindowCoordinator.shared.show()
  }

  public func hide() {
    NativeWindowCoordinator.shared.hide()
  }

  public func shutdown() {
    NativeWindowCoordinator.shared.shutdown()
  }
}
