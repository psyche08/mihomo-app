import Foundation
import Security
import MihomoControl

public struct AppProxyExecutable: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let applicationID: String
    public let path: String
    public let signingIdentifier: String
    public let teamIdentifier: String?
    public let requirement: String
    public init(applicationID: String, path: String, signingIdentifier: String, teamIdentifier: String?, requirement: String) {
        self.applicationID = applicationID; self.path = path; self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier; self.requirement = requirement
    }
}

/// A saved routing entry is distinct from consent, requested enablement and
/// actual OS interception. Never label a pending entry as connected.
public struct AppProxyApplicationStatus: Equatable, Sendable {
    public var requested: Bool
    public var active: Bool
    public var issue: String?
    public var servicePaused: Bool
    public init(requested: Bool = false, active: Bool = false, issue: String? = nil, servicePaused: Bool = false) {
        self.requested = requested; self.active = active; self.issue = issue; self.servicePaused = servicePaused
    }
    public var summary: String {
        if active { return "Intercepted · DNS and API not yet verified" }
        if !requested { return "Off · Not intercepted by App Proxy" }
        if servicePaused { return "Paused · Not intercepted by App Proxy" }
        if let issue {
            if ["needsAuthorization", "staleAuthorization", "permission"].contains(issue) {
                return "Code access required · Not intercepted by App Proxy"
            }
            return "Not intercepted · " + issue
        }
        return "Waiting for provider verification · Not intercepted"
    }
}

/// A terminal, editor or SSH login whose CLIs App Proxy captures. Display-only.
public struct AppProxyLaunchHost: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public init(path: String) {
        self.path = path
        name = Self.name(forExecutable: path)
    }
    static func name(forExecutable path: String) -> String {
        if ["/usr/libexec/sshd-session", "/usr/sbin/sshd"].contains(path) { return "SSH login" }
        let components = path.split(separator: "/")
        if let bundle = components.first(where: { $0.hasSuffix(".app") }) { return String(bundle.dropLast(4)) }
        return components.last.map(String.init) ?? path
    }
}

public struct AppProxyExtensionStatus: Equatable, Sendable {
    public var available: Bool
    public var enabled: Bool
    public var connected: Bool
    public var requiresReactivation: Bool
    public var discoveryIssues: [String: Int]
    public var identityReady: Bool
    public var verifiedTargetCount: Int
    public var identityIssue: String?
    public var applications: [String: AppProxyApplicationStatus]
    public var diagnostics: AppProxyRuntimeStatus?
    public var targetCounts: [String: Int]
    public var executables: [AppProxyExecutable]
    public var launchHosts: [AppProxyLaunchHost] = []
    public init(available: Bool, enabled: Bool = false, connected: Bool = false, requiresReactivation: Bool = false, targetCounts: [String: Int] = [:], executables: [AppProxyExecutable] = [], identityReady: Bool = false, verifiedTargetCount: Int = 0,
                identityIssue: String? = nil, diagnostics: AppProxyRuntimeStatus? = nil, discoveryIssues: [String: Int] = [:], applications: [String: AppProxyApplicationStatus] = [:]) {
        self.applications = applications
        self.available = available; self.enabled = enabled; self.connected = connected; self.targetCounts = targetCounts
        self.requiresReactivation = requiresReactivation
        self.executables = executables
        self.discoveryIssues = discoveryIssues
        self.identityReady = identityReady; self.verifiedTargetCount = verifiedTargetCount
        self.identityIssue = identityIssue; self.diagnostics = diagnostics
    }
}

@MainActor
public protocol DashboardAppProxyService: AnyObject {
    func status(settings: AppProxySettings) async throws -> AppProxyExtensionStatus
    func discoverExecutables(applications: [AppProxyEntry]) async throws -> [AppProxyExecutable]
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws
    func setApplicationEnabled(_ id: String, enabled: Bool, settings: AppProxySettings) async throws
    func chooseApplication(port: UInt16) async throws -> AppProxyEntry?
    func chooseExecutable() async throws -> String?
    func launchHosts() async -> [AppProxyLaunchHost]
    func flowOwners() async -> AppProxyFlowOwners?
}

public extension DashboardAppProxyService {
    func launchHosts() async -> [AppProxyLaunchHost] { [] }
    func flowOwners() async -> AppProxyFlowOwners? { nil }
}

