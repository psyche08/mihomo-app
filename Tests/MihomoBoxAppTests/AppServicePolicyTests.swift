import Foundation
import XCTest

@testable import MihomoBoxApp

final class AppServicePolicyTests: XCTestCase {
  func testEnhancedTUNUsesFiveExclusiveLifecycleStates() {
    XCTAssertEqual(
      EnhancedTUNActionPolicy.resolve(
        enhancedTUN: true, profileSelected: true, daemonInstalled: true,
        controllerReachable: true
      ),
      .stopAndRestore
    )
    XCTAssertEqual(
      EnhancedTUNActionPolicy.resolve(
        enhancedTUN: false, profileSelected: false, daemonInstalled: false,
        controllerReachable: false
      ),
      .requireProfile
    )
    XCTAssertEqual(
      EnhancedTUNActionPolicy.resolve(
        enhancedTUN: false, profileSelected: true, daemonInstalled: false,
        controllerReachable: false
      ),
      .installDaemon
    )
    XCTAssertEqual(
      EnhancedTUNActionPolicy.resolve(
        enhancedTUN: false, profileSelected: true, daemonInstalled: true,
        controllerReachable: false
      ),
      .startDaemon
    )
    XCTAssertEqual(
      EnhancedTUNActionPolicy.resolve(
        enhancedTUN: false, profileSelected: true, daemonInstalled: true,
        controllerReachable: true
      ),
      .enableTUN
    )
  }

