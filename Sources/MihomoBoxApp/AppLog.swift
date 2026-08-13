import AppKit
import Foundation
import os

enum AppLog {
  private static let logger = Logger(subsystem: "dev.linsheng.mihomo-app", category: "app")

  static func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }

  static func openDiagnostics() {
    let workspace = NSWorkspace.shared
    workspace.open(URL(fileURLWithPath: "/Applications/Utilities/Console.app"))
    workspace.open(URL(fileURLWithPath: "/Library/Logs/Mihomo App", isDirectory: true))
  }
}