/// Mihomo reports the App Proxy provider as the owner of every connection it relays to a
/// `mihomobox-app-*` listener. The provider's owner table names the verified process by the
/// connection's source port; without a match the App Proxy application title is used.
enum AppProxyAttribution {
    static let inboundPrefix = "mihomobox-app-"
    static func process(inboundName: String, sourcePort: String, network: String,
                        owners: AppProxyFlowOwners?, applications: [AppProxyEntry]) -> (process: String, path: String?)? {
        guard inboundName.hasPrefix(inboundPrefix) else { return nil }
        if let port = UInt16(sourcePort), let owner = owners?.owner(port: port, udp: network.lowercased() == "udp") {
            return ((owner.path as NSString).lastPathComponent, owner.path)
        }
        let id = String(inboundName.dropFirst(inboundPrefix.count))
        return applications.first { $0.id == id }.map { ($0.title, nil) }
    }
}

protocol AppProxyRoutingGateway: Sendable {
    func fetchAppProxyRouting() async throws -> AppProxyRoutingState
    func fetchProxies() async throws -> ControllerProxyCatalog
    func setAppProxyRouting(_ update: AppProxyRoutingUpdate) async throws -> AppProxyRoutingState
}
extension ControlGateway: AppProxyRoutingGateway {}

@MainActor
public final class AppProxyStore: ObservableObject {
    @Published public var draft = AppProxySettings()
    @Published public private(set) var routing: AppProxyRoutingState?
    @Published public private(set) var nodes: [String] = []
    @Published public private(set) var groups: [String] = []
    @Published public private(set) var extensionStatus = AppProxyExtensionStatus(available: false)
    @Published public private(set) var error: String?
    @Published public private(set) var refreshing = false
    @Published public private(set) var scanning = false
    @Published public private(set) var editingApplications = false
    @Published public private(set) var mutating = false
    @Published public private(set) var hasConflict = false
    @Published public private(set) var discoveryError: String?
    private var discoveredApplications: [AppProxyEntry]?
    private var discoveryGeneration = 0
    private var discoveredAt = Date.distantPast
    /// Display-only attribution for App Proxy connections; refreshed at most once a second.
    public private(set) var flowOwners: AppProxyFlowOwners?
    private var flowOwnersFetchedAt = Date.distantPast
    private var fetchingFlowOwners = false
    private let gateway: any AppProxyRoutingGateway
    public convenience init() { self.init(gateway: ControlGateway()) }
    init(gateway: any AppProxyRoutingGateway) { self.gateway = gateway }
    private var hasLoadedRouting = false
    private var preview = false
    private var service: (any DashboardAppProxyService)?

    public var dirty: Bool { draft != routing?.settings }
    public var busy: Bool { mutating || editingApplications }
    public var hasExecutableInventory: Bool { discoveredApplications == draft.applications }
    public var changedApplicationCount: Int {
        let saved = routing?.settings ?? .init(applications: [])
        return Set(draft.applications.map(\.id) + saved.applications.map(\.id)).filter { id in
            draft.applications.first { $0.id == id } != saved.applications.first { $0.id == id }
                || draft.routes[id] != saved.routes[id]
        }.count
    }
    public func discardChanges() {
        guard !busy, let routing else { return }
        draft = routing.settings; hasConflict = false; error = nil
    }
    public func selectTarget(_ target: String, for applicationID: String) {
        guard !busy, draft.applications.contains(where: { $0.id == applicationID }) else { return }
        draft.routes[applicationID] = target
    }
    public func selectTargetForAll(_ target: String) {
        guard !busy else { return }
        draft.routes = Dictionary(uniqueKeysWithValues: draft.applications.map { ($0.id, target) })
    }
    public func setBypassCIDRs(_ cidrs: [String]) throws {
        guard !busy, !refreshing, !extensionStatus.enabled, !hasConflict, routing != nil else {
            throw AppProxySettingsError.staleState
        }
        let policy = AppProxyBypassPolicy(cidrs: cidrs)
        try policy.validate()
        draft.bypass = policy
    }
    public var valid: Bool {
        (draft.applications.isEmpty || !draft.routes.isEmpty) && (try? draft.validate()) != nil
          && draft.routes.values.allSatisfy { nodes.contains($0) || groups.contains($0) }
    }
    public func configure(_ service: any DashboardAppProxyService) { self.service = service }

