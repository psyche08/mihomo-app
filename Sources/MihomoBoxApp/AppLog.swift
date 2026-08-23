import AppKit
import Foundation
import MihomoDNSCore
import os

enum AppStartupTimeline {
  enum Phase: String {
    case processStarted = "process_started"
    case backgroundServicesStarted = "background_services_started"
    case statusItemReady = "status_item_ready"
    case firstControlSnapshot = "first_control_snapshot"
    case componentSyncComplete = "component_sync_complete"
  }

  private static let clock = MonotonicStartupClock()

  static func mark(_ phase: Phase) {
    AppLog.info(
      "event=app_startup phase=\(phase.rawValue) elapsed_ms=\(clock.elapsedMilliseconds())"
    )
  }
}

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
