import AppKit
import MihomoBoxUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, ApplicationStatusItemControlling {
  private let service: any TrayService
  private let mainWindow: any NativeWindowControlling
  private let onExit: () -> Void
  private let statusBar: NSStatusBar
  private let statusItem: NSStatusItem

  private var renderedSnapshot: TraySnapshot?
  private var latestSnapshot: TraySnapshot
  private var pendingSnapshot: TraySnapshot?
  private var isTrackingMenu = false
  private var proxyItems: [TrayProxyID: NSMenuItem] = [:]
  private weak var checkForUpdatesItem: NSMenuItem?
  private var started = false

  init(
    service: any TrayService,
    mainWindow: any NativeWindowControlling,
    statusBar: NSStatusBar = .system,
    onExit: @escaping () -> Void
  ) {
    self.service = service
    self.mainWindow = mainWindow
    self.onExit = onExit
    self.statusBar = statusBar
    statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    latestSnapshot = service.currentSnapshot
    super.init()
    configureStatusItemButton()
  }

  func start() {
    guard !started else { return }
    started = true

    service.onSnapshot = { [weak self] snapshot in
      self?.receive(snapshot)
    }
    receive(service.currentSnapshot)
    service.start()
  }

  func stop() {
    guard started else { return }
    started = false

    service.onSnapshot = nil
    service.stop()
    statusItem.menu = nil
    statusBar.removeStatusItem(statusItem)
  }

  func menuWillOpen(_ menu: NSMenu) {
    isTrackingMenu = true
    refreshUpdateAvailability()
    service.menuWillOpen()
    service.refresh(authoritative: false)
  }

  func menuDidClose(_ menu: NSMenu) {
    isTrackingMenu = false
    guard let pendingSnapshot else { return }
    self.pendingSnapshot = nil
    render(pendingSnapshot, forceRebuild: true)
  }

  private func configureStatusItemButton() {
    guard let button = statusItem.button else { return }
    let image = NSImage(
      systemSymbolName: "network",
      accessibilityDescription: "MihomoBox"
    )
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageOnly
  }

  private func receive(_ snapshot: TraySnapshot) {
    latestSnapshot = snapshot
    statusItem.button?.toolTip = snapshot.tooltip
    refreshUpdateAvailability()

    switch TrayMenuUpdatePolicy.decision(
      rendered: renderedSnapshot,
      incoming: snapshot,
      isTracking: isTrackingMenu
    ) {
    case .rebuildNow:
      render(snapshot, forceRebuild: true)
    case .repaintDelaysOnly:
      repaintProxyDelays(using: snapshot)
      renderedSnapshot = snapshot
      // A later poll may have converged back to the state already drawn. Do
      // not apply an older deferred rebuild after the menu closes.
      pendingSnapshot = nil
    case .repaintDelaysAndDeferRebuild:
      // Latency labels are safe to update while AppKit tracks a submenu. Any
      // structural/check-state change is retained and rebuilt once the root
      // menu closes, so polling never collapses the user's current submenu.
      repaintProxyDelays(using: snapshot)
      pendingSnapshot = snapshot
    }
  }

  private func render(_ snapshot: TraySnapshot, forceRebuild: Bool) {
    guard forceRebuild || renderedSnapshot?.menuSignature != snapshot.menuSignature else {
      repaintProxyDelays(using: snapshot)
      renderedSnapshot = snapshot
      return
    }

    let menu = buildMenu(for: snapshot)
    menu.delegate = self
    statusItem.menu = menu
    renderedSnapshot = snapshot
    latestSnapshot = snapshot
  }

  private func repaintProxyDelays(using snapshot: TraySnapshot) {
    var nodes: [TrayProxyID: TrayProxyNode] = [:]
    for node in snapshot.proxies {
      nodes[node.id] = node
    }
    for (identifier, item) in proxyItems {
      guard let node = nodes[identifier] else { continue }
      item.title = node.menuTitle
    }
  }

  private func buildMenu(for snapshot: TraySnapshot) -> NSMenu {
    proxyItems.removeAll(keepingCapacity: true)
    checkForUpdatesItem = nil

    let menu = NSMenu(title: "MihomoBox")
    menu.autoenablesItems = false
    menu.addItem(item("Show Main Window", action: #selector(showMainWindow)))
    menu.addItem(.separator())

    let networkStatus = NSMenuItem(
      title: snapshot.networkStatusTitle, action: nil, keyEquivalent: "")
    networkStatus.isEnabled = false
    menu.addItem(networkStatus)

    let tun = item("Enhanced TUN", action: #selector(toggleEnhancedTUN(_:)))
    tun.state = snapshot.enhancedTUN ? .on : .off
    tun.isEnabled = TrayMenuActionPolicy.enhancedTUNEnabled(snapshot)
    menu.addItem(tun)
    menu.addItem(.separator())

    menu.addItem(outboundModeMenu(for: snapshot))
    menu.addItem(proxyMenu(for: snapshot))
    menu.addItem(profilesMenu(for: snapshot))

    let reload = item("Reload Profiles", action: #selector(reloadProfile))
    reload.isEnabled = TrayMenuActionPolicy.profileReloadEnabled(snapshot)
    menu.addItem(reload)
    menu.addItem(.separator())

    let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
    let toolsMenu = NSMenu(title: "Tools")
    toolsMenu.autoenablesItems = false
    let install = item("Install / Repair Daemon…", action: #selector(installOrRepairDaemon))
    install.isEnabled = TrayMenuActionPolicy.installerEnabled(snapshot)
    toolsMenu.addItem(install)
    toolsMenu.addItem(item("Open Diagnostic Logs…", action: #selector(openDiagnosticLogs)))
    let checkForUpdates = item("Check for Updates…", action: #selector(checkForUpdates))
    checkForUpdates.isEnabled = TrayUpdateAvailabilityPolicy.isEnabled(
      canCheckForUpdates: service.canCheckForUpdates
    )
    checkForUpdatesItem = checkForUpdates
    toolsMenu.addItem(checkForUpdates)
    tools.submenu = toolsMenu
    menu.addItem(tools)

    menu.addItem(.separator())
    menu.addItem(item("Exit", action: #selector(exitApplication)))
    return menu
  }

  private func outboundModeMenu(for snapshot: TraySnapshot) -> NSMenuItem {
    let parent = NSMenuItem(title: "Outbound Mode", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Outbound Mode")
    submenu.autoenablesItems = false

    for mode in TrayOutboundMode.allCases {
      let row = item(mode.title, action: #selector(selectOutboundMode(_:)))
      row.representedObject = mode.rawValue
      row.state = snapshot.outboundMode == mode ? .on : .off
      row.isEnabled = snapshot.controllerReachable && !snapshot.mutationOperationInFlight
      submenu.addItem(row)
    }
    parent.submenu = submenu
    return parent
  }

  private func proxyMenu(for snapshot: TraySnapshot) -> NSMenuItem {
    let parent = NSMenuItem(title: "Proxy List", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Proxy List")
    submenu.autoenablesItems = false

    let testNow = item("Test Now", action: #selector(testProxyDelays))
    testNow.isEnabled = snapshot.controllerReachable && !snapshot.mutationOperationInFlight
    submenu.addItem(testNow)
    submenu.addItem(.separator())

    if snapshot.proxies.isEmpty {
      let empty = NSMenuItem(
        title: snapshot.controllerReachable ? "No proxy nodes" : "Mihomo daemon unavailable",
        action: nil,
        keyEquivalent: ""
      )
      empty.isEnabled = false
      submenu.addItem(empty)
    } else {
      for node in snapshot.proxies {
        let row = item(node.menuTitle, action: #selector(selectProxy(_:)))
        row.representedObject = ProxyAction(group: node.group, name: node.name)
        row.state = node.isSelected ? .on : .off
        row.isEnabled = snapshot.controllerReachable && !snapshot.mutationOperationInFlight
        submenu.addItem(row)
        proxyItems[node.id] = row
      }
    }

    parent.submenu = submenu
    return parent
  }

  private func profilesMenu(for snapshot: TraySnapshot) -> NSMenuItem {
    let parent = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Profiles")
    submenu.autoenablesItems = false

    let importLocal = item("Import Local YAML…", action: #selector(importLocalProfile))
    importLocal.isEnabled = TrayMenuActionPolicy.profileActionEnabled(snapshot)
    submenu.addItem(importLocal)

    let importHTTP = item(
      "Import HTTP Subscription…",
      action: #selector(importHTTPProfile)
    )
    importHTTP.isEnabled = TrayMenuActionPolicy.profileActionEnabled(snapshot)
    submenu.addItem(importHTTP)
    submenu.addItem(.separator())

    if snapshot.profiles.isEmpty {
      let empty = NSMenuItem(title: "No imported profiles", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      submenu.addItem(empty)
    } else {
      for profile in snapshot.profiles {
        let row = item(profile, action: #selector(selectProfile(_:)))
        row.representedObject = profile
        row.state = snapshot.activeProfile == profile ? .on : .off
        row.isEnabled = TrayMenuActionPolicy.profileActionEnabled(snapshot)
        submenu.addItem(row)
      }
    }

    parent.submenu = submenu
    return parent
  }

  private func item(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    return item
  }

  private func refreshUpdateAvailability() {
    checkForUpdatesItem?.isEnabled = TrayUpdateAvailabilityPolicy.isEnabled(
      canCheckForUpdates: service.canCheckForUpdates
    )
  }

  @objc private func showMainWindow() {
    _ = mainWindow.show()
  }

  @objc private func toggleEnhancedTUN(_ sender: NSMenuItem) {
    let displayedValue = renderedSnapshot?.enhancedTUN ?? latestSnapshot.enhancedTUN
    // AppKit can optimistically toggle a check item. Restore the daemon-owned
    // value immediately; only authenticated readback may change the mark.
    sender.state = displayedValue ? .on : .off
    switch TrayEnhancedTUNClickPolicy.decision(
      displayedEnhancedTUN: displayedValue,
      latestEnhancedTUN: latestSnapshot.enhancedTUN
    ) {
    case .refreshAuthoritatively:
      // The menu is showing a structural state that arrived just before or
      // during tracking. Do not reinterpret a stale visible check mark as the
      // opposite lifecycle request; closing the menu applies the deferred
      // snapshot and the user can then make an informed choice.
      service.refresh(authoritative: true)
      return
    case .request(let requested):
      perform { service in
        try await service.setEnhancedTUNEnabled(requested)
      }
    }
  }

  @objc private func selectOutboundMode(_ sender: NSMenuItem) {
    guard
      let rawValue = sender.representedObject as? String,
      let mode = TrayOutboundMode(rawValue: rawValue)
    else { return }
    perform { service in try await service.setOutboundMode(mode) }
  }

  @objc private func testProxyDelays() {
    perform { service in try await service.testProxyDelays() }
  }

  @objc private func selectProxy(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? ProxyAction else { return }
    perform { service in
      try await service.selectProxy(group: action.group, name: action.name)
    }
  }

  @objc private func importLocalProfile() {
    perform { service in try await service.importLocalProfile() }
  }

  @objc private func importHTTPProfile() {
    perform { service in try await service.importHTTPProfile() }
  }

  @objc private func selectProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    perform { service in try await service.switchProfile(named: name) }
  }

  @objc private func reloadProfile() {
    perform { service in try await service.reloadProfile() }
  }

  @objc private func installOrRepairDaemon() {
    perform { service in try await service.installOrRepairDaemon() }
  }

  @objc private func openDiagnosticLogs() {
    service.openDiagnosticLogs()
  }

  @objc private func checkForUpdates() {
    service.checkForUpdates()
  }

  @objc private func exitApplication() {
    onExit()
  }

  private func perform(
    _ operation: @escaping @MainActor (any TrayService) async throws -> Void
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await operation(service)
      } catch {
        // The service retains a sanitized action error in its snapshot. An
        // authoritative refresh supplies both that error and real readback;
        // the tray never applies an optimistic state locally.
      }
      service.refresh(authoritative: true)
    }
  }
}

private final class ProxyAction: NSObject {
  let group: String
  let name: String

  init(group: String, name: String) {
    self.group = group
    self.name = name
  }
}
