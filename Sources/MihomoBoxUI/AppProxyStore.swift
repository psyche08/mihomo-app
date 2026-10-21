import Foundation
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

public struct AppProxyExtensionStatus: Equatable, Sendable {
    public var available: Bool
    public var enabled: Bool
    public var connected: Bool
    public var targetCounts: [String: Int]
    public var executables: [AppProxyExecutable]
    public init(available: Bool, enabled: Bool = false, connected: Bool = false, targetCounts: [String: Int] = [:], executables: [AppProxyExecutable] = []) {
        self.available = available; self.enabled = enabled; self.connected = connected; self.targetCounts = targetCounts
        self.executables = executables
    }
}

@MainActor
public protocol DashboardAppProxyService: AnyObject {
    func status(applications: [AppProxyEntry]) async throws -> AppProxyExtensionStatus
    func setEnabled(_ enabled: Bool, settings: AppProxySettings) async throws
    func chooseApplication(port: UInt16) async throws -> AppProxyEntry?
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
    private let gateway: any AppProxyRoutingGateway
    public convenience init() { self.init(gateway: ControlGateway()) }
    init(gateway: any AppProxyRoutingGateway) { self.gateway = gateway }
    private var preview = false
    private var service: (any DashboardAppProxyService)?

    public var dirty: Bool { draft != routing?.settings }
    public var valid: Bool {
        (draft.applications.isEmpty || !draft.routes.isEmpty) && (try? draft.validate()) != nil
          && draft.routes.values.allSatisfy { nodes.contains($0) || groups.contains($0) }
    }
    public func configure(_ service: any DashboardAppProxyService) { self.service = service }

    func loadPreviewFixtures() {
        preview = true
        nodes = ["Tokyo · 32 ms", "Singapore · 48 ms", "Los Angeles · 126 ms"]
        groups = ["Proxy", "Automatic"]
        let routes = Dictionary(uniqueKeysWithValues: AppProxyApplication.allCases.enumerated().map { index, app in
            (app.rawValue, nodes[index % nodes.count])
        })
        routing = .init(settings: .init(routes: routes), profile: "Preview.yaml", revision: "preview")
        draft = routing!.settings
        extensionStatus = .init(available: true, enabled: true, connected: true,
                                targetCounts: ["chatgpt": 45, "claude": 24, "codex_cli": 1, "claude_cli": 1])
    }

    public func refresh() async {
        guard !preview, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        error = nil
        do {
            let state = try await gateway.fetchAppProxyRouting()
            let catalog = try await gateway.fetchProxies()
            let allowed = catalog.proxies.filter { key, value in
                !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL"].contains(key.uppercased())
                  && !["direct", "reject", "pass", "passrule", "compatible"].contains(value.type.lowercased())
            }
            nodes = allowed.filter { $0.value.all.isEmpty }.keys.sorted()
            groups = allowed.filter { !$0.value.all.isEmpty }.keys.sorted()
            routing = state; draft = state.settings
            do { extensionStatus = try await service?.status(applications: draft.applications) ?? .init(available: false) }
            catch { self.error = error.localizedDescription }
        } catch {
            routing = nil; nodes = []; groups = []
            self.error = error.localizedDescription
        }
    }

    public func addApplication() async {
        guard !extensionStatus.enabled, let service,
              let port = (UInt16(17975)...UInt16(18002)).first(where: { value in !draft.applications.contains { $0.port == value } }),
              draft.applications.count < 32 else { return }
        refreshing = true; defer { refreshing = false }
        do {
            guard let entry = try await service.chooseApplication(port: port) else { return }
            var candidate = draft
            candidate.applications.append(entry)
            // Discover before accepting: overlapping signed executables cannot
            // silently inherit one of two conflicting application routes.
            let status = try await service.status(applications: candidate.applications)
            draft = candidate; extensionStatus = status; error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func removeApplication(_ id: String) {
        guard !extensionStatus.enabled else { return }
        draft.applications.removeAll { $0.id == id }; draft.routes.removeValue(forKey: id)
    }

    public func restoreDefaults() {
        guard !extensionStatus.enabled else { return }
        for entry in AppProxyEntry.defaults where !draft.applications.contains(where: { $0.id == entry.id }) {
            guard draft.applications.count < 32 else { break }
            draft.applications.append(entry)
        }
    }

    public func reset() async throws {
        guard !preview else { return }
        guard let routing, !extensionStatus.enabled else { throw AppProxySettingsError.staleState }
        do {
            let state = try await gateway.setAppProxyRouting(.init(settings: .init(), expectedRevision: routing.revision))
            self.routing = state; draft = state.settings; error = nil
        } catch {
            self.routing = nil; self.error = error.localizedDescription; throw error
        }
    }

    public func apply() async throws {
        guard !preview else { return }
        guard let routing, valid else { throw AppProxySettingsError.invalidRoutes }
        guard !extensionStatus.enabled || routing.settings.applications == draft.applications else { throw AppProxySettingsError.staleState }
        do {
            if routing.settings.applications != draft.applications {
                extensionStatus = try await service?.status(applications: draft.applications) ?? .init(available: false)
            }
            let result = try await gateway.setAppProxyRouting(.init(settings: draft, expectedRevision: routing.revision))
            self.routing = result; draft = result.settings; error = nil
        } catch {
            // The reply may have been lost after commit; discard stale state
            // and require a fresh read before another write or enable.
            self.routing = nil; self.error = error.localizedDescription
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !preview else { return }
        guard let service else { throw AppProxySettingsError.invalidRoutes }
        if enabled {
            guard let routing, !draft.routes.isEmpty, !dirty, valid,
                  try await gateway.fetchAppProxyRouting() == routing else { throw AppProxySettingsError.staleState }
        }
        do {
            try await service.setEnabled(enabled, settings: routing?.settings ?? draft)
            extensionStatus = try await service.status(applications: draft.applications)
            error = nil
        } catch {
            if let status = try? await service.status(applications: draft.applications) { extensionStatus = status }
            self.error = error.localizedDescription
            throw error
        }
    }
}
