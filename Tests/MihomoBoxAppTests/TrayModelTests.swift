import XCTest

@testable import MihomoBoxApp

final class TrayModelTests: XCTestCase {
  func testDelayOnlyChangeRepaintsWithoutRebuildingTrackedMenu() {
    let rendered = snapshot(delay: 180)
    let incoming = snapshot(delay: 420)

    XCTAssertEqual(rendered.menuSignature, incoming.menuSignature)
    XCTAssertEqual(
      TrayMenuUpdatePolicy.decision(
        rendered: rendered,
        incoming: incoming,
        isTracking: true
      ),
      .repaintDelaysOnly
    )
  }

  func testStructuralChangeIsDeferredWhileMenuIsTracking() {
    let rendered = snapshot(delay: 180)
    var incoming = rendered
    incoming.outboundMode = .global

    XCTAssertEqual(
      TrayMenuUpdatePolicy.decision(
        rendered: rendered,
        incoming: incoming,
        isTracking: true
      ),
      .repaintDelaysAndDeferRebuild
    )
    XCTAssertEqual(
      TrayMenuUpdatePolicy.decision(
        rendered: rendered,
        incoming: incoming,
        isTracking: false
      ),
      .rebuildNow
    )
  }

  func testFirstSnapshotBuildsMenu() {
    XCTAssertEqual(
      TrayMenuUpdatePolicy.decision(
        rendered: nil,
        incoming: snapshot(delay: nil),
        isTracking: false
      ),
      .rebuildNow
    )
  }

  func testDelayLabelsKeepExistingTrafficBands() {
    XCTAssertEqual(TrayProxyNode.delayLabel(nil), "⚪ --")
    XCTAssertEqual(TrayProxyNode.delayLabel(0), "⚪ --")
    XCTAssertEqual(TrayProxyNode.delayLabel(300), "🟢 300 ms")
    XCTAssertEqual(TrayProxyNode.delayLabel(301), "🟠 301 ms")
    XCTAssertEqual(TrayProxyNode.delayLabel(800), "🟠 800 ms")
    XCTAssertEqual(TrayProxyNode.delayLabel(801), "🔴 801 ms")
  }

  func testUpdateMenuAvailabilityCanChangeWithoutSnapshotRebuild() {
    XCTAssertFalse(TrayUpdateAvailabilityPolicy.isEnabled(canCheckForUpdates: false))
    XCTAssertTrue(TrayUpdateAvailabilityPolicy.isEnabled(canCheckForUpdates: true))
  }

  func testStaleEnhancedTUNCheckmarkRefreshesInsteadOfReplayingInstallerAction() {
    XCTAssertEqual(
      TrayEnhancedTUNClickPolicy.decision(
        displayedEnhancedTUN: true,
        latestEnhancedTUN: false
      ),
      .refreshAuthoritatively
    )
    XCTAssertEqual(
      TrayEnhancedTUNClickPolicy.decision(
        displayedEnhancedTUN: false,
        latestEnhancedTUN: false
      ),
      .request(enabled: true)
    )
    XCTAssertEqual(
      TrayEnhancedTUNClickPolicy.decision(
        displayedEnhancedTUN: true,
        latestEnhancedTUN: true
      ),
      .request(enabled: false)
    )
  }

  func testInstallerAndProfileActionsFailClosedDuringMutations() {
    var snapshot = TraySnapshot(
      profileActionsAvailable: true,
      installationActionsAvailable: true,
      enhancedTUNActionAvailable: true
    )
    XCTAssertTrue(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.installerEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))

    snapshot.mutationOperationInFlight = true
    XCTAssertFalse(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.installerEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))

    snapshot.mutationOperationInFlight = false
    snapshot.profileOperationInFlight = true
    XCTAssertFalse(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.installerEnabled(snapshot))

    snapshot.profileOperationInFlight = false
    snapshot.tunOperationInFlight = true
    XCTAssertFalse(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))
    snapshot.tunOperationInFlight = false
    snapshot.enhancedTUNActionAvailable = false
    XCTAssertFalse(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))
  }

  func testUnavailableProfileOrInstallerCapabilityStaysDisabled() {
    let snapshot = TraySnapshot(
      profileActionsAvailable: false,
      installationActionsAvailable: false
    )
    XCTAssertFalse(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.installerEnabled(snapshot))
  }

  func testStoppedStatusRequiresCompleteRestoreTruth() {
    var snapshot = TraySnapshot(
      controllerReachable: false,
      daemonReachable: true,
      agentRunning: false,
      networkHealthy: true,
      systemDNSManaged: false,
      healthTUNEnabled: false
    )
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Stopped — DNS restored")

    snapshot.networkHealthy = nil
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Stopped — restore unconfirmed")
    snapshot.networkHealthy = true
    snapshot.systemDNSManaged = true
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Stopped — restore unconfirmed")
  }

  func testProfileReloadRequiresActiveProfileAndReachableController() {
    var snapshot = TraySnapshot(
      controllerReachable: true,
      profiles: ["default.yaml"],
      activeProfile: "default.yaml"
    )
    XCTAssertTrue(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    snapshot.controllerReachable = false
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    snapshot.controllerReachable = true
    snapshot.activeProfile = nil
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
  }

  private func snapshot(delay: Int?) -> TraySnapshot {
    TraySnapshot(
      controllerReachable: true,
      enhancedTUN: true,
      networkHealthy: true,
      outboundMode: .rule,
      proxies: [
        TrayProxyNode(
          group: "Proxy",
          name: "Tokyo",
          delayMilliseconds: delay,
          isSelected: true
        )
      ],
      profiles: ["default.yaml"],
      activeProfile: "default.yaml",
      installationActionsAvailable: true
    )
  }
}
