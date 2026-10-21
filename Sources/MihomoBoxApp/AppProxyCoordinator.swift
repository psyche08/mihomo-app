import AppKit
import NetworkExtension
import SystemExtensions
import Security
import MihomoBoxUI
import MihomoControl

/// User-scoped NetworkExtension preferences. Privileged core/profile changes
/// remain typed XPC actions handled by the root daemon.
@MainActor
final class AppProxyCoordinator: NSObject, DashboardAppProxyService, @preconcurrency OSSystemExtensionRequestDelegate {
    private let extensionID = "dev.linsheng.mihomo-app.app-proxy"
    private var activation: CheckedContinuation<Void, Error>?
    private var busy = false
    private var counts: [String: Int] = [:]
    private var available: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", FileManager.default.fileExists(atPath:
            Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionID).systemextension").path) else { return false }
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              let capabilities = entitlements["com.apple.developer.networking.networkextension"] as? [String] else { return false }
        return capabilities.contains("app-proxy-provider-systemextension") || capabilities.contains("app-proxy-provider")
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "MihomoBox.AppProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func status(applications: [AppProxyEntry]) async throws -> AppProxyExtensionStatus {
        let manager = available ? try await load() : nil
        let targets = try await Task.detached { try AIAppTargets(requireAll: false, applications: applications) }.value
        counts = Dictionary(grouping: targets.targets, by: \.category).mapValues(\.count)
        return .init(available: available, enabled: manager?.isEnabled == true,
                     connected: manager?.connection.status == .connected, targetCounts: counts,
                     executables: targets.targets.filter { $0.category != "cli_host" }.map {
                         .init(applicationID: $0.category, path: $0.path, signingIdentifier: $0.id,
                               teamIdentifier: $0.team, requirement: $0.requirement)
                     })
    }
    func chooseApplication(port: UInt16) async throws -> AppProxyEntry? {
        let panel = NSOpenPanel()
        panel.title = "Add application or CLI executable"
        panel.message = "Choose a signed .app or CLI executable. Signed helpers inside an app are included."
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard await panel.begin() == .OK, let selected = panel.url else { return nil }
        let url = selected.resolvingSymlinksInPath().standardizedFileURL
        let title = selected.pathExtension == "app" ? selected.deletingPathExtension().lastPathComponent : selected.lastPathComponent
        let entry = AppProxyEntry(id: "app_" + UUID().uuidString.lowercased(), title: title, path: url.path, port: port)
        _ = try await Task.detached { try AIAppTargets(requireAll: false, applications: [entry]) }.value
        return entry
    }
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws {
        guard !busy, available else { throw failure("The bundled App Proxy extension is unavailable or busy.") }
        busy = true; defer { busy = false }
        let existing = try await load()
        if !enabled {
            if let existing { try await disable(existing) }
            return
        }
        guard existing?.isEnabled != true else { throw failure("Disable App Proxy before refreshing application identities.") }
        try settings.validate()
        guard !settings.routes.isEmpty else { throw failure("Choose at least one application and proxy route.") }
        let targets = try await Task.detached { try AIAppTargets(requireAll: false, applications: settings.applications) }.value
        guard targets.targets.contains(where: { $0.category != "cli_host" }) else { throw failure("No signed executables are available.") }
        try await activate()
        try await removeLegacyPacketConfigurations()
        let manager = existing ?? Self.makeManager()
        guard manager.routingMethod == .sourceApplication else { throw failure("The saved VPN is not an application routing configuration.") }
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = extensionID
        config.serverAddress = "MihomoBox App Proxy"
        config.providerConfiguration = ["mode": "ai", "targets": targets.targets.map(\.record),
                                        "deadline": 0, "routing": "per-application-v2",
                                        "ports": Dictionary(uniqueKeysWithValues: settings.applications.map { ($0.id, Int($0.port)) })]
        manager.protocolConfiguration = config
        manager.localizedDescription = "MihomoBox App Proxy"
        manager.appRules = targets.rules
        manager.isEnabled = true
        do {
            try await save(manager)
            try await reload(manager)
            guard manager.isEnabled, manager.routingMethod == .sourceApplication,
                  sameRules(manager.appRules, targets.rules),
                  let saved = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  saved.providerBundleIdentifier == extensionID,
                  NSDictionary(dictionary: saved.providerConfiguration ?? [:]).isEqual(to: config.providerConfiguration ?? [:]) else {
                throw failure("App Proxy preference verification failed.")
            }
            try manager.connection.startVPNTunnel()
            for _ in 0..<60 {
                if manager.connection.status == .connected { return }
                try await Task.sleep(for: .seconds(1))
            }
            throw failure("App Proxy did not connect. Check system extension approval in System Settings.")
        } catch {
            let original = error
            do { try await disable(manager) }
            catch { throw failure("App Proxy failed and disabling it could not be verified. Check VPN settings in System Settings.") }
            throw original
        }
    }
    static func makeManager() -> NEAppProxyProviderManager {
        // The inherited forPerAppVPN() factory returns a packet-tunnel
        // NETunnelProviderManager even when invoked on this subclass.
        // App proxy managers already use source-application routing.
        let manager = NEAppProxyProviderManager()
        manager.isEnabled = false
        return manager
    }
    private func removeLegacyPacketConfigurations() async throws {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { c in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { c.resume(throwing: error) }
                else { c.resume(returning: values ?? []) }
            }
        }
        for manager in managers where !(manager is NEAppProxyProviderManager)
          && (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID {
            guard !manager.isEnabled, [.disconnected, .invalid].contains(manager.connection.status) else {
                throw failure("Disable the earlier MihomoBox App Proxy VPN configuration in System Settings before retrying.")
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.removeFromPreferences { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        }
    }
    private func load() async throws -> NEAppProxyProviderManager? {
        let managers: [NEAppProxyProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NEAppProxyProviderManager.loadAllFromPreferences { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
        }
        let matches = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID }
        guard matches.count <= 1 else { throw failure("Multiple App Proxy configurations require review in System Settings.") }
        return matches.first
    }
    private func save(_ manager: NEAppProxyProviderManager) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    private func reload(_ manager: NEAppProxyProviderManager) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    private func disable(_ manager: NEAppProxyProviderManager) async throws {
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        try await save(manager); try await reload(manager)
        guard !manager.isEnabled else { throw failure("App Proxy disable was not saved.") }
        for _ in 0..<30 {
            if [.disconnected, .invalid].contains(manager.connection.status) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw failure("App Proxy is still disconnecting. Refresh its status before continuing.")
    }
    private func sameRules(_ actual: [NEAppRule], _ expected: [NEAppRule]) -> Bool {
        guard actual.count == expected.count else { return false }
        var remaining = expected
        for a in actual {
            guard let index = remaining.firstIndex(where: { b in
                a.matchSigningIdentifier == b.matchSigningIdentifier && a.matchDesignatedRequirement == b.matchDesignatedRequirement
                  && a.matchPath == b.matchPath && NSArray(array: a.matchDomains ?? []).isEqual(to: b.matchDomains ?? [])
                  && sameRules(a.matchTools ?? [], b.matchTools ?? [])
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }
    private func activate() async throws {
        try await withCheckedThrowingContinuation { c in
            activation = c
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let c = activation; activation = nil
        if result == .completed { c?.resume() }
        else { c?.resume(throwing: failure("Restart macOS to finish approving the App Proxy extension.")) }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let c = activation; activation = nil
        c?.resume(throwing: failure("System extension activation failed (code \((error as NSError).code)). Check approval in System Settings."))
    }
}