  func testTrayControlPollDecodesRuntimeAndFlattensOnlyLeafNodes() throws {
    let payload = Data(
      #"""
      {
        "agent_running":true,
        "snapshot":{
          "configs":{"mode":"Rule","tun":{"enable":true}},
          "proxies":{"proxies":{
            "Proxy":{"now":"Tokyo","all":["Tokyo","DIRECT","Nested"]},
            "Nested":{"now":"Osaka","all":["Osaka"]},
            "Tokyo":{"history":[{"delay":41}]},
            "Osaka":{"history":[{"delay":0}]}
          }}
        },
        "profiles":{"profiles":["default.yaml"],"active_profile":"default.yaml"},
        "health":{"network_consistent":true}
      }
      """#.utf8)

    let decoded = try TrayControlClient.decodePoll(payload)
    XCTAssertTrue(decoded.agentRunning)
    XCTAssertTrue(decoded.controllerReachable)
    XCTAssertTrue(decoded.enhancedTUN)
    XCTAssertEqual(decoded.outboundMode, .rule)
    XCTAssertEqual(decoded.profiles, ["default.yaml"])
    XCTAssertEqual(decoded.proxies.map(\.name), ["Osaka", "Tokyo"])
    XCTAssertFalse(decoded.proxies.contains(where: { $0.name == "DIRECT" || $0.name == "Nested" }))
  }

  func testProxyAndGroupNamesRemainCaseSensitive() throws {
    let payload = Data(
      #"""
      {
        "agent_running":true,
        "snapshot":{
          "configs":{"mode":"Rule","tun":{"enable":false}},
          "proxies":{"proxies":{
            "auto":{"now":"Node","all":["Node"]},
            "Proxy":{"now":"Auto","all":["Auto"]},
            "Auto":{"history":[{"delay":55}]},
            "Node":{"history":[]}
          }}
        },
        "profiles":{"profiles":[],"active_profile":null},
        "health":{"network_consistent":true}
      }
      """#.utf8)
    let decoded = try TrayControlClient.decodePoll(payload)
    XCTAssertTrue(decoded.proxies.contains(where: { $0.name == "Auto" }))
  }

  func testProfileNameSizeAndCustomHeaderPolicy() throws {
    XCTAssertEqual(try ProfileCoordinator.validatedName("profile.yaml"), "profile.yaml")
    XCTAssertThrowsError(try ProfileCoordinator.validatedName("../profile.yaml"))
    XCTAssertThrowsError(try ProfileCoordinator.validatedName("profile.txt"))
    XCTAssertTrue(ProfileCoordinator.validHeaderName("X-API-Key"))
    XCTAssertFalse(ProfileCoordinator.validHeaderName("Content-Length"))
    XCTAssertFalse(ProfileCoordinator.validHeaderName("Authorization"))
    XCTAssertFalse(ProfileCoordinator.validHeaderName("Cookie"))
    XCTAssertFalse(ProfileCoordinator.validHeaderName("Bad Header"))
  }

  func testCrossOriginRedirectStripsCredentialsAndHTTPSDowngradeFails() throws {
    var request = URLRequest(url: URL(string: "https://cdn.example/profile.yaml")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    request.setValue("secret", forHTTPHeaderField: "X-API-Key")
    let redirected = try SubscriptionRedirectPolicy.redirectedRequest(
      request,
      from: URL(string: "https://origin.example/profile.yaml")!,
      authentication: .header(name: "X-API-Key", value: "secret")
    )
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "X-API-Key"))

    request.url = URL(string: "http://origin.example/profile.yaml")!
    XCTAssertThrowsError(
      try SubscriptionRedirectPolicy.redirectedRequest(
        request,
        from: URL(string: "https://origin.example/profile.yaml")!,
        authentication: .none
      ))
  }

  func testCredentialsRequireHTTPS() {
    let http = URL(string: "http://origin.example/profile.yaml")!
    let https = URL(string: "https://origin.example/profile.yaml")!
    XCTAssertTrue(SubscriptionTransportPolicy.allows(url: http, authentication: .none))
    XCTAssertFalse(
      SubscriptionTransportPolicy.allows(
        url: http,
        authentication: .bearer("secret")
      ))
    XCTAssertTrue(
      SubscriptionTransportPolicy.allows(
        url: https,
        authentication: .digest(username: "user", password: "secret")
      ))
  }

  func testStoppedHealthCarriesExplicitDNSRestoreTruth() throws {
    let payload = Data(
      #"""
      {
        "agent_running":false,
        "snapshot":null,
        "profiles":{"profiles":[],"active_profile":null},
        "health":{
          "controller_reachable":false,
          "tun_enabled":false,
          "system_dns_managed":false,
          "network_consistent":true
        }
      }
      """#.utf8)
    let decoded = try TrayControlClient.decodePoll(payload)
    XCTAssertFalse(decoded.agentRunning)
    XCTAssertFalse(decoded.controllerReachable)
    XCTAssertEqual(decoded.healthTUNEnabled, false)
    XCTAssertEqual(decoded.systemDNSManaged, false)
    XCTAssertEqual(decoded.networkHealthy, true)
  }

  func testInstallerQuotingAndSafeClassification() {
    XCTAssertEqual(InstallerCoordinator.shellQuote("A B's"), "'A B'\\''s'")
    let appleScript = InstallerCoordinator.appleScriptQuote("first\nsecond")
    XCTAssertFalse(appleScript.contains("\n"))
    XCTAssertTrue(appleScript.contains("\\n"))
    XCTAssertEqual(
      InstallerCoordinator.classification("configuration file test failed"), "profile_rejected")
    XCTAssertEqual(InstallerCoordinator.classification("timed out waiting for daemon"), "timeout")
    XCTAssertEqual(InstallerCoordinator.classification("arbitrary profile contents"), "other")
  }

  func testPrivilegedInstallerCopiesAndChecksExactRequirementsBeforeExecutingSnapshotScript() {
    let command = InstallerCoordinator.bootstrapCommand(
      sourceBundlePath: "/Applications/Owner's MihomoBox.app",
      appRequirement: "identifier app and certificate leaf = H\"aa\"",
      callerRequirement: "identifier caller and certificate leaf = H\"aa\"",
      callerRelativeExecutable: "Contents/MacOS/mihomo-app",
      installerArguments: [],
      detached: false
    )

    let ditto = command.range(of: "/usr/bin/ditto")
    let appVerification = command.range(of: "/usr/bin/codesign --verify --deep --strict")
    let callerVerification = appVerification.flatMap {
      command.range(
        of: "/usr/bin/codesign --verify --strict",
        range: $0.upperBound..<command.endIndex
      )
    }
    let installer = command.range(
      of: "installer=\"$snapshot/Contents/Resources/scripts/install-daemon.sh\"")
    let execution = command.range(of: "/bin/bash \"$installer\"")

    XCTAssertNotNil(ditto)
    XCTAssertNotNil(appVerification)
    XCTAssertNotNil(callerVerification)
    XCTAssertNotNil(installer)
    XCTAssertNotNil(execution)
    if let ditto, let appVerification, let callerVerification, let installer, let execution {
      XCTAssertLessThan(ditto.lowerBound, appVerification.lowerBound)
      XCTAssertLessThan(appVerification.lowerBound, callerVerification.lowerBound)
      XCTAssertLessThan(callerVerification.lowerBound, installer.lowerBound)
      XCTAssertLessThan(installer.lowerBound, execution.lowerBound)
      XCTAssertFalse(
        String(command[..<callerVerification.upperBound]).contains("install-daemon.sh"))
    }
    XCTAssertTrue(command.contains("--verified-app-snapshot"))
    XCTAssertFalse(command.contains("--client-app-bundle"))
    XCTAssertFalse(command.contains("--initial-profile"))
    XCTAssertTrue(command.contains("--all-architectures"))
    XCTAssertTrue(
      command.contains(
        "-R '\\''=identifier app and certificate leaf = H\"aa\"'\\'' \"$snapshot\""
      )
    )
    XCTAssertFalse(command.contains("--requirements"))
    XCTAssertTrue(command.contains("and certificate leaf = H\"aa\""))
    XCTAssertTrue(command.contains("identifier caller and certificate leaf = H\"aa\""))
    XCTAssertFalse(
      command.contains("/Applications/Owner's MihomoBox.app/Contents/Resources/scripts"))
  }

  func testDetachedInstallerStartsOnlyAfterSnapshotVerificationAndKeepsRootOnlyLog() {
    let command = InstallerCoordinator.bootstrapCommand(
      sourceBundlePath: "/Applications/MihomoBox.app",
      appRequirement: "identifier app",
      callerRequirement: "identifier caller",
      callerRelativeExecutable: "Contents/MacOS/mihomo-app",
      installerArguments: [],
      detached: true
    )
    let verification = command.range(of: "/usr/bin/codesign --verify --strict")
    let detached = command.range(of: "/usr/bin/nohup")
    XCTAssertNotNil(verification)
    XCTAssertNotNil(detached)
    if let verification, let detached {
      XCTAssertLessThan(verification.lowerBound, detached.lowerBound)
    }
    XCTAssertTrue(command.contains("/bin/chmod 0600 \"$log\" \"$pid_file\""))
    XCTAssertTrue(command.contains("/private/tmp/mihomobox-bootstrap.XXXXXX"))
  }

  func testInstallerResourceMustBeRegularAndExecutable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-installer-policy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let regular = root.appendingPathComponent("installer")
    XCTAssertTrue(FileManager.default.createFile(atPath: regular.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: regular.path)
    XCTAssertTrue(InstallerCoordinator.isRegularExecutable(regular))

    let symlink = root.appendingPathComponent("installer-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
    XCTAssertFalse(InstallerCoordinator.isRegularExecutable(symlink))
  }

  func testDefaultProvisioningProfileIsRejectOnly() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let config = try String(
      contentsOf: repository.appendingPathComponent("deploy/default-config.yaml"),
      encoding: .utf8
    )
    XCTAssertTrue(config.contains("      - REJECT\n"))
    XCTAssertFalse(config.contains("      - DIRECT\n"))
  }

  func testShellEntrypointsCannotRunOriginalBundleScriptAsRoot() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let installer = try String(
      contentsOf: repository.appendingPathComponent("scripts/install-daemon.sh"),
      encoding: .utf8
    )
    XCTAssertTrue(
      installer.contains("refusing privileged execution outside the signed Swift bootstrap"))
    XCTAssertTrue(installer.contains("--verified-app-snapshot"))
    XCTAssertTrue(installer.contains("-ef \"${BASH_SOURCE[0]}\""))
    XCTAssertTrue(installer.contains("refusing non-root or symlinked managed directory"))
    XCTAssertTrue(installer.contains("! -L \"$DAEMON_SOURCE\""))
    XCTAssertTrue(installer.contains("! -L \"$AGENT_SOURCE\""))
    XCTAssertTrue(installer.contains("! -L \"$MIHOMO_SOURCE\""))
    XCTAssertFalse(installer.contains("codesign -d -r-"))
    XCTAssertFalse(installer.contains("verify_and_snapshot_app_bundle"))
    XCTAssertTrue(installer.contains("CFBundleShortVersionString raw"))
    XCTAssertTrue(installer.contains("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    XCTAssertTrue(installer.contains("$APP_SUPPORT/.component-version.XXXXXX"))
    XCTAssertTrue(installer.contains("/bin/chmod 0600 \"$staged\""))
    XCTAssertTrue(installer.contains("/bin/mv -f \"$staged\" \"$COMPONENT_VERSION\""))
    XCTAssertTrue(installer.contains("PROVISIONING_STATE=\"$APP_SUPPORT/provisioning\""))
    XCTAssertTrue(installer.contains("authenticated daemon XPC"))
    XCTAssertTrue(installer.contains("provisioning=$provisioning_install"))
    let versionCommit = installer.range(of: "write_component_version", options: .backwards)
    let daemonBootstrap = versionCommit.flatMap {
      installer.range(
        of: "run /bin/launchctl bootstrap system \"$PLIST\"",
        range: $0.upperBound..<installer.endIndex
      )
    }
    XCTAssertNotNil(versionCommit)
    XCTAssertNotNil(daemonBootstrap)
    if let versionCommit, let daemonBootstrap {
      XCTAssertLessThan(versionCommit.lowerBound, daemonBootstrap.lowerBound)
    }
    XCTAssertTrue(installer.contains("local managed_target=\"$APP_SUPPORT/mihomoboxctl\""))
    XCTAssertTrue(
      installer.contains(
        "run /usr/bin/install -o root -g wheel -m 0755 \"$CLI_SOURCE\" \"$APP_SUPPORT/mihomoboxctl\""
      ))
    XCTAssertTrue(installer.contains("installed CLI readback failed"))
    XCTAssertTrue(
      installer.contains("/usr/bin/cmp -s \"$CLI_SOURCE\" \"$APP_SUPPORT/mihomoboxctl\""))
    XCTAssertTrue(installer.contains("run /bin/ln -sfn \"$managed_target\" \"$CLI_ENTRY\""))
    XCTAssertTrue(installer.contains("managed CLI link readback failed"))
    XCTAssertTrue(
      installer.contains(
        "\"$(/usr/bin/readlink \"$CLI_ENTRY\")\" == \"$installed_target\""
      ))
    XCTAssertFalse(installer.contains("*/MihomoBox.app/Contents/MacOS/mihomoboxctl"))
    XCTAssertFalse(installer.contains("--client-app-bundle"))
    XCTAssertFalse(installer.contains("--initial-profile"))
    XCTAssertTrue(installer.contains("CLI_TARGET_METADATA=\"$APP_SUPPORT/cli-target\""))
    XCTAssertTrue(installer.contains("existing_target\" != \"$recorded_target"))

    let cli = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoBoxCLI/main.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(cli.contains("SecCodeCopySelf([], &dynamicCode)"))
    XCTAssertTrue(cli.contains("and cdhash H\\\"\\(cdhash)\\\""))
    XCTAssertTrue(cli.contains("/usr/bin/ditto \\(source) \"$snapshot\""))
    XCTAssertTrue(cli.contains("-R \\(appRequirement) \"$snapshot\""))
    XCTAssertTrue(cli.contains("-R \\(callerRequirement) \"$caller\""))
    XCTAssertFalse(cli.contains("--client-app-bundle"))
    XCTAssertFalse(cli.contains("--requirements"))

    let remote = try String(
      contentsOf: repository.appendingPathComponent("scripts/install-daemon-remote.sh"),
      encoding: .utf8
    )
    XCTAssertTrue(remote.contains("do not run install-daemon-remote.sh with sudo or as root"))
    XCTAssertTrue(remote.contains("/usr/sbin/spctl --assess --type execute"))
    XCTAssertTrue(remote.contains("exec \"$CLI\" install --detached"))
    XCTAssertFalse(remote.contains("nohup /bin/bash \"$INSTALLER\""))
  }

  func testKernelValidationReasonIsBoundedAndOnlyUsesErrorLine() {
    XCTAssertNil(ProfileCoordinator.firstConfigError("level=info msg=all good"))
    let reason = ProfileCoordinator.firstConfigError(
      "level=info msg=ignored\nlevel=error msg=\"\(String(repeating: "x", count: 300))\""
    )
    XCTAssertNotNil(reason)
    XCTAssertLessThanOrEqual(reason?.count ?? 999, 210)

    let credentialReason = ProfileCoordinator.firstConfigError(
      "level=error msg=provider https://example.com/sub?token=private-token "
        + "password=hunter2 authorization=BearerSecret"
    )
    XCTAssertFalse(credentialReason?.contains("private-token") ?? true)
    XCTAssertFalse(credentialReason?.contains("hunter2") ?? true)
    XCTAssertFalse(credentialReason?.contains("BearerSecret") ?? true)
    XCTAssertTrue(credentialReason?.contains("<redacted>") ?? false)
  }

  func testSeparateProfileAndInstallerAvailabilityParticipateInMenuSignature() {
    let base = TraySnapshot(profileActionsAvailable: true, installationActionsAvailable: false)
    var changed = base
    changed.profileActionsAvailable = false
    XCTAssertNotEqual(base.menuSignature, changed.menuSignature)
  }

  func testStoppedInstalledDaemonCanKeepTUNActionAvailableWithoutInstaller() {
    let snapshot = TraySnapshot(
      controllerReachable: false,
      enhancedTUN: false,
      profiles: ["default.yaml"],
      activeProfile: "default.yaml",
      installationActionsAvailable: false,
      enhancedTUNActionAvailable: true
    )
    XCTAssertTrue(snapshot.enhancedTUNActionAvailable)
  }

  func testOfflineLocalProfileStateSurvivesColdStart() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-offline-profile-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("profiles")
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try Data("mode: rule\n".utf8).write(to: profiles.appendingPathComponent("offline.yaml"))
    try Data("offline.yaml\n".utf8).write(to: root.appendingPathComponent("active-profile"))
    let coordinator = ProfileCoordinator(control: TrayControlClient(), root: root)
    let state = await coordinator.localState()
    XCTAssertEqual(state.profiles, ["offline.yaml"])
    XCTAssertEqual(state.activeProfile, "offline.yaml")
  }

  func testOfflineProfilePolicyListsOnlyYAMLAndValidatesActiveSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-profile-policy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let profiles = root.appendingPathComponent("profiles")
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try Data("mode: rule\n".utf8).write(to: profiles.appendingPathComponent("Beta.yml"))
    try Data("mode: global\n".utf8).write(to: profiles.appendingPathComponent("alpha.yaml"))
    try Data("ignored\n".utf8).write(to: profiles.appendingPathComponent("ignored.txt"))
    try Data("Beta.yml\n".utf8).write(to: root.appendingPathComponent("active-profile"))

    let coordinator = ProfileCoordinator(control: TrayControlClient(), root: root)
    let selected = await coordinator.localState()
    XCTAssertEqual(selected.profiles, ["alpha.yaml", "Beta.yml"])
    XCTAssertEqual(selected.activeProfile, "Beta.yml")

    try Data("missing.yaml\n".utf8).write(to: root.appendingPathComponent("active-profile"))
    let invalidSelection = await coordinator.localState()
    XCTAssertNil(invalidSelection.activeProfile)
  }

  func testProfileSymlinkIsNotARegularCandidate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-profile-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.txt")
    let link = root.appendingPathComponent("linked.yaml")
    try Data("private".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertFalse(ProfileCoordinator.isRegularNonSymlink(link))
    XCTAssertThrowsError(try ProfileCoordinator.boundedBytes(at: link))
  }

  func testMutationBusyStateChangesMenuSignature() {
    let idle = TraySnapshot(mutationOperationInFlight: false)
    var busy = idle
    busy.mutationOperationInFlight = true
    XCTAssertNotEqual(idle.menuSignature, busy.menuSignature)
  }
}
