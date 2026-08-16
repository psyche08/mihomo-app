import AppKit
import Foundation
import MihomoControl

enum EnhancedTUNAction: Equatable {
  case requireProfile
  case installDaemon
  case startDaemon
  case enableTUN
  case stopAndRestore
}

enum EnhancedTUNActionPolicy {
  static func resolve(
    enhancedTUN: Bool,
    profileSelected: Bool,
    daemonInstalled: Bool,
    controllerReachable: Bool
  ) -> EnhancedTUNAction {
    if enhancedTUN { return .stopAndRestore }
    if !profileSelected { return .requireProfile }
    if !daemonInstalled { return .installDaemon }
    if !controllerReachable { return .startDaemon }
    return .enableTUN
  }
}

@MainActor
final class AppMutationGate {
  var onBusyChanged: ((Bool) -> Void)?
  private(set) var isBusy = false
  private let coordinator: AppMutationCoordinator

  init(coordinator: AppMutationCoordinator = .shared) {
    self.coordinator = coordinator
  }

  func withLock<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value? {
    guard !isBusy else { return nil }
    isBusy = true
    onBusyChanged?(true)
    defer {
      isBusy = false
      onBusyChanged?(false)
    }
    return try await coordinator.tryWithLock(operation)
  }
}

@MainActor
final class TrayStateCoordinator: TrayService {
  var onSnapshot: (@MainActor (TraySnapshot) -> Void)?
  private(set) var currentSnapshot = TraySnapshot()
  var canCheckForUpdates: Bool { updates.canCheckForUpdates }

  private let control: TrayControlClient
  private let profiles: ProfileCoordinator
  private let installer: InstallerCoordinator
  private let login: LoginAutostartController
  private let updates: SparkleUpdateController
  private let mutationGate: AppMutationGate
  private let fileManager: FileManager
  private var pollTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var latencyTask: Task<Void, Never>?
  private var lastAutomaticLatencyTest: ContinuousClock.Instant?
  private var consecutivePollFailures = 0
  private var started = false
  private var installationAvailable = false
  private var loginDefaultDoneOrInFlight = false
  private var loginDefaultFailures = 0

  init(
    control: TrayControlClient,
    profiles: ProfileCoordinator,
    installer: InstallerCoordinator,
    login: LoginAutostartController,
    updates: SparkleUpdateController,
    mutationGate: AppMutationGate,
    fileManager: FileManager = .default
  ) {
    self.control = control
    self.profiles = profiles
    self.installer = installer
    self.login = login
    self.updates = updates
    self.mutationGate = mutationGate
    self.fileManager = fileManager
    currentSnapshot.installationActionsAvailable = false
    mutationGate.onBusyChanged = { [weak self] busy in
      guard let self else { return }
      var value = self.currentSnapshot
      value.mutationOperationInFlight = busy
      self.publish(value)
    }
    Task { [weak self] in
      guard let self else { return }
      let local = await profiles.localState()
      var initial = self.currentSnapshot
      initial.profiles = local.profiles
      initial.activeProfile = local.activeProfile
      self.publish(initial)
      self.installationAvailable = await installer.installationActionsAvailable
      var value = self.currentSnapshot
      value.installationActionsAvailable = self.installationAvailable
      self.publish(value)
    }
  }

  func start() {
    guard !started else { return }
    started = true
    refresh(authoritative: false)
    pollTask = Task { [weak self] in
      var warmup = 0
      while !Task.isCancelled {
        guard let self else { return }
        let fast = !self.currentSnapshot.controllerReachable && warmup < 20
        try? await Task.sleep(for: fast ? .milliseconds(500) : .seconds(5))
        guard !Task.isCancelled else { return }
        self.refresh(authoritative: false)
        if fast { warmup += 1 }
        if self.currentSnapshot.controllerReachable { warmup = 20 }
      }
    }
  }

  func stop() {
    started = false
    pollTask?.cancel()
    pollTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    latencyTask?.cancel()
    latencyTask = nil
  }

