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

  func testTrayPollingIsFastOnlyDuringStartupAndSlowWhileHealthy() {
    XCTAssertEqual(
      TrayPollingPolicy.interval(controllerReachable: false, startupAttempt: 0),
      .milliseconds(500)
    )
    XCTAssertEqual(
      TrayPollingPolicy.interval(
        controllerReachable: false,
        startupAttempt: TrayPollingPolicy.startupFastAttempts
      ),
      .seconds(10)
    )
    XCTAssertEqual(
      TrayPollingPolicy.interval(controllerReachable: true, startupAttempt: 0),
      .seconds(30)
    )
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
      daemonCompatibility: .compatible,
      profileActionsAvailable: true,
      installationActionsAvailable: true,
      managedInstallationPresent: true,
      enhancedTUNActionAvailable: true
    )
    XCTAssertTrue(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.installerEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.uninstallerEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))

    snapshot.mutationOperationInFlight = true
    XCTAssertFalse(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.installerEnabled(snapshot))
    XCTAssertFalse(TrayMenuActionPolicy.uninstallerEnabled(snapshot))
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

  func testUninstallRequiresBothSignedInstallerAndManagedArtifacts() {
    var snapshot = TraySnapshot(
      installationActionsAvailable: true,
      managedInstallationPresent: false
    )
    XCTAssertFalse(TrayMenuActionPolicy.uninstallerEnabled(snapshot))
    snapshot.managedInstallationPresent = true
    XCTAssertTrue(TrayMenuActionPolicy.uninstallerEnabled(snapshot))
    snapshot.installationActionsAvailable = false
    XCTAssertFalse(TrayMenuActionPolicy.uninstallerEnabled(snapshot))
  }

  func testUnavailableProfileOrInstallerCapabilityStaysDisabled() {
    let snapshot = TraySnapshot(
      daemonCompatibility: .compatible,
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

  func testBusyNetworkStatusNamesTheCurrentPhase() {
    var snapshot = TraySnapshot(tunOperationInFlight: true)
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Starting…")

    snapshot.enhancedTUN = true
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Stopping…")

    snapshot.tunOperationInFlight = false
    snapshot.profileOperationInFlight = true
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Applying profile…")

    snapshot.profileOperationInFlight = false
    snapshot.mutationOperationInFlight = true
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Applying change…")
  }

  func testProfileReloadRequiresActiveProfileAndReachableController() {
    var snapshot = TraySnapshot(
      daemonCompatibility: .compatible,
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

  func testProtocolCompatibilityStatusesTakePriorityOverRuntimeState() {
    var snapshot = TraySnapshot(
      daemonCompatibility: .legacyRepairRequired(peerVersion: 1),
      controllerReachable: true,
      daemonReachable: true,
      agentRunning: true,
      networkHealthy: true
    )
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Daemon upgrade required")
    XCTAssertEqual(snapshot.tooltip, "MihomoBox · daemon repair required")

    snapshot.daemonCompatibility = .appUpdateRequired(peerVersion: 3)
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: App update required")
    XCTAssertEqual(snapshot.tooltip, "MihomoBox · app update required")

    snapshot.daemonCompatibility = .incompatible(peerVersion: 0)
    XCTAssertEqual(snapshot.networkStatusTitle, "Network: Protocol incompatible")
    XCTAssertEqual(snapshot.tooltip, "MihomoBox · protocol incompatible")
  }

  func testActionErrorRemainsVisibleWhileDaemonRepairIsRequired() {
    let snapshot = TraySnapshot(
      daemonCompatibility: .legacyRepairRequired(peerVersion: 1),
      actionError: "Action failed: daemon repair did not complete"
    )
    XCTAssertEqual(
      snapshot.networkStatusTitle,
      "Action failed: daemon repair did not complete"
    )
    XCTAssertEqual(snapshot.tooltip, "MihomoBox · daemon repair required")
    XCTAssertTrue(TrayDaemonMenuPolicy.showsUpgradeAction(snapshot))
  }

  func testProtocolMismatchDisablesControlTunAndProfileActions() {
    let compatibilities: [DaemonProtocolCompatibility] = [
      .legacyRepairRequired(peerVersion: 1),
      .appUpdateRequired(peerVersion: 3),
      .incompatible(peerVersion: 0),
    ]

    for compatibility in compatibilities {
      let snapshot = TraySnapshot(
        daemonCompatibility: compatibility,
        controllerReachable: true,
        enhancedTUN: true,
        profiles: ["default.yaml"],
        activeProfile: "default.yaml",
        profileActionsAvailable: true,
        installationActionsAvailable: true,
        enhancedTUNActionAvailable: true
      )
      XCTAssertTrue(compatibility.blocksControlActions)
      XCTAssertFalse(TrayMenuActionPolicy.controllerActionEnabled(snapshot))
      XCTAssertFalse(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))
      XCTAssertFalse(TrayMenuActionPolicy.profileActionEnabled(snapshot))
      XCTAssertFalse(TrayMenuActionPolicy.profileReloadEnabled(snapshot))
    }
  }

  func testUnknownCompatibilityPreservesFirstInstallActions() {
    let snapshot = TraySnapshot(
      daemonCompatibility: .unknown,
      profileActionsAvailable: true,
      installationActionsAvailable: true,
      enhancedTUNActionAvailable: true
    )
    XCTAssertFalse(snapshot.daemonCompatibility.blocksControlActions)
    XCTAssertTrue(TrayMenuActionPolicy.enhancedTUNEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.profileActionEnabled(snapshot))
    XCTAssertTrue(TrayMenuActionPolicy.installerEnabled(snapshot))
  }

  func testOnlyLegacyMismatchOffersRequiredDaemonUpgrade() {
    let legacy = TraySnapshot(
      daemonCompatibility: .legacyRepairRequired(peerVersion: 1),
      installationActionsAvailable: true
    )
    XCTAssertTrue(legacy.daemonCompatibility.requiresRepair)
    XCTAssertTrue(TrayMenuActionPolicy.installerEnabled(legacy))
    XCTAssertTrue(TrayDaemonMenuPolicy.showsUpgradeAction(legacy))
    XCTAssertEqual(
      TrayDaemonMenuPolicy.installerTitle(legacy),
      "Install / Repair Daemon… (Required)"
    )

    for compatibility in [
      DaemonProtocolCompatibility.appUpdateRequired(peerVersion: 3),
      .incompatible(peerVersion: 0),
    ] {
      let snapshot = TraySnapshot(
        daemonCompatibility: compatibility,
        installationActionsAvailable: true
      )
      XCTAssertFalse(compatibility.requiresRepair)
      XCTAssertFalse(TrayMenuActionPolicy.installerEnabled(snapshot))
      XCTAssertFalse(TrayDaemonMenuPolicy.showsUpgradeAction(snapshot))
      XCTAssertEqual(
        TrayDaemonMenuPolicy.installerTitle(snapshot),
        "Install / Repair Daemon…"
      )
    }
  }

  func testCompatibilityChangeForcesMenuRebuild() {
    let rendered = snapshot(delay: 180)
    var incoming = rendered
    incoming.daemonCompatibility = .legacyRepairRequired(peerVersion: 1)

    XCTAssertNotEqual(rendered.menuSignature, incoming.menuSignature)
    XCTAssertEqual(
      TrayMenuUpdatePolicy.decision(
        rendered: rendered,
        incoming: incoming,
        isTracking: false
      ),
      .rebuildNow
    )
  }

  private func snapshot(delay: Int?) -> TraySnapshot {
    TraySnapshot(
      daemonCompatibility: .compatible,
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
