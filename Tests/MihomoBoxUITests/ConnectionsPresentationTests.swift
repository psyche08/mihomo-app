import Foundation
import XCTest

@testable import MihomoBoxUI

final class ConnectionsPresentationTests: XCTestCase {
  func testRecentConnectionsDeduplicateActiveAndOrderNewestFirst() {
    let oldest = connection(id: "old", process: "Safari", offset: -30)
    let newest = connection(id: "new", process: "Code", offset: -5)
    let duplicate = connection(id: "old", process: "Safari", offset: -30)

    let recent = ConnectionsPresentation.recent(
      active: [oldest],
      closed: [newest, duplicate]
    )

    XCTAssertEqual(recent.map(\.id), ["new", "old"])
  }

  func testClientGroupsAggregateActiveCountsAndLiveSpeedByProcess() throws {
    let activeSafari = connection(
      id: "safari-active",
      process: "Safari",
      path: "/usr/bin/Safari",
      offset: -2,
      uploadSpeed: 120,
      downloadSpeed: 640
    )
    let closedSafari = connection(
      id: "safari-closed", process: "Safari", path: "/usr/bin/Safari", offset: -20)
    let code = connection(id: "code", process: "Code", path: "/usr/bin/Code", offset: -4)
    let unknown = connection(id: "unknown", process: nil, path: nil, offset: -8)

    let groups = ConnectionsPresentation.clientGroups(
      active: [activeSafari, code],
      closed: [closedSafari, unknown]
    )

    XCTAssertEqual(groups.map(\.name), ["Code", "Safari", "Unknown Process"])
    let safari = try XCTUnwrap(groups.first { $0.name == "Safari" })
    XCTAssertEqual(safari.activeCount, 1)
    XCTAssertEqual(safari.recentCount, 2)
    XCTAssertEqual(safari.uploadSpeed, 120)
    XCTAssertEqual(safari.downloadSpeed, 640)
  }

  func testClientGroupsMergeMainAndNestedHelperIntoOutermostApplication() throws {
    let main = connection(
      id: "dumbo-main",
      process: "Dumbo",
      path: "/Applications/Dumbo.app/Contents/MacOS/Dumbo",
      offset: -2,
      downloadSpeed: 128
    )
    let helper = connection(
      id: "dumbo-helper",
      process: "Dumbo Helper",
      path:
        "/Applications/Dumbo.app/Contents/Frameworks/Dumbo Helper.app/Contents/MacOS/Dumbo Helper",
      offset: -1,
      uploadSpeed: 64
    )

    let groups = ConnectionsPresentation.clientGroups(active: [main, helper], closed: [])

    let group = try XCTUnwrap(groups.first)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(group.name, "Dumbo")
    XCTAssertEqual(group.applicationBundlePath, "/Applications/Dumbo.app")
    XCTAssertEqual(group.activeCount, 2)
    XCTAssertEqual(group.recentCount, 2)
    XCTAssertEqual(group.uploadSpeed, 64)
    XCTAssertEqual(group.downloadSpeed, 128)
    XCTAssertEqual(
      ConnectionsPresentation.clientID(for: main),
      ConnectionsPresentation.clientID(for: helper)
    )
  }

  func testClientNameFallsBackToExecutableBasename() {
    let item = connection(
      id: "helper",
      process: nil,
      path: "/usr/local/bin/Example Helper",
      offset: 0
    )

    XCTAssertEqual(ConnectionsPresentation.clientName(for: item), "Example Helper")
  }

  func testClientNameUsesOutermostApplicationNameBeforeHelperProcessName() {
    let item = connection(
      id: "helper",
      process: "Example Helper (Renderer)",
      path:
        "/Applications/Example.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper",
      offset: 0
    )

    XCTAssertEqual(ConnectionsPresentation.clientName(for: item), "Example")
    XCTAssertEqual(ConnectionsPresentation.processName(for: item), "Example Helper (Renderer)")
    XCTAssertEqual(
      ConnectionsPresentation.applicationBundlePath(for: item),
      "/Applications/Example.app"
    )
  }

  private func connection(
    id: String,
    process: String?,
    path: String? = "/Applications/Example.app/Contents/MacOS/Example",
    offset: TimeInterval,
    uploadSpeed: Int64 = 0,
    downloadSpeed: Int64 = 0
  ) -> DashboardConnection {
    DashboardConnection(
      id: id,
      host: "example.com",
      destination: "203.0.113.1:443",
      network: "TCP",
      process: process,
      processPath: path,
      rule: "MATCH",
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      startedAt: Date(timeIntervalSince1970: 1_000 + offset)
    )
  }
}
