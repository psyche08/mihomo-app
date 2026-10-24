import AppKit
import NetworkExtension
import SystemExtensions
import Security
import SystemConfiguration
import CryptoKit
import MihomoBoxUI
import MihomoControl

/// User-scoped NetworkExtension preferences. Privileged core/profile changes
/// remain typed XPC actions handled by the root daemon.
@MainActor
final class AppProxyCoordinator: NSObject, DashboardAppProxyService, @preconcurrency OSSystemExtensionRequestDelegate {
    private let extensionID = "dev.linsheng.mihomo-app.app-proxy"
    private var activation: CheckedContinuation<Void, Error>?
    private var busy = false
    private let codeAccess = AppProxyCodeAccessClient()
    private var maintenance: Task<Void, Never>?
    private var identityIssue: String?
    private var discoveryIssues: [String: Int] = [:]
    override init() {
        super.init()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.maintainIdentities()
            }
        }
    }
    deinit { maintenance?.cancel() }

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
    func status(settings: AppProxySettings) async throws -> AppProxyExtensionStatus {
        let isAvailable = available
        let manager = isAvailable ? try await load() : nil
        let configuration = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        var live: AppProxyRuntimeStatus?
        if let manager, manager.connection.status == .connected {
            live = try? await message(.init(.status), to: manager)
        }
        let snapshot = (configuration?["identitySnapshot"] as? Data).flatMap { try? AppProxyIdentitySnapshot.decode($0) }
        let current = configuration?["routing"] as? String == "per-application-v4" && snapshot != nil
        let ready = current && live?.ready == true && live?.generation == snapshot?.generation
            && manager.map { Self.rulesDigest($0.appRules) == configuration?["rulesDigest"] as? String } == true
        return .init(available: isAvailable, enabled: manager?.isEnabled == true,
                     connected: manager?.connection.status == .connected,
                     requiresReactivation: manager?.isEnabled == true && (!current || (configuration?["bypassCIDRs"] as? [String]) != settings.bypass.cidrs),
                     identityReady: ready, verifiedTargetCount: ready ? live?.verifiedTargets ?? 0 : 0,
                     identityIssue: identityIssue ?? live?.failure?.rawValue ?? (manager?.connection.status == .connected && !ready ? "generationMismatch" : nil),
                     diagnostics: live, discoveryIssues: discoveryIssues)
    }

    func discoverExecutables(applications: [AppProxyEntry]) async throws -> [AppProxyExecutable] {
        let found = try await Task.detached(priority: .utility) {
            try AIAppTargets(requireAll: false, applications: applications)
        }.value
        discoveryIssues = Dictionary(grouping: found.issues, by: { $0.category + ":" + $0.failure.rawValue }).mapValues(\.count)
        return found.targets.filter { $0.category != "cli_host" }.map {
            AppProxyExecutable(applicationID: $0.category, path: $0.path, signingIdentifier: $0.id,
                               teamIdentifier: $0.team, requirement: $0.requirement)
        }
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
        // The store validates the complete candidate list once, including duplicate ownership.
        return entry
    }
    func chooseExecutable() async throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose CLI executable"
        panel.message = "Choose the signed executable itself, such as /usr/bin/curl. Use Command-Shift-G to enter a path."
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        guard await panel.begin() == .OK, let selected = panel.url else { return nil }
        return selected.resolvingSymlinksInPath().standardizedFileURL.path
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
        let snapshot = try await codeAccess.snapshot(records: targets.targets.map(\.identity), interactive: true)
        try await activate()
        try await removeLegacyPacketConfigurations()
        let manager = existing ?? Self.makeManager()
        guard manager.routingMethod == .sourceApplication else { throw failure("The saved VPN is not an application routing configuration.") }
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = extensionID
        config.serverAddress = "MihomoBox"
        config.providerConfiguration = try configuration(settings: settings, targets: targets, snapshot: snapshot)
        manager.protocolConfiguration = config
        manager.localizedDescription = "MihomoBox"
        // Bootstrap with no interception rules. Only publish rules after provider-local authorization succeeds.
        manager.appRules = []
        manager.isEnabled = true
        do {
            try await save(manager)
            try await reload(manager)
            guard manager.isEnabled, manager.routingMethod == .sourceApplication,
                  manager.appRules.isEmpty,
                  let saved = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  saved.providerBundleIdentifier == extensionID,
                  NSDictionary(dictionary: saved.providerConfiguration ?? [:]).isEqual(to: config.providerConfiguration ?? [:]) else {
                throw failure("App Proxy preference verification failed.")
            }
            try manager.connection.startVPNTunnel()
            for _ in 0..<60 {
                if manager.connection.status == .connected {
                    let status = try await message(.init(.status), to: manager)
                    guard status.ready, status.generation == snapshot.generation else { throw AppProxyIdentityFailure.staleAuthorization }
                    manager.appRules = targets.rules
                    try await save(manager); try await reload(manager)
                    guard sameRules(manager.appRules, targets.rules) else { throw AppProxyIdentityFailure.generationMismatch }
                    let committed = try await message(.init(.status), to: manager)
                    guard committed.ready, committed.generation == snapshot.generation else { throw AppProxyIdentityFailure.generationMismatch }
                    identityIssue = nil; return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw failure("App Proxy did not complete provider-local identity verification. Review code-access diagnostics and system extension approval.")
        } catch {
            let original = error
            do { try await disable(manager) }
            catch { throw failure("App Proxy failed and disabling it could not be verified. Check VPN settings in System Settings.") }
            throw original
        }
    }
    private func configuration(settings: AppProxySettings, targets: AIAppTargets, snapshot: AppProxyIdentitySnapshot) throws -> [String: Any] {
        ["mode": "ai", "targets": targets.targets.map(\.record), "deadline": 0,
         "routing": "per-application-v4", "identitySnapshot": try snapshot.encoded(), "rulesDigest": Self.rulesDigest(targets.rules),
         "bypassCIDRs": settings.bypass.cidrs,
         "ports": Dictionary(uniqueKeysWithValues: settings.applications.map { ($0.id, Int($0.port)) })]
    }
    private func message(_ request: AppProxyRuntimeMessage, to manager: NEAppProxyProviderManager) async throws -> AppProxyRuntimeStatus {
        guard let session = manager.connection as? NETunnelProviderSession else { throw AppProxyIdentityFailure.unavailable }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { c in
            let box = AppProxyMessageCompletion(c)
            do {
                try session.sendProviderMessage(data) { data in
                    do {
                        guard let data, data.count <= 65536 else { throw AppProxyIdentityFailure.unavailable }
                        box.finish(.success(try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: data)))
                    } catch { box.finish(.failure(error)) }
                }
            } catch { box.finish(.failure(error)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { box.finish(.failure(AppProxyIdentityFailure.unavailable)) }
        }
    }
    private func maintainIdentities() async {
        guard !busy, available else { return }
        busy = true; defer { busy = false }
        var managed: NEAppProxyProviderManager?
        do {
            guard let manager = try await load(), manager.isEnabled else { return }
            managed = manager
            guard let previous = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  previous.providerConfiguration?["routing"] as? String == "per-application-v4",
                  let data = previous.providerConfiguration?["identitySnapshot"] as? Data else { return }
            let old = try AppProxyIdentitySnapshot.decode(data)
            guard Self.rulesDigest(manager.appRules) == previous.providerConfiguration?["rulesDigest"] as? String else {
                throw AppProxyIdentityFailure.generationMismatch
            }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid == getuid(), old.ownerUID == uid else {
                throw AppProxyIdentityFailure.wrongUser
            }
            let settings = try await ControlGateway().fetchAppProxyRouting().settings
            let targets = try await Task.detached { try AIAppTargets(requireAll: false, applications: settings.applications) }.value
            discoveryIssues = Dictionary(grouping: targets.issues, by: { $0.category + ":" + $0.failure.rawValue }).mapValues(\.count)
            let records = targets.targets.map(\.identity)
            try old.validateRefresh(records)
            if records == old.records, manager.connection.status == .connected {
                let state = try await message(.init(.renew, expected: old.generation), to: manager)
                guard state.ready, state.generation == old.generation else { throw state.failure ?? .generationMismatch }
                identityIssue = nil; return
            }
            let previousPorts = previous.providerConfiguration?["ports"] as? [String: Int]
            guard previousPorts == Dictionary(uniqueKeysWithValues: settings.applications.map { ($0.id, Int($0.port)) }),
                  previous.providerConfiguration?["bypassCIDRs"] as? [String] == settings.bypass.cidrs else { throw AppProxyIdentityFailure.needsAuthorization }
            let next = try await codeAccess.snapshot(records: records, interactive: false)
            let raw = try configuration(settings: settings, targets: targets, snapshot: next)
            let oldRules = manager.appRules
            let wasConnected = manager.connection.status == .connected
            if wasConnected {
                let wire = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
                let state = try await message(.init(.prepare, expected: old.generation, configuration: wire), to: manager)
                guard state.failure == nil else { throw state.failure! }
            }
            let updated = previous.copy() as! NETunnelProviderProtocol
            updated.providerConfiguration = raw
            do {
                manager.protocolConfiguration = updated; manager.appRules = wasConnected ? targets.rules : []
                try await save(manager); try await reload(manager)
                guard sameRules(manager.appRules, wasConnected ? targets.rules : []),
                      let saved = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      NSDictionary(dictionary: saved.providerConfiguration ?? [:]).isEqual(to: raw) else { throw AppProxyIdentityFailure.generationMismatch }
                if [.disconnected, .invalid].contains(manager.connection.status) { try manager.connection.startVPNTunnel() }
                for _ in 0..<10 {
                    if manager.connection.status == .connected { break }
                    try await Task.sleep(for: .seconds(1))
                }
                let live = try await message(.init(.status), to: manager)
                let committed = live.generation == next.generation ? live : try await message(.init(.commit, expected: next.generation), to: manager)
                guard committed.ready, committed.generation == next.generation else { throw committed.failure ?? .generationMismatch }
                if !wasConnected {
                    // On restart, renew grants in the provider before restoring interception rules.
                    manager.appRules = targets.rules
                    try await save(manager); try await reload(manager)
                    guard sameRules(manager.appRules, targets.rules) else { throw AppProxyIdentityFailure.generationMismatch }
                    let published = try await message(.init(.status), to: manager)
                    guard published.ready, published.generation == next.generation else { throw AppProxyIdentityFailure.generationMismatch }
                }
                identityIssue = nil
            } catch {
                // Restore persisted rules before withdrawing prepared grants; ambiguous rollback disables interception.
                manager.protocolConfiguration = previous; manager.appRules = oldRules
                try await save(manager); try await reload(manager)
                _ = try? await message(.init(.abort), to: manager)
                throw error
            }
        } catch {
            identityIssue = (error as? AppProxyIdentityFailure ?? .unavailable).rawValue
            // Never continue to advertise connected while authorization or policy cannot be verified.
            if let managed {
                do { try await disable(managed) }
                catch { identityIssue = "rollbackUnverified" }
            }
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
                throw failure("Disable the earlier VPN configuration for MihomoBox in System Settings before retrying.")
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
    static func rulesDigest(_ rules: [NEAppRule]) -> String {
        // Length-prefixed fields distinguish nil (unrestricted tools) from an empty list.
        func field(_ value: String?) -> String {
            guard let value else { return "n" }
            return "v\(value.utf8.count):" + value
        }
        func array(_ values: [String]?) -> String {
            guard let values else { return "n" }
            return "a\(values.count):" + values.sorted().map { field($0) }.joined()
        }
        func encode(_ rule: NEAppRule) -> String {
            // NE exposes domains as [Any]; tag non-string values so they cannot match generated rules.
            let domains: [String]? = rule.matchDomains?.map { ($0 as? String).map { "s" + $0 } ?? "x" }
            let tools: [NEAppRule]? = rule.matchTools
            let encodedTools = tools.map { values in values.map { encode($0) } }
            return field(rule.matchSigningIdentifier) + field(rule.matchDesignatedRequirement)
                + field(rule.matchPath) + array(domains) + array(encodedTools)
        }
        let payload = array(rules.map { encode($0) })
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func sameRules(_ actual: [NEAppRule], _ expected: [NEAppRule]) -> Bool {
        Self.rulesDigest(actual) == Self.rulesDigest(expected)
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

// Continuation is consumed exactly once under the lock, including timeout and interruption.
private final class AppProxyMessageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppProxyRuntimeStatus, Error>?
    init(_ continuation: CheckedContinuation<AppProxyRuntimeStatus, Error>) { self.continuation = continuation }
    func finish(_ result: Result<AppProxyRuntimeStatus, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(with: result)
    }
}