    func loadPreviewFixtures() {
        preview = true
        nodes = ["Tokyo · 32 ms", "Singapore · 48 ms", "Los Angeles · 126 ms"]
        groups = ["Proxy", "Automatic"]
        let routes = Dictionary(uniqueKeysWithValues: AppProxyEntry.defaults.enumerated().map { index, app in
            (app.id, nodes[index % nodes.count])
        })
        routing = .init(settings: .init(routes: routes), profile: "Preview.yaml", revision: "preview")
        draft = routing!.settings
        discoveredApplications = draft.applications
        let counts = ["chatgpt": 45, "claude": 24, "codex_cli": 1, "claude_cli": 1]
        let executables = draft.applications.flatMap { app in
            (0..<counts[app.id, default: 0]).map { index in
                AppProxyExecutable(applicationID: app.id,
                    path: "/Applications/Preview/\(app.title)/Executable-\(index + 1)",
                    signingIdentifier: "preview.\(app.id).\(index + 1)",
                    teamIdentifier: "PREVIEW", requirement: "identifier \"preview.\(app.id).\(index + 1)\"")
            }
        }
        extensionStatus = .init(available: true, enabled: true, connected: true,
                                targetCounts: counts, executables: executables)
        extensionStatus.launchHosts = ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                                       "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                                       "/usr/libexec/sshd-session"].map(AppProxyLaunchHost.init(path:))
    }

    public func refresh() async {
        guard !preview, !refreshing, !busy else { return }
        refreshing = true
        error = nil
        let previous = routing
        let preserveDraft = dirty
        do {
            async let stateRequest = gateway.fetchAppProxyRouting()
            async let catalogRequest = gateway.fetchProxies()
            let (state, catalog) = try await (stateRequest, catalogRequest)
            async let statusRequest = service?.status(settings: state.settings)
            let allowed = catalog.proxies.filter { key, value in
                !key.hasPrefix("mihomobox-app-")
                  && !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL"].contains(key.uppercased())
                  && !["direct", "reject", "pass", "passrule", "compatible"].contains(value.type.lowercased())
            }
            nodes = allowed.filter { $0.value.all.isEmpty }.keys.sorted()
            groups = allowed.filter { !$0.value.all.isEmpty }.keys.sorted()
            // Editing remains responsive during reads. Never replace a draft
            // changed before or during this refresh with an older response.
            let keepDraft = hasLoadedRouting && (preserveDraft || dirty)
            if keepDraft, previous != state { hasConflict = true }
            routing = state
            hasLoadedRouting = true
            if !keepDraft { draft = state.settings; hasConflict = false }
            do { updateStatus(try await statusRequest ?? .init(available: false)) }
            catch { self.error = error.localizedDescription }
        } catch {
            // Preserve visible data on transient failure, but invalidate writes.
            routing = nil
            self.error = error.localizedDescription
        }
        refreshing = false
        await refreshExecutables()
    }

    private func updateStatus(_ status: AppProxyExtensionStatus) {
        var status = status
        status.executables = extensionStatus.executables
        status.targetCounts = extensionStatus.targetCounts
        status.launchHosts = extensionStatus.launchHosts
        extensionStatus = status
    }

    private func updateExecutables(_ executables: [AppProxyExecutable], applications: [AppProxyEntry]) {
        extensionStatus.executables = executables
        extensionStatus.targetCounts = Dictionary(grouping: executables, by: \.applicationID).mapValues(\.count)
        discoveredApplications = applications
        discoveredAt = Date()
        discoveryError = nil
    }

    /// This cache is display-only. Activation always revalidates signatures.
    public func refreshExecutables(force: Bool = false) async {
        guard !preview, !scanning, !busy, let service,
              force || !hasExecutableInventory || Date().timeIntervalSince(discoveredAt) > 30 else { return }
        scanning = true
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let applications = draft.applications
        defer { scanning = false }
        do {
            async let hosts = service.launchHosts()
            let executables = try await service.discoverExecutables(applications: applications)
            let launchHosts = await hosts
            guard generation == discoveryGeneration, applications == draft.applications else { return }
            updateExecutables(executables, applications: applications)
            extensionStatus.launchHosts = launchHosts
        } catch {
            guard generation == discoveryGeneration, applications == draft.applications else { return }
            discoveryError = error.localizedDescription
        }
    }

