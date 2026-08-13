import AppKit
import Dispatch
import SwiftUI

/// Owns the one native main window hosted inside Tauri's `NSApplication`.
///
/// Tauri remains responsible for the process event loop and accessory
/// activation policy. This coordinator deliberately creates neither a second
/// `NSApplication` nor a SwiftUI `App` scene.
@MainActor
final class NativeWindowCoordinator: NSObject, NSWindowDelegate {
  static let shared = NativeWindowCoordinator()

  private enum Layout {
    static let initialSize = NSSize(width: 1_280, height: 820)
    static let minimumSize = NSSize(width: 900, height: 600)
    static let frameAutosaveName = "MihomoBox.MainWindow"
  }

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

    // Do not change NSApp.activationPolicy here. Tauri intentionally keeps
    // MihomoBox as an accessory/menu-bar application.
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    return window.isVisible
  }

  func hide() {
    dispatchPrecondition(condition: .onQueue(.main))

    dashboardStore.setVisible(false)
    dashboardStore.stop()
    window?.orderOut(nil)
  }

  func shutdown() {
    dispatchPrecondition(condition: .onQueue(.main))

    dashboardStore.setVisible(false)
    dashboardStore.stop()

    guard let window else { return }
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

  private func existingOrCreateWindow() -> NSWindow {
    if let window {
      return window
    }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Layout.initialSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MihomoBox"
    window.contentMinSize = Layout.minimumSize
    window.contentViewController = NSHostingController(rootView: RootView())
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    _ = window.setFrameAutosaveName(Layout.frameAutosaveName)

    self.window = window
    return window
  }
}

/// These C entry points are invoked only by Rust's `native_window` wrappers,
/// which enqueue every call on Tauri's main event loop before crossing the ABI.
@MainActor
@_cdecl("mihomobox_ui_show")
public func mihomoboxUIShow() -> Int32 {
  dispatchPrecondition(condition: .onQueue(.main))
  return NativeWindowCoordinator.shared.show() ? 1 : 0
}

@MainActor
@_cdecl("mihomobox_ui_hide")
public func mihomoboxUIHide() {
  dispatchPrecondition(condition: .onQueue(.main))
  NativeWindowCoordinator.shared.hide()
}

@MainActor
@_cdecl("mihomobox_ui_shutdown")
public func mihomoboxUIShutdown() {
  dispatchPrecondition(condition: .onQueue(.main))
  NativeWindowCoordinator.shared.shutdown()
}
