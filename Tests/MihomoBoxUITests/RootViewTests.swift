import AppKit
import SwiftUI
import XCTest

@testable import MihomoBoxUI

@MainActor
final class RootViewTests: XCTestCase {
  func testExpandedSidebarNavigationActivatesFromTrailingBlankArea() throws {
    _ = NSApplication.shared
    var actionCount = 0
    let rowSize = NSSize(width: 192, height: 40)
    let hostingView = NSHostingView(
      rootView: DashboardSidebarNavigationButton(
        page: .proxies,
        isSelected: false,
        compact: false
      ) {
        actionCount += 1
      }
      .frame(width: rowSize.width, height: rowSize.height)
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: rowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    defer {
      window.orderOut(nil)
      window.close()
    }
    hostingView.layoutSubtreeIfNeeded()

    // The icon and title occupy the leading side. This point is deliberately
    // inside the row's far-right transparent spacer, not inside visible text.
    let trailingBlankPoint = NSPoint(x: rowSize.width - 4, y: rowSize.height / 2)
    try sendClick(at: trailingBlankPoint, to: window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    XCTAssertEqual(actionCount, 1)
  }

  private func sendClick(at point: NSPoint, to window: NSWindow) throws {
    let timestamp = ProcessInfo.processInfo.systemUptime
    let mouseDown = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )
    )
    let mouseUp = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: point,
        modifierFlags: [],
        timestamp: timestamp + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0
      )
    )
    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
  }
}
