import AppKit
import SwiftUI
import XCTest

@testable import MihomoBoxUI

@MainActor
final class NativeWindowGeometryTests: XCTestCase {
  func testPreservesSizeAndMovesPartiallyHiddenFrameFullyOnScreen() throws {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    let frame = try XCTUnwrap(
      NativeWindowGeometry.constrainedFrame(
        NSRect(x: 1_300, y: 850, width: 1_200, height: 700),
        minimumSize: NSSize(width: 900, height: 632),
        defaultSize: NSSize(width: 1_280, height: 852),
        visibleFrames: [visibleFrame],
        fallbackVisibleFrame: visibleFrame
      )
    )

    XCTAssertEqual(frame, NSRect(x: 240, y: 200, width: 1_200, height: 700))
  }

  func testUsesFallbackScreenWhenSavedDisplayIsDisconnected() throws {
    let mainScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    let frame = try XCTUnwrap(
      NativeWindowGeometry.constrainedFrame(
        NSRect(x: 3_000, y: 200, width: 1_100, height: 700),
        minimumSize: NSSize(width: 900, height: 632),
        defaultSize: NSSize(width: 1_280, height: 852),
        visibleFrames: [mainScreen],
        fallbackVisibleFrame: mainScreen
      )
    )

    XCTAssertEqual(frame, NSRect(x: 340, y: 200, width: 1_100, height: 700))
  }

  func testClampsRestoredSizeBetweenMinimumAndVisibleScreen() throws {
    let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)

    let undersized = try XCTUnwrap(
      NativeWindowGeometry.constrainedFrame(
        NSRect(x: 500, y: 400, width: 300, height: 200),
        minimumSize: NSSize(width: 900, height: 632),
        defaultSize: NSSize(width: 1_280, height: 852),
        visibleFrames: [visibleFrame],
        fallbackVisibleFrame: visibleFrame
      )
    )
    let oversized = try XCTUnwrap(
      NativeWindowGeometry.constrainedFrame(
        NSRect(x: -500, y: -500, width: 3_000, height: 2_000),
        minimumSize: NSSize(width: 900, height: 632),
        defaultSize: NSSize(width: 1_280, height: 852),
        visibleFrames: [visibleFrame],
        fallbackVisibleFrame: visibleFrame
      )
    )

    XCTAssertEqual(undersized, NSRect(x: 400, y: 218, width: 900, height: 632))
    XCTAssertEqual(oversized, visibleFrame)
  }

  func testInvalidSavedGeometryUsesDefaultSizeCenteredOnFallbackScreen() throws {
    let visibleFrame = NSRect(x: -1_440, y: 0, width: 1_440, height: 900)

    let frame = try XCTUnwrap(
      NativeWindowGeometry.constrainedFrame(
        NSRect(
          x: CGFloat.nan,
          y: CGFloat.infinity,
          width: CGFloat.nan,
          height: CGFloat.nan
        ),
        minimumSize: NSSize(width: 900, height: 632),
        defaultSize: NSSize(width: 1_280, height: 852),
        visibleFrames: [visibleFrame],
        fallbackVisibleFrame: visibleFrame
      )
    )

    XCTAssertEqual(frame, NSRect(x: -1_360, y: 24, width: 1_280, height: 852))
  }

  func testAppKitFrameAutosaveRoundTripRestoresFrame() throws {
    _ = NSApplication.shared
    let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
    let autosaveName: NSWindow.FrameAutosaveName =
      "MihomoBox.Tests.\(UUID().uuidString)"
    let defaultsKey = "NSWindow Frame \(autosaveName)"
    NSWindow.removeFrame(usingName: autosaveName)

    let savedWindow = makeWindow()
    let restoredWindow = makeWindow()
    defer {
      savedWindow.close()
      restoredWindow.close()
      NSWindow.removeFrame(usingName: autosaveName)
      UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    let savedFrame = NSRect(
      x: visibleFrame.minX + 24,
      y: visibleFrame.minY + 24,
      width: min(1_100, visibleFrame.width - 48),
      height: min(720, visibleFrame.height - 48)
    )
    savedWindow.setFrame(savedFrame, display: false)
    savedWindow.saveFrame(usingName: autosaveName)

    XCTAssertNotNil(UserDefaults.standard.string(forKey: defaultsKey))
    restoredWindow.setFrame(
      NSRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 420, height: 320),
      display: false
    )
    XCTAssertTrue(restoredWindow.setFrameUsingName(autosaveName))
    XCTAssertEqual(restoredWindow.frame, savedWindow.frame)
  }

  func testHostingControllerFillsWindowWithoutDrivingItsSize() {
    let hostingController = NSHostingController(rootView: EmptyView())

    NativeWindowHosting.configure(hostingController)

    XCTAssertEqual(hostingController.sizingOptions, [])
    XCTAssertTrue(hostingController.view.autoresizingMask.contains(.width))
    XCTAssertTrue(hostingController.view.autoresizingMask.contains(.height))
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    // XCTest retains these windows until the method returns; prevent AppKit's
    // legacy close-time self-release from racing ARC teardown.
    window.isReleasedWhenClosed = false
    return window
  }
}