    public func refreshFlowOwners() async {
        guard !preview, !fetchingFlowOwners, let service, Date().timeIntervalSince(flowOwnersFetchedAt) >= 1 else { return }
        fetchingFlowOwners = true
        defer { fetchingFlowOwners = false; flowOwnersFetchedAt = Date() }
        flowOwners = await service.flowOwners()
    }

    public func addApplication() async {
        guard let service else { return }
        await add { port in try await service.chooseApplication(port: port) }
    }

    /// Adds a dropped or typed `.app` bundle or executable without a file picker.
    public func addApplication(path text: String) async {
        let path = Self.normalizedPath(text)
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              directory.boolValue ? url.pathExtension == "app" : FileManager.default.isExecutableFile(atPath: url.path) else {
            error = "Enter the absolute path of a signed .app or executable file."
            return
        }
        guard !draft.applications.contains(where: { $0.path == url.path }) else {
            error = "\(url.path) is already in the list."
            return
        }
        let title = url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        await add { port in .init(id: "app_" + UUID().uuidString.lowercased(), title: title, path: url.path, port: port) }
    }

    /// The Team ID of a dropped app or executable, read from its code signature.
    public nonisolated static func teamIdentifier(ofCodeAt path: String) -> String? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Accepts typed paths, quoted paths, `~` and dropped `file://` URLs.
    public nonisolated static func normalizedPath(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL { value = url.path }
        return (value as NSString).expandingTildeInPath
    }