  func refresh(authoritative: Bool) {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      defer { self.refreshTask = nil }
      do {
        let poll = try await self.control.poll()
        self.consecutivePollFailures = 0
        self.apply(poll, retainDelays: !authoritative)
        await self.applyLoginDefaultIfNeeded()
      } catch let error as ControlError {
        if case .protocolVersionMismatch(let expected, let received) = error {
          self.consecutivePollFailures = 0
          let local = await self.profiles.localState()
          self.publish(
            self.protocolMismatchSnapshot(
              expected: expected,
              received: received,
              localProfiles: local
            ))
          return
        }
        self.consecutivePollFailures += 1
        if self.consecutivePollFailures >= 2 {
          let local = await self.profiles.localState()
          self.publish(self.offlineSnapshot(localProfiles: local))
        }
      } catch {
        self.consecutivePollFailures += 1
        if self.consecutivePollFailures >= 2 {
          let local = await self.profiles.localState()
          self.publish(self.offlineSnapshot(localProfiles: local))
        }
      }
    }
  }

  func menuWillOpen() {
    scheduleAutomaticLatencyTestIfNeeded()
  }

  func setEnhancedTUNEnabled(_ enabled: Bool) async throws {
    try await withShellMutation {
      try await self.setEnhancedTUNEnabledLocked(enabled)
    }
  }

  private func setEnhancedTUNEnabledLocked(_ enabled: Bool) async throws {
    guard !currentSnapshot.daemonCompatibility.blocksControlActions else {
      let message = protocolActionError(for: currentSnapshot.daemonCompatibility)
      publishError(message)
      throw NSError(
        domain: "MihomoBoxTray",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
    var busy = currentSnapshot
    busy.tunOperationInFlight = true
    publish(busy)
    defer {
      var complete = currentSnapshot
      complete.tunOperationInFlight = false
      publish(complete)
    }
    do {
      if !enabled {
        guard confirmNetworkRestore() else { return }
        apply(try await control.stopAgentAndRestore(), retainDelays: false)
        clearError()
        return
      }
      if currentSnapshot.enhancedTUN { return }
      let daemonInstalled = Self.daemonInstalled(fileManager: fileManager)
      let resolved = EnhancedTUNActionPolicy.resolve(
        enhancedTUN: currentSnapshot.enhancedTUN,
        profileSelected: currentSnapshot.activeProfile != nil,
        daemonInstalled: daemonInstalled,
        controllerReachable: currentSnapshot.controllerReachable
      )
      guard resolved != .requireProfile else {
        publishError("Add a profile before enabling Enhanced TUN.")
        throw NSError(
          domain: "MihomoBoxTray",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Add a profile before enabling Enhanced TUN."]
        )
      }
      if resolved == .installDaemon {
        let initialProfile =
          Self.managedInstallationPresent(fileManager: fileManager)
          ? nil
          : selectedLocalProfile()
        try await installer.installOrRepair(initialProfile: initialProfile)
        let ready = try await waitForControllerReadiness()
        if ready.enhancedTUN {
          apply(ready, retainDelays: false)
        } else {
          apply(try await control.enableEnhancedTUN(), retainDelays: false)
        }
      } else if resolved == .startDaemon {
        _ = try await control.startAgent()
        let ready = try await waitForControllerReadiness()
        if ready.enhancedTUN {
          apply(ready, retainDelays: false)
        } else {
          apply(try await control.enableEnhancedTUN(), retainDelays: false)
        }
      } else {
        apply(try await control.enableEnhancedTUN(), retainDelays: false)
      }
      await applyLoginDefaultIfNeeded()
      clearError()
    } catch {
      if currentSnapshot.activeProfile != nil || !enabled {
        publishError("Action failed: Enhanced TUN was not changed")
      }
      throw error
    }
  }

  func setOutboundMode(_ mode: TrayOutboundMode) async throws {
    try await withShellMutation {
      try self.requireCompatibleControlAction()
      try await self.action("Action failed: outbound mode was not safely applied") {
        self.apply(try await self.control.setOutboundMode(mode), retainDelays: false)
      }
    }
  }

  func selectProxy(group: String, name: String) async throws {
    try await withShellMutation {
      try self.requireCompatibleControlAction()
      try await self.action("Action failed: proxy selection was not applied") {
        self.apply(
          try await self.control.selectProxy(group: group, name: name),
          retainDelays: false
        )
      }
    }
  }

  func testProxyDelays() async throws {
    try await withShellMutation {
      try self.requireCompatibleControlAction()
      try await self.runLatencyTest(automatic: false)
    }
  }

  func importLocalProfile() async throws {
    try await profileAction {
      try await self.profiles.chooseAndImportLocal(
        daemonInstalled: Self.daemonInstalled(fileManager: self.fileManager)
      )
    }
  }

  func importHTTPProfile() async throws {
    try await profileAction {
      try await self.profiles.promptAndImportSubscription(
        daemonInstalled: Self.daemonInstalled(fileManager: self.fileManager)
      )
    }
  }

  func switchProfile(named name: String) async throws {
    try await profileAction {
      try await self.profiles.switchProfile(
        named: name,
        daemonInstalled: Self.daemonInstalled(fileManager: self.fileManager)
      )
    }
  }

  func reloadProfile() async throws {
    try await profileAction { try await self.profiles.reload() }
  }

  func installOrRepairDaemon(requireLegacy: Bool) async throws {
    try await withShellMutation {
      if requireLegacy, !self.currentSnapshot.daemonCompatibility.requiresRepair {
        self.refresh(authoritative: true)
        return
      }
      guard self.currentSnapshot.daemonCompatibility.allowsExplicitInstaller,
        self.currentSnapshot.installationActionsAvailable
      else {
        let message = self.protocolActionError(
          for: self.currentSnapshot.daemonCompatibility
        )
        self.publishError(message)
        throw NSError(
          domain: "MihomoBoxTray",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: message]
        )
      }
      try await self.action("Action failed: the privileged installer did not complete") {
        let managedInstallationPresent = Self.managedInstallationPresent(
          fileManager: self.fileManager
        )
        let repairingLegacy = self.currentSnapshot.daemonCompatibility.requiresRepair
        if repairingLegacy, !self.confirmDaemonUpgrade() { return }
        // Repair preserves the root-owned active profile. Supplying user bytes
        // again is necessary only for first installation and would otherwise
        // add an unrelated profile mutation to the protocol migration.
        let initialProfile =
          (repairingLegacy || managedInstallationPresent)
          ? nil
          : self.selectedLocalProfile()
        try await self.installer.installOrRepair(initialProfile: initialProfile)
        self.apply(try await self.waitForDaemonProtocolReadiness(), retainDelays: false)
      }
    }
  }

  func openDiagnosticLogs() {
    AppLog.openDiagnostics()
  }

  func checkForUpdates() { updates.checkForUpdates() }

  private func waitForControllerReadiness() async throws -> TrayControlPoll {
    for attempt in 0..<30 {
      if let poll = try? await control.poll(), poll.controllerReachable { return poll }
      if attempt < 29 { try await Task.sleep(for: .milliseconds(500)) }
    }
    throw TrayControlError.readbackMismatch("controller readiness")
  }

  private func waitForDaemonProtocolReadiness() async throws -> TrayControlPoll {
    for attempt in 0..<30 {
      if let poll = try? await control.poll() { return poll }
      if attempt < 29 { try await Task.sleep(for: .milliseconds(500)) }
    }
    throw TrayControlError.readbackMismatch("daemon protocol readiness")
  }

  private func action(
    _ userError: String,
    operation: () async throws -> Void
  ) async throws {
    do {
      try await operation()
      clearError()
    } catch {
      publishError(userError)
      throw error
    }
  }

  private func profileAction(
    _ operation: @escaping @MainActor @Sendable () async throws -> ProfileList
  ) async throws {
    try await withShellMutation {
      try self.requireCompatibleControlAction()
      guard !self.currentSnapshot.profileOperationInFlight else {
        throw ProfileCoordinatorError.busy
      }
      var busy = self.currentSnapshot
      busy.profileOperationInFlight = true
      self.publish(busy)
      do {
        let state = try await operation()
        var complete = self.currentSnapshot
        complete.profiles = state.profiles
        complete.activeProfile = state.activeProfile
        complete.profileOperationInFlight = false
        complete.actionError = nil
        self.publish(complete)
        self.refresh(authoritative: true)
      } catch ProfileCoordinatorError.cancelled {
        var cancelled = self.currentSnapshot
        cancelled.profileOperationInFlight = false
        self.publish(cancelled)
      } catch {
        var failed = self.currentSnapshot
        failed.profileOperationInFlight = false
        let cocoa = error as NSError
        if cocoa.domain == "MihomoBoxProfileValidation",
          cocoa.localizedDescription.hasPrefix("Action failed: profile rejected by Mihomo")
        {
          failed.actionError = String(cocoa.localizedDescription.prefix(240))
        } else if let known = error as? ProfileCoordinatorError,
          known == .validatorUnavailable
        {
          failed.actionError = "Action failed: the bundled Mihomo validator is unavailable"
        } else {
          failed.actionError = "Action failed: profile operation did not complete"
        }
        self.publish(failed)
        throw error
      }
    }
  }

  private func apply(_ poll: TrayControlPoll, retainDelays: Bool) {
    let proxies =
      retainDelays
      ? Self.retainingKnownDelays(in: poll.proxies, from: currentSnapshot.proxies)
      : poll.proxies
    publish(
      TraySnapshot(
        daemonCompatibility: .compatible,
        controllerReachable: poll.controllerReachable,
        daemonReachable: true,
        agentRunning: poll.agentRunning,
        enhancedTUN: poll.enhancedTUN,
        tunOperationInFlight: currentSnapshot.tunOperationInFlight,
        mutationOperationInFlight: currentSnapshot.mutationOperationInFlight,
        networkHealthy: poll.networkHealthy,
        systemDNSManaged: poll.systemDNSManaged,
        healthTUNEnabled: poll.healthTUNEnabled,
        outboundMode: poll.outboundMode,
        proxies: proxies,
        profiles: poll.profiles,
        activeProfile: poll.activeProfile,
        profileOperationInFlight: currentSnapshot.profileOperationInFlight,
        profileActionsAvailable: true,
        installationActionsAvailable: installationAvailable,
        enhancedTUNActionAvailable: tunActionAvailable(
          enhancedTUN: poll.enhancedTUN,
          activeProfile: poll.activeProfile
        ),
        actionError: currentSnapshot.actionError
      ))
  }

  /// Passive controller polls do not contain a fresh delay for every node.
  /// The controller catalog is deduplicated by its case-sensitive node name,
  /// while the display group may change when another selector becomes active.
  /// Preserve the last-good measurement by that stable node identity instead
  /// of `TrayProxyID`, whose group is only presentation context.
  nonisolated static func retainingKnownDelays(
    in incoming: [TrayProxyNode],
    from previous: [TrayProxyNode]
  ) -> [TrayProxyNode] {
    let known = Dictionary(
      uniqueKeysWithValues: previous.compactMap { node in
        node.delayMilliseconds.map { (node.name, $0) }
      })
    return incoming.map { node in
      guard node.delayMilliseconds == nil, let delay = known[node.name] else { return node }
      var retained = node
      retained.delayMilliseconds = delay
      return retained
    }
  }

  private func offlineSnapshot(localProfiles: ProfileList) -> TraySnapshot {
    var value = currentSnapshot
    value.controllerReachable = false
    value.daemonReachable = false
    value.networkHealthy = nil
    value.profiles = localProfiles.profiles
    value.activeProfile = localProfiles.activeProfile
    value.enhancedTUNActionAvailable = tunActionAvailable(
      enhancedTUN: value.enhancedTUN,
      activeProfile: value.activeProfile
    )
    return value
  }

  private func protocolMismatchSnapshot(
    expected: Int,
    received: Int,
    localProfiles: ProfileList
  ) -> TraySnapshot {
    let compatibility = Self.protocolCompatibility(
      expected: expected,
      received: received
    )
    return TraySnapshot(
      daemonCompatibility: compatibility,
      controllerReachable: false,
      daemonReachable: true,
      agentRunning: false,
      enhancedTUN: false,
      tunOperationInFlight: currentSnapshot.tunOperationInFlight,
      mutationOperationInFlight: currentSnapshot.mutationOperationInFlight,
      networkHealthy: nil,
      systemDNSManaged: nil,
      healthTUNEnabled: nil,
      outboundMode: .rule,
      proxies: [],
      profiles: localProfiles.profiles,
      activeProfile: localProfiles.activeProfile,
      profileOperationInFlight: currentSnapshot.profileOperationInFlight,
      profileActionsAvailable: false,
      installationActionsAvailable: installationAvailable,
      enhancedTUNActionAvailable: false,
      actionError: currentSnapshot.actionError
    )
  }

  nonisolated static func protocolCompatibility(
    expected: Int,
    received: Int
  ) -> DaemonProtocolCompatibility {
    if expected == mihomoControlProtocolVersion, received == 1 {
      return .legacyRepairRequired(peerVersion: received)
    }
    if received > expected {
      return .appUpdateRequired(peerVersion: received)
    }
    return .incompatible(peerVersion: received)
  }

  private func protocolActionError(
    for compatibility: DaemonProtocolCompatibility
  ) -> String {
    switch compatibility {
    case .legacyRepairRequired:
      return "Action unavailable: upgrade the MihomoBox daemon first"
    case .appUpdateRequired:
      return "Action unavailable: update MihomoBox to match the installed daemon"
    case .incompatible:
      return "Action unavailable: the daemon protocol is incompatible"
    case .unknown, .compatible:
      return "Action unavailable: daemon compatibility is unknown"
    }
  }

  private func requireCompatibleControlAction() throws {
    guard !currentSnapshot.daemonCompatibility.blocksControlActions else {
      let message = protocolActionError(for: currentSnapshot.daemonCompatibility)
      publishError(message)
      throw NSError(
        domain: "MihomoBoxTray",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private func publish(_ snapshot: TraySnapshot) {
    currentSnapshot = snapshot
    onSnapshot?(snapshot)
  }

  private func clearError() {
    var value = currentSnapshot
    value.actionError = nil
    publish(value)
  }

  private func publishError(_ message: String) {
    var value = currentSnapshot
    value.actionError = message
    publish(value)
  }

  private func scheduleAutomaticLatencyTestIfNeeded() {
    guard !mutationGate.isBusy else { return }
    let now = ContinuousClock.now
    if let lastAutomaticLatencyTest,
      lastAutomaticLatencyTest.duration(to: now) < .seconds(20)
    {
      return
    }
    lastAutomaticLatencyTest = now
    guard latencyTask == nil else { return }
    latencyTask = Task { [weak self] in
      defer { self?.latencyTask = nil }
      try? await self?.runLatencyTest(automatic: true)
    }
  }

  private func runLatencyTest(automatic: Bool) async throws {
    try Task.checkCancellation()
    if currentSnapshot.daemonCompatibility.blocksControlActions {
      if automatic { return }
      try requireCompatibleControlAction()
    }
    let names = currentSnapshot.proxies.map(\.name)
    guard !names.isEmpty else { return }
    let succeeded: Int
    do { succeeded = try await control.testDelays(names: names) } catch {
      if !automatic { publishError("Action failed: latency test could not reach any node") }
      throw error
    }
    if !automatic, succeeded == 0 {
      publishError("Action failed: latency test could not reach any node")
    }
    if let poll = try? await control.poll() {
      apply(poll, retainDelays: automatic)
    }
    if !automatic, succeeded > 0 { clearError() }
  }

  private func applyLoginDefaultIfNeeded() async {
    guard !loginDefaultDoneOrInFlight,
      currentSnapshot.enhancedTUN, currentSnapshot.networkHealthy == true
    else { return }
    loginDefaultDoneOrInFlight = true
    do {
      let outcome = try await login.applyIfHealthy(
        enhancedTUN: currentSnapshot.enhancedTUN,
        networkHealthy: currentSnapshot.networkHealthy
      )
      AppLog.info("event=login_autostart_default result=\(outcome.rawValue)")
      loginDefaultDoneOrInFlight = true
    } catch {
      loginDefaultFailures += 1
      AppLog.error("event=login_autostart_default result=failed")
      loginDefaultDoneOrInFlight = loginDefaultFailures >= 3
    }
  }

  private func confirmNetworkRestore() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Stop Mihomo and restore real system DNS?"
    alert.informativeText = "Profiles and installation files will be preserved."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Restore Network")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmDaemonUpgrade() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Upgrade the MihomoBox daemon?"
    alert.informativeText =
      "The signed installer will briefly restart Mihomo, Enhanced TUN, and managed DNS."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Upgrade Daemon")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func selectedLocalProfile() -> URL? {
    guard let active = currentSnapshot.activeProfile else { return nil }
    let url = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/MihomoBox/profiles")
      .appendingPathComponent(active)
    return fileManager.isReadableFile(atPath: url.path) ? url : nil
  }

  private static func daemonInstalled(fileManager: FileManager) -> Bool {
    fileManager.isExecutableFile(
      atPath: "/Library/Application Support/Mihomo App/mihomo-daemon"
    )
      && fileManager.fileExists(
        atPath: "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist"
      )
  }

  private static func managedInstallationPresent(fileManager: FileManager) -> Bool {
    let paths = [
      "/Library/Application Support/Mihomo App",
      "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist",
      "/Library/LaunchDaemons/dev.linsheng.mihomo-app.daemon.plist",
    ]
    return hasManagedInstallationArtifact(at: paths, fileManager: fileManager)
  }

  nonisolated static func hasManagedInstallationArtifact(
    at paths: [String],
    fileManager: FileManager
  ) -> Bool {
    return paths.contains { path in
      fileManager.fileExists(atPath: path)
        || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }
  }

  private func tunActionAvailable(enhancedTUN: Bool, activeProfile: String?) -> Bool {
    if enhancedTUN || activeProfile == nil { return true }
    return Self.daemonInstalled(fileManager: fileManager) || installationAvailable
  }

  private func withShellMutation<Value: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    latencyTask?.cancel()
    latencyTask = nil
    guard let value = try await mutationGate.withLock(operation) else {
      throw ProfileCoordinatorError.busy
    }
    return value
  }
}

@MainActor
private final class LiveAppShellCoordinator: AppShellCoordinating {
  let trayService: any TrayService
  private let components: ComponentSynchronizer
  private let updates: SparkleUpdateController

  init(
    trayService: any TrayService,
    components: ComponentSynchronizer,
    updates: SparkleUpdateController
  ) {
    self.trayService = trayService
    self.components = components
    self.updates = updates
  }

  func startBackgroundServices() {
    Task { await components.start() }
    updates.start()
  }

  func stopBackgroundServices() {
    Task { await components.stop() }
    updates.stop()
  }
}

@MainActor
enum AppComposition {
  static func live() -> any AppShellCoordinating {
    let control = TrayControlClient()
    let updates = SparkleUpdateController()
    let mutationGate = AppMutationGate()
    let tray = TrayStateCoordinator(
      control: control,
      profiles: ProfileCoordinator(control: control),
      installer: InstallerCoordinator(),
      login: LoginAutostartController(),
      updates: updates,
      mutationGate: mutationGate
    )
    return LiveAppShellCoordinator(
      trayService: tray,
      components: ComponentSynchronizer(control: control, mutationGate: mutationGate),
      updates: updates
    )
  }
}
