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
      offset: -2,
      uploadSpeed: 120,
      downloadSpeed: 640
    )
    let closedSafari = connection(id: "safari-closed", process: "Safari", offset: -20)
    let code = connection(id: "code", process: "Code", offset: -4)
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

  func testClientNameFallsBackToExecutableBasename() {
    let item = connection(
      id: "helper",
      process: nil,
      path: "/Applications/Example.app/Contents/MacOS/Example Helper",
      offset: 0
    )

    XCTAssertEqual(ConnectionsPresentation.clientName(for: item), "Example Helper")
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
