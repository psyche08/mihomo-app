import Foundation
import MihomoControl

enum ComponentSynchronizerError: Error, LocalizedError {
  case invalidBundle
  case missingVersion
  case missingComponent(String)

  var errorDescription: String? {
    switch self {
    case .invalidBundle: "MihomoBox is not running from an App bundle"
    case .missingVersion: "the App bundle version is unavailable"
    case .missingComponent(let name): "the App bundle is missing \(name)"
    }
  }
}

/// Reconciles exactly the daemon, agent and Mihomo binaries over authenticated
/// XPC. No CLI process or installer is involved after bootstrap.
actor ComponentSynchronizer {
  private let control: TrayControlClient
  private let bundle: Bundle
  private let installedDaemon: URL
  private let mutationGate: AppMutationGate
  private var task: Task<Void, Never>?

  init(
    control: TrayControlClient,
    bundle: Bundle = .main,
    mutationGate: AppMutationGate,
    installedDaemon: URL = URL(
      fileURLWithPath: "/Library/Application Support/Mihomo App/mihomo-daemon"
    )
  ) {
    self.control = control
    self.bundle = bundle
    self.mutationGate = mutationGate
    self.installedDaemon = installedDaemon
  }

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self else { return }
      do {
        let completed = try await self.synchronizeIfNeeded()
        if completed { await self.clearTask() }
      } catch let error as ControlError where error.isLegacyDaemonProtocol {
        // Protocol v1 cannot safely self-upgrade into the transactional v2
        // daemon. The tray exposes an explicit verified Install / Repair path;
        // never retry the old component.update operation with a downgraded
        // request envelope.
        AppLog.info(
          "event=component_sync result=repair_required reason=legacy_protocol peer_version=1")
        await self.clearTask()
      } catch {
        AppLog.error("event=component_sync result=failed")
        await self.clearTask()
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  @discardableResult
  func synchronizeIfNeeded() async throws -> Bool {
    guard
      let result: Void = try await mutationGate.withLock({ [self] in
        try await synchronizeWhileHoldingGate()
      })
    else {
      AppLog.info("event=component_sync result=deferred_busy")
      scheduleDeferredRetry()
      return false
    }
    _ = result
    return true
  }

  private func scheduleDeferredRetry() {
    guard task != nil else { return }
    task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self else { return }
      do {
        let completed = try await self.synchronizeIfNeeded()
        if completed { await self.clearTask() }
      } catch let error as ControlError where error.isLegacyDaemonProtocol {
        AppLog.info(
          "event=component_sync result=repair_required reason=legacy_protocol peer_version=1")
        await self.clearTask()
      } catch {
        AppLog.error("event=component_sync result=failed")
        await self.clearTask()
      }
    }
  }

  private func clearTask() {
    task = nil
  }

  private func synchronizeWhileHoldingGate() async throws {
    guard FileManager.default.isExecutableFile(atPath: installedDaemon.path) else {
      AppLog.info("event=component_sync result=skipped_not_installed")
      return
    }
    let bundleURL = bundle.bundleURL
    guard bundleURL.pathExtension == "app" else { throw ComponentSynchronizerError.invalidBundle }
    guard
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      !version.isEmpty
    else { throw ComponentSynchronizerError.missingVersion }

    let status = try await control.componentStatus()
    let directory = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
    var bytes: [String: Data] = [:]
    var daemonWillRestart = false
    var changed = false
    for component in ManagedComponent.allCases {
      let url = directory.appendingPathComponent(component.rawValue)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isExecutableKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.isExecutable == true, let size = values.fileSize,
        size > 0, size <= Self.maximumSize(for: component)
      else {
        throw ComponentSynchronizerError.missingComponent(component.rawValue)
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      bytes[component.rawValue] = data
      let digest = ComponentUpdatePackage.digest(data)
      if status.components[component.rawValue] != digest {
        changed = true
        if component == .daemon { daemonWillRestart = true }
      }
    }
    guard changed || status.updatePending || status.installedVersion != version else {
      AppLog.info("event=component_sync result=current")
      return
    }
    try await control.upgradeComponents(
      ComponentUpdatePackage(appVersion: version, components: bytes),
      daemonWillRestart: daemonWillRestart
    )
    if daemonWillRestart {
      // The old daemon intentionally drops XPC after atomically replacing
      // itself. Require the new launchd instance to answer before declaring
      // reconciliation complete.
      let expected = Dictionary(
        uniqueKeysWithValues: bytes.map {
          ($0.key, ComponentUpdatePackage.digest($0.value))
        })
      var healthy = false
      for attempt in 0..<30 {
        if let observed = try? await control.componentStatus(),
          !observed.updatePending,
          observed.installedVersion == version,
          observed.components == expected
        {
          healthy = true
          break
        }
        if attempt < 29 { try await Task.sleep(for: .milliseconds(500)) }
      }
      guard healthy else { throw ControlError.connectionFailed }
    }
    AppLog.info("event=component_sync result=success")
  }

  private static func maximumSize(for component: ManagedComponent) -> Int {
    switch component {
    case .daemon, .agent: 64 * 1_024 * 1_024
    case .mihomo: 128 * 1_024 * 1_024
    }
  }
}
