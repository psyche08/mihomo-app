import AppKit
import Foundation
import XCTest

@testable import MihomoBoxApp

final class AppServicePolicyTests: XCTestCase {
  @MainActor
  func testStatusItemIconUsesThePinnedMetaArtworkAndTemplateSizing() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let meta = repository.appendingPathComponent("assets/Meta.png")
    var fallbackCalled = false

    let artwork = try XCTUnwrap(
      StatusItemIconLoader.load(primaryURL: meta) {
        fallbackCalled = true
        return nil
      }
    )

    XCTAssertEqual(StatusItemIconLoader.resourceName, "Meta")
    XCTAssertEqual(StatusItemIconLoader.resourceExtension, "png")
    XCTAssertFalse(fallbackCalled)
    XCTAssertFalse(artwork.usedFallback)
    XCTAssertEqual(artwork.image.size, NSSize(width: 18, height: 18))
    XCTAssertTrue(artwork.image.isTemplate)
    XCTAssertEqual(artwork.image.accessibilityDescription, "MihomoBox")

    let fallback = NSImage(size: NSSize(width: 1, height: 1))
    let fallbackArtwork = try XCTUnwrap(
      StatusItemIconLoader.load(primaryURL: nil) { fallback }
    )
    XCTAssertTrue(fallbackArtwork.usedFallback)
    XCTAssertTrue(fallbackArtwork.image === fallback)
    XCTAssertEqual(fallbackArtwork.image.size, NSSize(width: 18, height: 18))
    XCTAssertTrue(fallbackArtwork.image.isTemplate)
  }

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

  func testProtocolMismatchClassificationOnlyRepairsExactLegacyV1() {
    XCTAssertEqual(
      TrayStateCoordinator.protocolCompatibility(expected: 2, received: 1),
      .legacyRepairRequired(peerVersion: 1)
    )
    XCTAssertEqual(
      TrayStateCoordinator.protocolCompatibility(expected: 2, received: 3),
      .appUpdateRequired(peerVersion: 3)
    )
    XCTAssertEqual(
      TrayStateCoordinator.protocolCompatibility(expected: 3, received: 1),
      .incompatible(peerVersion: 1)
    )
  }

  func testAnyManagedInstallationArtifactPreservesTheRootProfile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mihomobox-install-artifacts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let absent = root.appendingPathComponent("absent").path
    XCTAssertFalse(
      TrayStateCoordinator.hasManagedInstallationArtifact(
        at: [absent],
        fileManager: .default
      )
    )

    let appSupport = root.appendingPathComponent("Mihomo App", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    XCTAssertTrue(
      TrayStateCoordinator.hasManagedInstallationArtifact(
        at: [appSupport.path],
        fileManager: .default
      )
    )

    let dangling = root.appendingPathComponent("renamed-daemon.plist")
    try FileManager.default.createSymbolicLink(
      at: dangling,
      withDestinationURL: root.appendingPathComponent("missing-target")
    )
    XCTAssertTrue(
      TrayStateCoordinator.hasManagedInstallationArtifact(
        at: [dangling.path],
        fileManager: .default
      )
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

  func testProvisioningRequiresPersistentAndDynamicDNSRestorationReadback() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let proxyService = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoDNSCore/ProxyService.swift"),
      encoding: .utf8
    )
    let agent = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoAgent/main.swift"),
      encoding: .utf8
    )
    let supervisor = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoDaemon/AgentSupervisor.swift"),
      encoding: .utf8
    )
    let installer = try String(
      contentsOf: repository.appendingPathComponent("scripts/install-daemon.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(proxyService.contains("isSystemDNSRestored"))
    XCTAssertTrue(
      proxyService.contains(
        "let persistentlyPresent = try preferences.containsManagedServerPersistently()"
      )
    )
    XCTAssertTrue(
      proxyService.contains(
        "let dynamicallyPresent = try preferences.containsManagedServerEffectively()"
      )
    )
    XCTAssertTrue(proxyService.contains("return !persistentlyPresent && !dynamicallyPresent"))
    XCTAssertTrue(
      supervisor.contains("ProxyService.isSystemDNSRestored(configuration: configuration)")
    )
    XCTAssertTrue(supervisor.contains("observed.tunInterface == nil"))
    XCTAssertTrue(supervisor.contains("!observed.fakeIPRouteReady"))
    XCTAssertTrue(supervisor.contains("!observed.dnsBridgeReady"))
    XCTAssertTrue(supervisor.contains("!observed.mihomoDNSReady"))
    XCTAssertTrue(agent.contains("--check-system-dns-restored"))
    XCTAssertTrue(installer.contains("--check-system-dns-restored >/dev/null 2>&1"))
    XCTAssertTrue(installer.contains("managed_mihomo_pids"))
  }

  func testInstallerAndDaemonMutationsShareTheRootTransactionLock() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let updater = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoDaemon/ComponentUpdater.swift"),
      encoding: .utf8
    )
    let server = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoDaemon/ControlServer.swift"),
      encoding: .utf8
    )

    let lockPath = "/Library/Application Support/.mihomobox-install.lock"
    XCTAssertTrue(updater.contains(lockPath))
    XCTAssertTrue(updater.contains("O_EXLOCK | O_NONBLOCK"))
    XCTAssertTrue(
      updater.contains(
        "O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK"
      )
    )
    XCTAssertTrue(updater.contains("let fileLock = try mutationLockForTransaction()"))
    XCTAssertTrue(updater.contains("pendingBootValidationLock = fileLock"))
    XCTAssertTrue(updater.contains("var previousVersion: String?"))
    XCTAssertTrue(updater.contains("0.8.0 did not encode previousVersion"))
    XCTAssertTrue(updater.contains("pending.previousVersion = previousVersion"))
    XCTAssertTrue(updater.contains("new pending component update is missing its previous version"))
    XCTAssertTrue(updater.contains("try writeInstalledVersion(rollbackVersion)"))
    XCTAssertTrue(updater.contains("installed component version state is missing or invalid"))
    XCTAssertTrue(updater.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
    XCTAssertTrue(updater.contains("metadata.st_mode & 0o7777 == 0o600"))
    XCTAssertTrue(updater.contains("private func semanticVersion(_ value: String) -> [String]?"))
    XCTAssertTrue(updater.contains("semanticVersionPrecedes"))
    XCTAssertFalse(updater.contains("let number = Int(field)"))
    XCTAssertTrue(server.contains("request.operation != .upgradeComponents"))
    XCTAssertTrue(server.contains("components.ownsPendingMutationFileLock"))
    XCTAssertTrue(server.contains("externalMutationFileLock = try ComponentMutationFileLock()"))
    XCTAssertTrue(server.contains("another privileged MihomoBox mutation is running"))
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
    XCTAssertTrue(installer.contains("enforce_component_version_floor"))
    XCTAssertTrue(installer.contains("semantic_version_precedes"))
    XCTAssertTrue(installer.contains("refusing to downgrade installed components"))
    XCTAssertTrue(installer.contains("__installer-probe-daemon-protocol"))
    XCTAssertTrue(installer.contains("probe_status\" -eq 10"))
    XCTAssertTrue(installer.contains("installed component version state is unsafe"))
    XCTAssertTrue(installer.contains("read_exact_semantic_version_file"))
    XCTAssertTrue(installer.contains("$(( ${#value} + 1 ))"))
    XCTAssertTrue(installer.contains("UNVERSIONED_INSTALLATION_AUTHORIZED"))
    XCTAssertTrue(installer.contains("for artifact in \\\n    \"$APP_SUPPORT\""))
    XCTAssertTrue(installer.contains("\"$RENAMED_PLIST\"; do"))
    XCTAssertTrue(
      installer.contains("INSTALL_LOCK=\"/Library/Application Support/.mihomobox-install.lock\""))
    XCTAssertTrue(installer.contains("acquire_install_lock"))
    XCTAssertTrue(installer.contains("/usr/bin/lockf -s -t 0 9"))
    XCTAssertTrue(installer.contains("exec 9<>\"$INSTALL_LOCK\""))
    XCTAssertTrue(
      installer.contains("COMPONENT_PENDING=\"$APP_SUPPORT/component-update-pending.plist\""))
    XCTAssertTrue(
      installer.contains("component update recovery must finish before installer repair"))
    XCTAssertTrue(installer.contains("/bin/chmod 0600 \"$staged\""))
    XCTAssertTrue(installer.contains("/bin/mv -f \"$staged\" \"$COMPONENT_VERSION\""))
    XCTAssertTrue(installer.contains("PROVISIONING_STATE=\"$APP_SUPPORT/provisioning\""))
    XCTAssertTrue(installer.contains("authenticated daemon XPC"))
    XCTAssertTrue(installer.contains("verified stopped network after provisioning"))
    XCTAssertTrue(installer.contains("managed_network_restored"))
    XCTAssertTrue(installer.contains("managed_mihomo_pids"))
    XCTAssertTrue(installer.contains("--check-system-dns-restored"))
    XCTAssertTrue(installer.contains("'\"fake_ip_route_ready\":false'"))
    XCTAssertTrue(installer.contains("'\"dns_bridge_ready\":false'"))
    XCTAssertTrue(installer.contains("'\"mihomo_dns_ready\":false'"))
    XCTAssertTrue(
      installer.contains(
        "LEGACY_PLIST=\"/Library/LaunchDaemons/homebrew.mxcl.mihomo.plist\""
      ))
    XCTAssertTrue(installer.contains("LEGACY_PLIST_BACKUP"))
    XCTAssertTrue(installer.contains("snapshot_previous_launchd_definitions"))
    XCTAssertTrue(installer.contains("if [[ -e \"$PLIST\" || -L \"$PLIST\" ]]"))
    XCTAssertTrue(
      installer.contains("if [[ -e \"$RENAMED_PLIST\" || -L \"$RENAMED_PLIST\" ]]")
    )
    XCTAssertTrue(installer.contains("restart_launchd_job"))
    XCTAssertTrue(installer.contains("wait_for_job_present"))
    XCTAssertTrue(installer.contains("state = running"))
    XCTAssertTrue(installer.contains("PREVIOUS_MANAGED_RUNTIME_RUNNING"))
    XCTAssertTrue(installer.contains("restored managed MihomoBox network"))
    XCTAssertTrue(installer.contains("recovery_required: rollback snapshot preserved at"))
    XCTAssertTrue(installer.contains("restore_saved_legacy_installation"))
    XCTAssertFalse(
      installer.contains(
        "/bin/launchctl kickstart -k \"system/$LEGACY_LABEL\" >/dev/null 2>&1 || true"
      ))
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
    let installBody = try XCTUnwrap(
      installer.range(of: "install_daemon() {", options: .backwards)
    )
    let stopped = try XCTUnwrap(
      installer.range(
        of: "wait_for_managed_process_absent",
        range: installBody.lowerBound..<installer.endIndex
      )
    )
    let stableSnapshot = try XCTUnwrap(
      installer.range(
        of: "snapshot_installation",
        range: stopped.upperBound..<installer.endIndex
      )
    )
    let firstReplacement = try XCTUnwrap(
      installer.range(
        of: "run /usr/bin/install -o root -g wheel -m 0755 \"$DAEMON_SOURCE\"",
        range: stableSnapshot.upperBound..<installer.endIndex
      )
    )
    XCTAssertLessThan(stopped.lowerBound, stableSnapshot.lowerBound)
    XCTAssertLessThan(stableSnapshot.lowerBound, firstReplacement.lowerBound)
    let launchdSnapshot = try XCTUnwrap(
      installer.range(
        of: "snapshot_previous_launchd_definitions",
        range: installBody.lowerBound..<stopped.lowerBound
      )
    )
    let legacyBootout = try XCTUnwrap(
      installer.range(
        of: "/bin/launchctl bootout \"system/$LEGACY_LABEL\"",
        range: launchdSnapshot.upperBound..<stopped.lowerBound
      )
    )
    XCTAssertLessThan(launchdSnapshot.lowerBound, legacyBootout.lowerBound)
    let dispatcher = try XCTUnwrap(
      installer.range(of: "if [[ -n \"$IMPORT_PROFILE\" ]]", options: .backwards)
    )
    let globalLock = try XCTUnwrap(
      installer.range(
        of: "acquire_install_lock",
        options: .backwards,
        range: installBody.lowerBound..<dispatcher.lowerBound
      )
    )
    XCTAssertLessThan(globalLock.lowerBound, dispatcher.lowerBound)
    XCTAssertFalse(
      installer[installBody.lowerBound..<globalLock.lowerBound]
        .contains("acquire_install_lock")
    )
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

    let cli = try String(
      contentsOf: repository.appendingPathComponent("Sources/MihomoBoxCLI/main.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(cli.contains("case \"__installer-probe-daemon-protocol\""))
    XCTAssertTrue(cli.contains("protocolVersionMismatch(let expected, let received)"))
    XCTAssertTrue(cli.contains("InstallerProtocolProbeExit.legacy.rawValue"))
    XCTAssertFalse(cli.contains("ControlRequest(version: 1"))
    XCTAssertFalse(installer.contains("--client-app-bundle"))
    XCTAssertFalse(installer.contains("--initial-profile"))
    XCTAssertTrue(installer.contains("CLI_TARGET_METADATA=\"$APP_SUPPORT/cli-target\""))
    XCTAssertTrue(installer.contains("existing_target\" != \"$recorded_target"))

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