    private func add(_ makeEntry: (UInt16) async throws -> AppProxyEntry?) async {
        guard !busy, !refreshing, !extensionStatus.enabled, let service,
              let port = (UInt16(17975)...UInt16(18002)).first(where: { value in !draft.applications.contains { $0.port == value } }),
              draft.applications.count < 32 else { return }
        editingApplications = true; defer { editingApplications = false }
        do {
            guard let entry = try await makeEntry(port) else { return }
            var candidate = draft
            candidate.applications.append(entry)
            // Discover before accepting: overlapping signed executables cannot
            // silently inherit one of two conflicting application routes.
            let executables = try await service.discoverExecutables(applications: candidate.applications)
            discoveryGeneration += 1
            draft = candidate
            updateExecutables(executables, applications: candidate.applications)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func removeApplication(_ id: String) {
        guard !busy, !refreshing, !extensionStatus.enabled else { return }
        draft.applications.removeAll { $0.id == id }; draft.routes.removeValue(forKey: id)
    }

    public func chooseExecutable() async throws -> String? {
        guard !busy, !refreshing, !extensionStatus.enabled, let service else { throw AppProxySettingsError.staleState }
        editingApplications = true; defer { editingApplications = false }
        return try await service.chooseExecutable()
    }

    /// Edit membership in the draft; Apply persists it through authenticated XPC.
    public func setExecutablePaths(_ paths: [String], for applicationID: String) async throws {
        guard let entry = draft.applications.first(where: { $0.id == applicationID }) else { throw AppProxySettingsError.staleState }
        try await setPolicy(executablePaths: paths, teamIdentifiers: entry.teamIdentifiers,
                            directories: entry.directories, for: applicationID)
    }

    /// Exact CLIs, whole Team IDs and whole directories for one application; validated by a fresh scan.
    /// `capturesLaunchedCLIs` is kept when nil.
    public func setPolicy(executablePaths paths: [String], teamIdentifiers teams: [String], directories: [String],
                          capturesLaunchedCLIs: Bool? = nil, for applicationID: String) async throws {
        guard !busy, !refreshing, !extensionStatus.enabled, !hasConflict, routing != nil, let service,
              let index = draft.applications.firstIndex(where: { $0.id == applicationID }) else {
            throw AppProxySettingsError.staleState
        }
        editingApplications = true; defer { editingApplications = false }
        var candidate = draft
        candidate.applications[index].executablePaths = paths
        candidate.applications[index].teamIdentifiers = teams.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        // A typed folder may carry a trailing slash or `..`; executables must already be exact.
        candidate.applications[index].directories = directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if let capturesLaunchedCLIs { candidate.applications[index].capturesLaunchedCLIs = capturesLaunchedCLIs }
        try AppProxySettings(applications: candidate.applications).validate()
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        candidate.applications[index].executablePaths = paths.map(canonical)
        candidate.applications[index].directories = directories.map(canonical)
        try AppProxySettings(applications: candidate.applications).validate()
        let executables = try await service.discoverExecutables(applications: candidate.applications)
        discoveryGeneration += 1
        draft = candidate
        updateExecutables(executables, applications: candidate.applications)
        error = nil
    }

    public func restoreDefaults() {
        guard !busy, !refreshing, !extensionStatus.enabled else { return }
        for entry in AppProxyEntry.defaults where !draft.applications.contains(where: { $0.id == entry.id }) {
            guard draft.applications.count < 32 else { break }
            draft.applications.append(entry)
        }
    }

    public func reset() async throws {
        guard !preview else { return }
        guard !busy, !refreshing, let routing, !extensionStatus.enabled else { throw AppProxySettingsError.staleState }
        mutating = true; defer { mutating = false }
        do {
            let state = try await gateway.setAppProxyRouting(.init(settings: .init(), expectedRevision: routing.revision))
            self.routing = state; draft = state.settings; error = nil
        } catch {
            self.routing = nil; self.error = error.localizedDescription; throw error
        }
    }

    public func apply() async throws {
        guard !preview else { return }
        guard !busy, !refreshing, !hasConflict else { throw AppProxySettingsError.staleState }
        guard let routing, valid else { throw AppProxySettingsError.invalidRoutes }
        guard !extensionStatus.enabled || (routing.settings.applications == draft.applications
            && routing.settings.bypass == draft.bypass) else { throw AppProxySettingsError.staleState }
        guard dirty else { return }
        mutating = true; defer { mutating = false }
        do {
            if routing.settings.applications != draft.applications, let service {
                let applications = draft.applications
                let executables = try await service.discoverExecutables(applications: applications)
                discoveryGeneration += 1
                updateExecutables(executables, applications: applications)
            }
            let submitted = draft
            let result = try await gateway.setAppProxyRouting(.init(settings: submitted, expectedRevision: routing.revision))
            // An older daemon may decode but silently discard new membership fields.
            guard result.settings == submitted, result.profile == routing.profile else {
                throw AppProxySettingsError.staleState
            }
            self.routing = result; draft = result.settings; error = nil
        } catch {
            // The reply may have been lost after commit; discard stale state
            // and require a fresh read before another write or enable.
            self.routing = nil; self.error = error.localizedDescription
            throw error
        }
    }

    public func setApplicationEnabled(_ id: String, enabled: Bool) async throws {
        guard !preview else { return }
        guard !busy, !refreshing, !hasConflict, !dirty, valid, let service, let routing,
              routing.settings.applications.contains(where: { $0.id == id }),
              try await gateway.fetchAppProxyRouting() == routing else { throw AppProxySettingsError.staleState }
        mutating = true; defer { mutating = false }
        do {
            try await service.setApplicationEnabled(id, enabled: enabled, settings: routing.settings)
            updateStatus(try await service.status(settings: routing.settings)); error = nil
        } catch {
            if let status = try? await service.status(settings: routing.settings) { updateStatus(status) }
            self.error = error.localizedDescription; throw error
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !preview else { return }
        guard !busy, !refreshing else { throw AppProxySettingsError.staleState }
        guard let service else { throw AppProxySettingsError.invalidRoutes }
        mutating = true; defer { mutating = false }
        if enabled {
            guard !hasConflict, let routing, !draft.routes.isEmpty, !dirty, valid,
                  try await gateway.fetchAppProxyRouting() == routing else { throw AppProxySettingsError.staleState }
        }
        do {
            try await service.setEnabled(enabled, settings: routing?.settings ?? draft)
            updateStatus(try await service.status(settings: routing?.settings ?? draft))
            error = nil
        } catch {
            if let status = try? await service.status(settings: routing?.settings ?? draft) { updateStatus(status) }
            self.error = error.localizedDescription
            throw error
        }
    }
}
