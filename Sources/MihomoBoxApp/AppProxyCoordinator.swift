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
    private let crossProcess = AppProxyMutationLock()
    private let codeAccess = AppProxyCodeAccessClient()
    private let usesHeadlessActivation: Bool
    private var maintenance: Task<Void, Never>?
    /// Periodic fallback for changes FSEvents does not report (a removed folder, a revoked
    /// signature); application and CLI updates wake a pass through `updateWatcher` at once.
    static let maintenanceInterval: Duration = .seconds(180)
    /// Wakes maintenance when an update changes a discovery root; nil for headless runs.
    private var updateWatcher: AppProxyUpdateWatcher?
    private var refreshRequested = false
    private var leaseKeeper: Task<Void, Never>?
    private var leaseTarget: (manager: NEAppProxyProviderManager, generation: UUID)?
    private let leaseRenewer = AppProxyLeaseRenewer()
    private let preferenceGate = AppProxyPreferenceGate()
    private var preferencesObserver: NSObjectProtocol?
    private var preferencesDirty = true
    private var preferenceRevision = 0
    private var identityIssue: String?
    private var discoveryIssues: [String: Int] = [:]
    private var lastReadbackObservation: String?
    private var applicationIssues: [String: String] = [:]
    /// The manager from the latest preference read, reused for frequent owner-table requests.
    private var liveManager: NEAppProxyProviderManager?
    /// Process routes last accepted by the daemon; nil until the first push.
    private var lastProcessRoutes: AppProxyProcessRoutes?
    /// Bundled extension version this process already tried to put in place of an older provider.
    private var extensionUpgradeAttempted: String?
    private let selectionKey = "appProxy.requestedApplications.v1"
    private let masterKey = "appProxy.requestedEnabled.v1"
    private var requestedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectionKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: selectionKey) }
    }
    private var requestedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: masterKey) }
        set { UserDefaults.standard.set(newValue, forKey: masterKey) }
    }
    var requestedState: Bool? { UserDefaults.standard.object(forKey: masterKey) as? Bool }
    private func migrateSelection(_ manager: NEAppProxyProviderManager?) {
        guard UserDefaults.standard.object(forKey: selectionKey) == nil else { return }
        let policy = Self.savedPolicy(manager)
        requestedIDs = Set(policy?.routes.map(\.category) ?? [])
        if requestedState == nil { requestedEnabled = manager?.isEnabled == true && policy != nil }
    }
    static let routing = "per-application-v5"
    /// The policy of a saved current-version configuration; nil for an older one.
    static func savedPolicy(_ manager: NEAppProxyProviderManager?) -> AppProxyPolicy? {
        let raw = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard raw?["routing"] as? String == routing else { return nil }
        return (raw?["policy"] as? Data).flatMap { try? AppProxyPolicy.decode($0) }
    }
    override convenience init() { self.init(maintenance: true) }
    /// A headless `--app-proxy` run performs one action and skips the maintenance loop.
    init(maintenance enabled: Bool) {
        usesHeadlessActivation = enabled
        super.init()
        preferencesObserver = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.preferencesChanged() }
            }
        // Renewal does not acquire the preferences/mutation lock. Its only
        // authority is an already validated generation, revalidated by the
        // provider on every renewal. Slow OS preference callbacks cannot starve it.
        leaseKeeper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.renewCachedLease()
            }
        }
        guard enabled else { return }
        updateWatcher = AppProxyUpdateWatcher { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }
        maintenance = Task { [weak self] in
            await self?.maintainIdentities()
            await self?.drainRefreshes()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.maintenanceInterval)
                guard !Task.isCancelled else { return }
                await self?.maintainIdentities()
                await self?.drainRefreshes()
            }
        }
    }
    deinit {
        maintenance?.cancel(); leaseKeeper?.cancel(); updateWatcher?.stop()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    /// An update changed a discovery root: run a pass now instead of at the next periodic one.
    /// A pass already running is followed by another, so a burst costs at most one more pass.
    private func requestRefresh() {
        refreshRequested = true
        guard !busy else { return }
        Task { await drainRefreshes() }
    }
    private func drainRefreshes() async {
        while refreshRequested, !busy {
            refreshRequested = false
            AppLog.info("event=app_proxy_refresh reason=update")
            await maintainIdentities()
        }
    }

    private func preferencesChanged() {
        preferencesDirty = true
        preferenceRevision &+= 1
    }
    private func observedManager() async throws -> NEAppProxyProviderManager? {
        if preferencesDirty { return try await load() }
        return liveManager
    }
    private func rememberLease(_ manager: NEAppProxyProviderManager) {
        let raw = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard manager.isEnabled, manager.connection.status == .connected,
              Self.rulesDigest(manager.appRules) == raw?["rulesDigest"] as? String,
              let policy = Self.savedPolicy(manager), policy.ownerUID == getuid() else { leaseTarget = nil; return }
        leaseTarget = (manager, policy.generation)
    }
    private func renew(_ manager: NEAppProxyProviderManager, generation: UUID) async throws {
        try await leaseRenewer.run(generation: generation) {
            try Self.requireProvider(try await self.message(.init(.renew, expected: generation), to: manager), generation: generation)
        }
    }
    private func renewCachedLease() async {
        guard requestedEnabled, let target = leaseTarget else { return }
        do {
            try await renew(target.manager, generation: target.generation)
        } catch {
            // A concurrent commit may have replaced this generation. Never stop
            // the new provider or publish old readiness because that renewal failed.
            guard leaseTarget?.generation == target.generation else { return }
            identityIssue = "renewal:" + Self.issueCode(error)
            preferencesDirty = true
            AppLog.error("event=app_proxy_policy_failure phase=renewal issue=\(Self.issueCode(error))")
        }
    }

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
        // Policy reads remain serialized with publication; renewal is independent.
        try await waitUntilIdle()
        defer { crossProcess?.unlock() }
        busy = true; defer { busy = false }
        let isAvailable = available
        let manager = isAvailable ? try await observedManager() : nil
        liveManager = manager
        migrateSelection(manager)
        let configuration = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        var live: AppProxyRuntimeStatus?
        if let manager, manager.connection.status == .connected {
            live = try? await message(.init(.status), to: manager)
        }
        let policy = Self.savedPolicy(manager)
        let current = policy != nil
        let liveIssue = Self.readinessIssue(current: current, expectedGeneration: policy?.generation,
            rulesMatch: manager.map { Self.rulesDigest($0.appRules) == configuration?["rulesDigest"] as? String } == true,
            live: live)
        let ready = manager?.isEnabled == true && manager?.connection.status == .connected && liveIssue == nil
        let activeIDs = ready ? Set(policy?.routes.map(\.category) ?? []) : []
        let states = Dictionary(uniqueKeysWithValues: settings.applications.map { app in
            (app.id, AppProxyApplicationStatus(requested: requestedIDs.contains(app.id),
                active: activeIDs.contains(app.id), issue: applicationIssues[app.id],
                servicePaused: !requestedEnabled))
        })
        return .init(available: isAvailable, enabled: manager?.isEnabled == true,
                     connected: manager?.connection.status == .connected,
                     requiresReactivation: manager?.isEnabled == true && (!current || (configuration?["bypassCIDRs"] as? [String]) != settings.bypass.cidrs),
                     identityReady: ready, verifiedTargetCount: ready ? live?.verifiedTargets ?? 0 : 0,
                     identityIssue: identityIssue ?? live?.failure?.rawValue ?? (manager?.connection.status == .connected ? liveIssue : nil),
                     diagnostics: live, discoveryIssues: discoveryIssues, applications: states, requestedEnabled: requestedEnabled)
    }

    nonisolated private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    /// The applications' policies; one that cannot be resolved is left out of display.
    nonisolated static func policies(_ applications: [AppProxyEntry]) -> [AppProxyApplicationPolicy] {
        applications.compactMap { try? AppProxyApplicationPolicy.resolve($0, home: home) }
    }

    /// The top-level code each application's rules name: LaunchServices and the configured
    /// folders, read without validating code. Everything they start matches by identifier.
    func discoverExecutables(applications: [AppProxyEntry]) async throws -> [AppProxyExecutable] {
        let found = await Task.detached(priority: .utility) { AIAppTargets(applications: Self.policies(applications)) }.value
        discoveryIssues = found.issues
        return found.applications.compactMap { code in
            code.category.map {
                AppProxyExecutable(applicationID: $0, path: code.path, signingIdentifier: code.identifier,
                                   teamIdentifier: code.team, requirement: code.requirement)
            }
        }
    }

    /// Which verified process owns each provider connection to a Mihomo listener.
    func flowOwners() async -> AppProxyFlowOwners? {
        guard !busy, available, crossProcess?.tryLock() ?? true else { return nil }
        defer { crossProcess?.unlock() }
        busy = true; defer { busy = false }
        if preferencesDirty { liveManager = try? await observedManager() }
        guard let manager = liveManager, manager.connection.status == .connected else { return nil }
        do { return try await message(.init(.flowOwners), to: manager).flowOwners }
        catch { return nil }
    }

    func launchHosts() async -> [AppProxyLaunchHost] {
        await Task.detached(priority: .utility) {
            AIAppTargets.launchHostLocations().map { AppProxyLaunchHost(path: $0.path) }
        }.value
    }

    func chooseApplication(port: UInt16) async throws -> AppProxyEntry? {
        let panel = NSOpenPanel()
        panel.title = "Add application or CLI executable"
        panel.message = "Choose a .app or CLI signed with a Developer ID. Its Team ID and signing identifiers are read once."
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard await panel.begin() == .OK, let selected = panel.url else { return nil }
        return try await application(at: selected.path, port: port)
    }
    /// A custom application from its signature: Team ID, signing identifiers (with nested helpers)
    /// and, outside the folders the provider reads, the code folder to grant.
    func application(at path: String, port: UInt16) async throws -> AppProxyEntry {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let code = try await Task.detached(priority: .userInitiated) { try AIAppTargets.codeIdentity(of: url.path) }.value
        let title = url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        // The store validates the complete candidate list once, including duplicate ownership.
        return AppProxyEntry(id: "app_" + UUID().uuidString.lowercased(), title: title, path: url.path, port: port,
                             teamIdentifiers: [code.team], signingIdentifiers: code.identifiers,
                             directories: AIAppTargets.codeFolders(for: url.path, home: Self.home))
    }
    func chooseFolder() async throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose code folder"
        panel.message = "Choose a folder that holds this application's code, outside /Applications. It is granted read-only to the App Proxy extension."
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard await panel.begin() == .OK, let selected = panel.url else { return nil }
        return selected.resolvingSymlinksInPath().standardizedFileURL.path
    }
    /// A user action waits for a running maintenance pass (in this process or in the
    /// menu-bar app while a headless run is active) instead of failing while it runs.
    /// Returns holding the cross-process lock; no suspension separates the final checks
    /// from the caller claiming `busy`.
    private func waitUntilIdle(timeout: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while busy || !(crossProcess?.tryLock() ?? true) {
            guard clock.now < deadline else { throw failure("App Proxy is still updating. Try again shortly.") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws {
        if usesHeadlessActivation {
            try await waitUntilIdle()
            busy = true
            requestedEnabled = enabled
            crossProcess?.unlock() // The signed child acquires this lock itself.
            defer { busy = false }
            try await runHeadlessToggle(enabled)
            liveManager = nil; preferencesDirty = true; identityIssue = nil
            return
        }
        try await waitUntilIdle()
        defer { crossProcess?.unlock() }
        requestedEnabled = enabled // Persist accepted intent before runtime work.
        guard available else { throw failure("The bundled App Proxy extension is unavailable.") }
        busy = true; defer { busy = false }
        let existing = try await load(); migrateSelection(existing)
        requestedEnabled = enabled
        if !enabled {
            requestedEnabled = false
            if let existing { try await disable(existing) }
            await syncProcessRoutes(nil)
            return
        }
        guard !requestedIDs.isEmpty else { throw failure("Choose Authorize & Enable on an application first.") }
        requestedEnabled = true
        try await reconcile(settings: settings, existing: existing, interactiveID: nil)
    }

    func setApplicationEnabled(_ id: String, enabled: Bool, settings: AppProxySettings) async throws {
        try await setApplicationEnabled(id, enabled: enabled, settings: settings, interactive: true)
    }
    /// `interactive` is the operator's consent to the scanned code and scopes (the confirmation
    /// sheet or `mihomoboxctl app-proxy enable --approve`); otherwise only prior approvals apply.
    func setApplicationEnabled(_ id: String, enabled: Bool, settings: AppProxySettings, interactive: Bool) async throws {
        try await waitUntilIdle()
        defer { crossProcess?.unlock() }
        guard available, settings.applications.contains(where: { $0.id == id }) else {
            throw failure("The application or App Proxy service is unavailable.")
        }
        busy = true; defer { busy = false }
        let existing = try await load(); migrateSelection(existing)
        if enabled { requestedIDs.insert(id); requestedEnabled = true }
        else { requestedIDs.remove(id); applicationIssues.removeValue(forKey: id) }
        do { try await reconcile(settings: settings, existing: existing, interactiveID: enabled && interactive ? id : nil) }
        catch {
            if enabled { applicationIssues[id] = Self.issueCode(error) }
            throw error
        }
        if enabled, let issue = applicationIssues[id] {
            throw failure("This application is not intercepted by App Proxy: " + issue + ". Other application selections are preserved.")
        }
    }

    private func reconcile(settings: AppProxySettings, existing: NEAppProxyProviderManager?, interactiveID: String?) async throws {
        try settings.validate()
        guard !settings.routes.isEmpty else { throw failure("Choose a proxy node for each saved application.") }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid == getuid() else { throw AppProxyIdentityFailure.wrongUser }
        let previous = existing?.protocolConfiguration as? NETunnelProviderProtocol
        let old = Self.savedPolicy(existing)
        if let old, old.ownerUID != getuid() { throw AppProxyIdentityFailure.wrongUser }
        if let existing, existing.isEnabled, old != nil,
           Self.rulesDigest(existing.appRules) != previous?.providerConfiguration?["rulesDigest"] as? String {
            try await disable(existing)
            throw PolicyCheckFailure.rulesReadbackMismatch
        }
        let home = Self.home
        let prepare: () async throws -> AppProxyEnrollment = {
            try await AppProxyEnrollment.prepare(applications: settings.applications, requested: self.requestedIDs,
                interactiveID: interactiveID, home: home,
                build: { policies in await Task.detached(priority: .utility) { AIAppTargets(applications: policies) }.value },
                authorize: { category, folders, interactive in
                    try await self.codeAccess.grants(category: category, folders: folders, interactive: interactive)
                })
        }
        let plan: AppProxyEnrollment
        if let existing, let old, existing.isEnabled, existing.connection.status == .connected {
            do {
                plan = try await AppProxyAuthorizationLease.run(renew: {
                    try await self.renew(existing, generation: old.generation)
                }, operation: prepare)
            } catch { try await disable(existing); throw error }
        } else { plan = try await prepare() }
        applicationIssues = plan.failures
        discoveryIssues = plan.targets.issues
        guard requestedEnabled, let policy = plan.policy else {
            if let existing { try await disable(existing) }
            identityIssue = nil
            await syncProcessRoutes(nil)
            return
        }
        let targets = plan.targets, rules = targets.rules
        let ports = Dictionary(uniqueKeysWithValues: settings.applications.map { ($0.id, Int($0.port)) })
        // Unchanged publishers, folders, code and rules: keep the running generation.
        if let existing, let old, existing.isEnabled, existing.connection.status == .connected,
           old.sameAuthority(as: policy),
           Self.rulesDigest(existing.appRules) == Self.rulesDigest(rules),
           previous?.providerConfiguration?["rulesDigest"] as? String == Self.rulesDigest(rules),
           previous?.providerConfiguration?["ports"] as? [String: Int] == ports,
           previous?.providerConfiguration?["bypassCIDRs"] as? [String] == settings.bypass.cidrs {
            do {
                try await renew(existing, generation: old.generation)
                rememberLease(existing)
                identityIssue = nil
                await syncProcessRoutes(targets.processRoutes)
                return
            } catch {
                // A failed live lease is never presented as healthy. Rebuild below.
                try await disable(existing)
            }
        }
        // Mihomo's process rules first: they reload without a restart, so a new version's
        // TUN and system-proxy connections follow its route while the provider prepares.
        await syncProcessRoutes(targets.processRoutes)
        try await install(settings: settings, policy: policy, rules: rules)
    }

    /// Mirrors the active applications' code locations into Mihomo's process rules, so their
    /// system-proxy and TUN connections, which never reach the provider, follow the same route.
    /// Best effort: interception does not depend on it.
    private func syncProcessRoutes(_ routes: AppProxyProcessRoutes?) async {
        let routes = routes ?? AppProxyProcessRoutes()
        guard routes != lastProcessRoutes else { return }
        do {
            try await ControlGateway().setAppProxyProcesses(routes)
            lastProcessRoutes = routes
        } catch { AppLog.error("event=app_proxy_process_routes result=failed") }
    }

    private func install(settings: AppProxySettings, policy: AppProxyPolicy, rules: [NEAppRule]) async throws {
        try await removeLegacyPacketConfigurations()
        // A cached manager can renew an existing lease, but cannot authorize a
        // policy mutation. Always read current preferences before prepare/save.
        let manager = try await load() ?? Self.makeManager()
        guard manager.routingMethod == .sourceApplication else { throw failure("The saved VPN is not an application routing configuration.") }
        let previous = manager.protocolConfiguration as? NETunnelProviderProtocol
        let previousRules = manager.appRules
        let old = Self.savedPolicy(manager)
        let liveUpdate = manager.isEnabled && manager.connection.status == .connected && old != nil
        let raw = try configuration(settings: settings, policy: policy, rules: rules)
        try Self.requireConfigurationBudget(raw, rules: rules)
        if !liveUpdate { try await activate() }
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = extensionID; config.serverAddress = "MihomoBox"
        config.providerConfiguration = raw
        var prepared = false
        do {
            if liveUpdate, let old {
                // Provider validates the complete new policy before interception changes.
                let wire = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
                let reply = try await message(.init(.prepare, expected: old.generation, configuration: wire), to: manager)
                if let failure = reply.failure { throw failure }
                prepared = true
            } else if manager.isEnabled { try await disable(manager) }
            manager.protocolConfiguration = config; manager.localizedDescription = "MihomoBox"
            manager.appRules = liveUpdate ? rules : []
            manager.isEnabled = true
            try await save(manager); try await reload(manager)
            guard manager.isEnabled, manager.routingMethod == .sourceApplication,
                  sameRules(manager.appRules, liveUpdate ? rules : []),
                  let saved = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  NSDictionary(dictionary: saved.providerConfiguration ?? [:]).isEqual(to: raw) else {
                throw PolicyCheckFailure.configurationReadbackMismatch
            }
            if !liveUpdate { try manager.connection.startVPNTunnel() }
            for _ in 0..<60 {
                if manager.connection.status == .connected {
                    let status = try await message(.init(.status), to: manager)
                    let committed = status.generation == policy.generation ? status
                        : try await message(.init(.commit, expected: policy.generation), to: manager)
                    try Self.requireProvider(committed, generation: policy.generation)
                    leaseTarget = (manager, policy.generation)
                    if !liveUpdate {
                        manager.appRules = rules
                        try await save(manager); try await reload(manager)
                    }
                    try requireSameRules(manager.appRules, rules, phase: "enable")
                    try Self.requireProvider(try await message(.init(.status), to: manager), generation: policy.generation)
                    liveManager = manager; rememberLease(manager)
                    identityIssue = nil; return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw PolicyCheckFailure.providerNotReady
        } catch {
            let original = error
            identityIssue = "enable:" + Self.issueCode(error)
            AppLog.error("event=app_proxy_policy_failure phase=enable issue=\(Self.issueCode(error))")
            // Only retain the previous generation when both stored rules and
            // provider readiness can be positively verified after rollback.
            var restored = false
            if liveUpdate, let previous, let old {
                do {
                    manager.protocolConfiguration = previous; manager.appRules = previousRules
                    try await save(manager); try await reload(manager)
                    if prepared { _ = try await message(.init(.abort), to: manager) }
                    try requireSameRules(manager.appRules, previousRules, phase: "rollback")
                    try Self.requireProvider(try await message(.init(.status), to: manager), generation: old.generation)
                    restored = true
                } catch { restored = false }
            }
            if !restored { try await disable(manager) }
            throw original
        }
    }
    private func configuration(settings: AppProxySettings, policy: AppProxyPolicy, rules: [NEAppRule]) throws -> [String: Any] {
        ["mode": "ai", "routing": Self.routing, "policy": try policy.encoded(), "rulesDigest": Self.rulesDigest(rules),
         "bypassCIDRs": settings.bypass.cidrs,
         "ports": Dictionary(uniqueKeysWithValues: settings.applications.map { ($0.id, Int($0.port)) })]
    }
    enum ProviderTransportFailure: String, Error, LocalizedError {
        case emptyReply, oversizedReply, preferencesTimeout, preferencesBusy
        var errorDescription: String? { "App Proxy provider reply unavailable: " + rawValue }
    }
    private func message(_ request: AppProxyRuntimeMessage, to manager: NEAppProxyProviderManager) async throws -> AppProxyRuntimeStatus {
        try await Self.withProviderReplyRetry(action: request.action) {
            try await self.messageOnce(request, to: manager)
        }
    }
    static func withProviderReplyRetry<T>(action: AppProxyRuntimeMessage.Action,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        operation: @MainActor () async throws -> T) async throws -> T {
        let retryable = [.status, .flowOwners, .renew].contains(action)
        for attempt in 0..<3 {
            do { return try await operation() }
            catch ProviderTransportFailure.emptyReply where retryable && attempt < 2 {
                // Saving app rules may briefly replace the provider IPC channel.
                // Only idempotent reads/renewal may retry an unobserved reply.
                try await pause()
            }
        }
        throw ProviderTransportFailure.emptyReply
    }
    private func messageOnce(_ request: AppProxyRuntimeMessage, to manager: NEAppProxyProviderManager) async throws -> AppProxyRuntimeStatus {
        guard let session = manager.connection as? NETunnelProviderSession else { throw AppProxyIdentityFailure.unavailable }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { c in
            let box = AppProxyCompletion(c)
            do {
                try session.sendProviderMessage(data) { data in
                    do {
                        guard let data else { throw ProviderTransportFailure.emptyReply }
                        guard data.count <= 65536 else { throw ProviderTransportFailure.oversizedReply }
                        box.finish(.success(try JSONDecoder().decode(AppProxyRuntimeStatus.self, from: data)))
                    } catch { box.finish(.failure(error)) }
                }
            } catch { box.finish(.failure(error)) }
            // Preparing opens the granted folders; nothing validates code files any more.
            let timeout: Double = [.prepare, .commit].contains(request.action) ? 30 : 10
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.finish(.failure(AppProxyIdentityFailure.providerTimeout)) }
        }
    }
    private func maintainIdentities() async {
        guard !busy, available, crossProcess?.tryLock() ?? true else { return }
        var holdsLock = true
        defer { if holdsLock { crossProcess?.unlock() } }
        busy = true; defer { busy = false }
        var managed: NEAppProxyProviderManager?
        do {
            let manager = try await observedManager(); managed = manager; migrateSelection(manager)
            guard requestedEnabled else {
                updateWatcher?.stop()
                if let manager, manager.isEnabled || manager.connection.status == .connected {
                    if usesHeadlessActivation {
                        holdsLock = false; crossProcess?.unlock()
                        try await runHeadlessToggle(false)
                        liveManager = nil; preferencesDirty = true
                    } else { try await disable(manager) }
                }
                return
            }
            let settings = try await ControlGateway().fetchAppProxyRouting().settings
            updateWatcher?.watch(AIAppTargets.updateRoots(
                applications: Self.policies(settings.applications.filter { requestedIDs.contains($0.id) }), home: Self.home))
            // After an update the bundled provider is newer than the running one, and only a
            // non-live install activates it. Do that here, in the background after launch,
            // rather than at the user's next enable, where it took minutes under load.
            let upgrading = await providerNeedsUpgrade(manager)
            if upgrading, let manager {
                extensionUpgradeAttempted = bundledExtensionVersion
                AppLog.info("event=app_proxy_extension_upgrade phase=started bundled=\(bundledExtensionVersion ?? "unknown")")
                try await disable(manager)
            }
            if usesHeadlessActivation,
               manager?.isEnabled != true || manager?.connection.status != .connected {
                holdsLock = false; crossProcess?.unlock()
                try await runHeadlessToggle(true)
                liveManager = nil; preferencesDirty = true; identityIssue = nil
            } else {
                try await reconcile(settings: settings, existing: manager, interactiveID: nil)
            }
            if upgrading { AppLog.info("event=app_proxy_extension_upgrade result=success") }
        } catch {
            identityIssue = "maintenance:" + Self.issueCode(error)
            AppLog.error("event=app_proxy_policy_failure phase=maintenance issue=\(Self.issueCode(error))")
            // System-wide failures (console owner, transport, ambiguous publication)
            // remain fail-closed. Per-app discovery/consent failures are handled above.
            let readUnavailable = (error as? ProviderTransportFailure).map { [.preferencesTimeout, .preferencesBusy].contains($0) } == true
            if !readUnavailable, holdsLock, let managed {
                do { try await disable(managed) } catch { identityIssue = "rollbackUnverified" }
            }
        }
    }

    /// Reuse the fixed signed operator entry point for master activation. A fresh
    /// host avoids retaining a GUI NetworkExtension session across stop/start.
    /// The child never receives --approve, so only existing consent can be used.
    private func runHeadlessToggle(_ enabled: Bool) async throws {
        guard let executable = Bundle.main.executableURL else { throw failure("The signed App Proxy host is unavailable.") }
        let arguments = [AppProxyCommand.argument, enabled ? "on" : "off"]
        let (data, status) = try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
            defer { timeout.cancel() }
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard result.count <= 131072 else { throw ProviderTransportFailure.oversizedReply }
            return (result, process.terminationStatus)
        }.value
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("The App Proxy host returned no usable result.")
        }
        if let error = result["error"] as? String { throw failure(error) }
        guard status == 0, result["enabled"] as? Bool == enabled,
              !enabled || (result["connected"] as? Bool == true && result["identityReady"] as? Bool == true) else {
            throw failure("The App Proxy host could not confirm the requested state.")
        }
    }

    enum PolicyCheckFailure: String, Error, LocalizedError {
        case rulesReadbackMismatch, configurationReadbackMismatch, providerGenerationMismatch, providerNotReady
        var errorDescription: String? { "App Proxy policy verification failed: " + rawValue }
    }
    /// NetworkExtension rejects a saved configuration above 512 KiB. Unchecked, the rule-less
    /// first save succeeds and interception starts, then saving the rules fails.
    /// The configuration crosses XPC before it is measured, which drops object sharing: a tool
    /// listed by several rules counts once per rule. Measure detached copies the same way.
    /// Identifier tools keep a policy far below this (a few dozen kilobytes).
    static let configurationBudget = 440 * 1024
    static func configurationSize(_ raw: [String: Any], rules: [NEAppRule]) -> Int {
        (try? NSKeyedArchiver.archivedData(withRootObject: [raw, rules.map(detached)] as NSArray,
                                           requiringSecureCoding: false).count) ?? Int.max
    }
    private static func detached(_ rule: NEAppRule) -> NEAppRule {
        let copy = NEAppRule(signingIdentifier: rule.matchSigningIdentifier, designatedRequirement: rule.matchDesignatedRequirement)
        copy.matchPath = rule.matchPath
        copy.matchTools = rule.matchTools?.map(detached)
        return copy
    }
    static func requireConfigurationBudget(_ raw: [String: Any], rules: [NEAppRule]) throws {
        let bytes = configurationSize(raw, rules: rules)
        AppLog.info("event=app_proxy_configuration_size bytes=\(bytes) budget=\(configurationBudget) rules=\(rules.count) tools=\(rules.reduce(0) { $0 + ($1.matchTools?.count ?? 0) })")
        guard bytes <= configurationBudget else { throw AppProxyIdentityFailure.capacity }
    }
    static func issueCode(_ error: Error) -> String {
        (error as? ProviderTransportFailure)?.rawValue ?? (error as? PolicyCheckFailure)?.rawValue ?? (error as? AppProxyIdentityFailure ?? .unavailable).rawValue
    }
    static func requireProvider(_ status: AppProxyRuntimeStatus, generation: UUID) throws {
        if let failure = status.failure { throw failure }
        guard status.generation == generation else { throw PolicyCheckFailure.providerGenerationMismatch }
        guard status.ready else { throw PolicyCheckFailure.providerNotReady }
    }
    static func readinessIssue(current: Bool, expectedGeneration: UUID?, rulesMatch: Bool,
                               live: AppProxyRuntimeStatus?) -> String? {
        guard current, let expectedGeneration else { return "configurationObsolete" }
        guard rulesMatch else { return PolicyCheckFailure.rulesReadbackMismatch.rawValue }
        guard let live else { return "providerUnavailable" }
        do { try requireProvider(live, generation: expectedGeneration); return nil }
        catch { return issueCode(error) }
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
        let managers: [NETunnelProviderManager] = try await preferenceRequest("legacyLoadAll") { finish in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { finish(.failure(error)) }
                else { finish(.success(values ?? [])) }
            }
        }
        for manager in managers where !(manager is NEAppProxyProviderManager)
          && (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID {
            guard !manager.isEnabled, [.disconnected, .invalid].contains(manager.connection.status) else {
                throw failure("Disable the earlier VPN configuration for MihomoBox in System Settings before retrying.")
            }
            let _: Void = try await preferenceRequest("legacyRemove") { finish in
                manager.removeFromPreferences { error in
                    if let error { finish(.failure(error)) } else { finish(.success(())) }
                }
            }
        }
    }
    private func preferenceRequest<Value>(_ operation: String, _ start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard let ticket = preferenceGate.begin() else { throw ProviderTransportFailure.preferencesBusy }
        let gate = preferenceGate
        return try await withCheckedThrowingContinuation { continuation in
            let completion = AppProxyCompletion(continuation)
            let timeout = DispatchWorkItem {
                AppLog.error("event=app_proxy_preferences_timeout operation=\(operation)")
                completion.finish(.failure(ProviderTransportFailure.preferencesTimeout))
            }
            // Timing out does not cancel the OS request. Keep the gate occupied
            // until its real callback arrives instead of growing nehelper's queue.
            start { gate.finish(ticket); timeout.cancel(); completion.finish($0) }
            // A newly signed host/extension can spend over 15 seconds in macOS
            // assessment during an in-place upgrade. Keep a finite budget without
            // misclassifying normal first activation as an unavailable service.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        }
    }
    private func load() async throws -> NEAppProxyProviderManager? {
        let revision = preferenceRevision
        let managers: [NEAppProxyProviderManager] = try await preferenceRequest("loadAll") { finish in
            NEAppProxyProviderManager.loadAllFromPreferences { values, error in
                if let error { finish(.failure(error)) }
                else { finish(.success(values ?? [])) }
            }
        }
        let matches = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID }
        guard matches.count <= 1 else { throw failure("Multiple App Proxy configurations require review in System Settings.") }
        guard let manager = matches.first else {
            liveManager = nil; leaseTarget = nil; preferencesDirty = preferenceRevision != revision
            return nil
        }
        // Use a current preference read for policy decisions; do not authorize from
        // an enumerated manager's potentially older view. Reload failure propagates.
        let enumerated = Self.readbackObservation(manager)
        try await reload(manager)
        let reloaded = Self.readbackObservation(manager)
        let observation = "enumerated=\(enumerated) reloaded=\(reloaded)"
        if observation != lastReadbackObservation {
            lastReadbackObservation = observation
            AppLog.info("event=app_proxy_preference_readback \(observation)")
        }
        liveManager = manager; rememberLease(manager)
        preferencesDirty = preferenceRevision != revision
        return manager
    }
    // Bounded, non-identifying metadata only. Never emit rules, paths, requirements,
    // generations, bookmarks, or their fingerprints into general application logs.
    private static func readbackObservation(_ manager: NEAppProxyProviderManager) -> String {
        let config = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let matches = rulesDigest(manager.appRules) == config?["rulesDigest"] as? String
        let toolCount = manager.appRules.reduce(0) { $0 + ($1.matchTools?.count ?? 0) }
        return "\(manager.isEnabled ? 1 : 0):\(manager.appRules.count):\(toolCount):\(matches ? 1 : 0)"
    }
    private func save(_ manager: NEAppProxyProviderManager) async throws {
        let _: Void = try await preferenceRequest("save") { finish in
            manager.saveToPreferences { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }
    private func reload(_ manager: NEAppProxyProviderManager) async throws {
        let _: Void = try await preferenceRequest("reload") { finish in
            manager.loadFromPreferences { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }
    private func disable(_ manager: NEAppProxyProviderManager) async throws {
        leaseTarget = nil; preferencesDirty = true
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
    private func requireSameRules(_ actual: [NEAppRule], _ expected: [NEAppRule], phase: String) throws {
        guard !sameRules(actual, expected) else { return }
        AppLog.error("event=app_proxy_rules_diff phase=\(phase) \(Self.rulesDifference(actual: actual, expected: expected).summary)")
        throw PolicyCheckFailure.rulesReadbackMismatch
    }

    /// Count-only comparison of generated and read-back rules. Like the readback
    /// observation, it never carries identifiers, paths or requirements.
    struct RuleDifference: Equatable {
        var expectedRules = 0, actualRules = 0, missingRules = 0, extraRules = 0
        var requirementText = 0, requirementCanonical = 0, requirementCleared = 0, domains = 0, toolScope = 0
        var expectedTools = 0, actualTools = 0, missingTools = 0, extraTools = 0
        var toolRequirementText = 0, toolRequirementCanonical = 0, toolRequirementCleared = 0
        var movedPaths = 0, pathCaseOnly = 0, pathResolvesEqual = 0, pathCleared = 0
        var summary: String {
            "rules=\(expectedRules)/\(actualRules) missing=\(missingRules) extra=\(extraRules)"
                + " dr=\(requirementText) drCanon=\(requirementCanonical) drCleared=\(requirementCleared)"
                + " domains=\(domains) toolScope=\(toolScope)"
                + " tools=\(expectedTools)/\(actualTools) toolMissing=\(missingTools) toolExtra=\(extraTools)"
                + " toolDr=\(toolRequirementText) toolDrCanon=\(toolRequirementCanonical) toolDrCleared=\(toolRequirementCleared)"
                + " moved=\(movedPaths) caseOnly=\(pathCaseOnly) resolved=\(pathResolvesEqual) pathCleared=\(pathCleared)"
        }
    }
    static func rulesDifference(actual: [NEAppRule], expected: [NEAppRule]) -> RuleDifference {
        var d = RuleDifference(expectedRules: expected.count, actualRules: actual.count)
        let rules = pair(expected: expected, actual: actual)
        d.missingRules = rules.missing.count; d.extraRules = rules.extra.count
        classifyMoved(missing: rules.missing, extra: rules.extra, into: &d)
        for (wanted, found) in rules.pairs {
            compareRequirement(wanted, found, text: &d.requirementText, canonical: &d.requirementCanonical, cleared: &d.requirementCleared)
            let wantedDomains = wanted.matchDomains?.map { "\($0)" }.sorted(), foundDomains = found.matchDomains?.map { "\($0)" }.sorted()
            if wantedDomains != foundDomains { d.domains += 1 }
            d.expectedTools += wanted.matchTools?.count ?? 0; d.actualTools += found.matchTools?.count ?? 0
            guard let wantedTools = wanted.matchTools, let foundTools = found.matchTools else {
                if (wanted.matchTools == nil) != (found.matchTools == nil) { d.toolScope += 1 }
                continue
            }
            let tools = pair(expected: wantedTools, actual: foundTools)
            d.missingTools += tools.missing.count; d.extraTools += tools.extra.count
            classifyMoved(missing: tools.missing, extra: tools.extra, into: &d)
            for (wantedTool, foundTool) in tools.pairs {
                compareRequirement(wantedTool, foundTool, text: &d.toolRequirementText,
                                   canonical: &d.toolRequirementCanonical, cleared: &d.toolRequirementCleared)
            }
        }
        return d
    }
    private static func pair(expected: [NEAppRule], actual: [NEAppRule])
        -> (pairs: [(NEAppRule, NEAppRule)], missing: [NEAppRule], extra: [NEAppRule]) {
        func key(_ rule: NEAppRule) -> String { rule.matchSigningIdentifier + "\u{0}" + (rule.matchPath ?? "") }
        var available = Dictionary(grouping: actual, by: key)
        var pairs: [(NEAppRule, NEAppRule)] = [], missing: [NEAppRule] = []
        for rule in expected {
            if var candidates = available[key(rule)], !candidates.isEmpty {
                pairs.append((rule, candidates.removeFirst())); available[key(rule)] = candidates
            } else { missing.append(rule) }
        }
        return (pairs, missing, available.values.flatMap { $0 })
    }
    /// An expected entry whose signing ID survives under another path: say how the path changed.
    private static func classifyMoved(missing: [NEAppRule], extra: [NEAppRule], into d: inout RuleDifference) {
        var pool = extra
        for rule in missing {
            guard let index = pool.firstIndex(where: { $0.matchSigningIdentifier == rule.matchSigningIdentifier }) else { continue }
            let other = pool.remove(at: index)
            d.movedPaths += 1
            guard let wanted = rule.matchPath, let found = other.matchPath else { d.pathCleared += 1; continue }
            if wanted.lowercased() == found.lowercased() { d.pathCaseOnly += 1 }
            if URL(fileURLWithPath: wanted).resolvingSymlinksInPath().path == URL(fileURLWithPath: found).resolvingSymlinksInPath().path {
                d.pathResolvesEqual += 1
            }
        }
    }
    private static func compareRequirement(_ wanted: NEAppRule, _ found: NEAppRule,
                                           text: inout Int, canonical: inout Int, cleared: inout Int) {
        guard wanted.matchDesignatedRequirement != found.matchDesignatedRequirement else { return }
        text += 1
        if found.matchDesignatedRequirement.isEmpty { cleared += 1; return }
        if let a = canonicalRequirement(wanted.matchDesignatedRequirement),
           a == canonicalRequirement(found.matchDesignatedRequirement) { canonical += 1 }
    }
    private static func canonicalRequirement(_ text: String?) -> String? {
        guard let text else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var canonical: CFString?
        guard SecRequirementCopyString(requirement, [], &canonical) == errSecSuccess else { return nil }
        return canonical as String?
    }
    private var bundledExtensionVersion: String? {
        let info = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(extensionID).systemextension/Contents/Info.plist")
        return NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String
    }
    /// True once per bundled version when a connected provider reports another version (or none).
    private func providerNeedsUpgrade(_ manager: NEAppProxyProviderManager?) async -> Bool {
        guard let manager, manager.isEnabled, manager.connection.status == .connected,
              let bundled = bundledExtensionVersion, extensionUpgradeAttempted != bundled,
              let live = try? await message(.init(.status), to: manager) else { return false }
        return live.providerVersion != bundled
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
private final class AppProxyCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(with: result)
    }
}

/// Serializes App Proxy mutations between the menu-bar app and a headless `--app-proxy`
/// run, which share the NetworkExtension configuration and the requested selection.
final class AppProxyMutationLock {
    private let descriptor: Int32
    init?() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("MihomoBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("app-proxy.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
    }
    deinit { close(descriptor) }
    func tryLock() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
    func unlock() { flock(descriptor, LOCK_UN) }
}

/// An expired caller must not enqueue another OS request behind its still-live
/// predecessor. A late callback releases only its own ticket.
final class AppProxyPreferenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: UUID?
    func begin() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard pending == nil else { return nil }
        let ticket = UUID(); pending = ticket; return ticket
    }
    func finish(_ ticket: UUID) {
        lock.lock(); defer { lock.unlock() }
        if pending == ticket { pending = nil }
    }
}
