import Foundation

public enum AppProxyApplication: String, Codable, CaseIterable, Sendable, Identifiable {
    case chatgpt, codexCLI = "codex_cli", claude, claudeCLI = "claude_cli"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chatgpt: "ChatGPT / Codex Desktop"
        case .codexCLI: "Codex CLI"
        case .claude: "Claude Desktop"
        case .claudeCLI: "Claude CLI"
        }
    }
    public var port: UInt16 {
        switch self {
        case .chatgpt: 17971
        case .codexCLI: 17972
        case .claude: 17973
        case .claudeCLI: 17974
        }
    }
}

public struct AppProxyEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var path: String?
    public var port: UInt16
    public var executablePaths: [String]
    public init(id: String, title: String, path: String? = nil, port: UInt16, executablePaths: [String] = []) {
        self.id = id; self.title = title; self.path = path; self.port = port
        self.executablePaths = executablePaths
    }
    private enum CodingKeys: String, CodingKey { case id, title, path, port, executablePaths }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        port = try values.decode(UInt16.self, forKey: .port)
        executablePaths = try values.decodeIfPresent([String].self, forKey: .executablePaths) ?? []
    }
    public static var defaults: [Self] {
        AppProxyApplication.allCases.map { .init(id: $0.rawValue, title: $0.title, port: $0.port) }
    }
}

/// Empty routes means unconfigured. A configured set is complete, so an
/// unidentified/missing category can never fall back to a shared proxy.
public struct AppProxySettings: Codable, Equatable, Sendable {
    public var routes: [String: String]
    public var applications: [AppProxyEntry]
    public var bypass: AppProxyBypassPolicy
    public init(routes: [String: String] = [:], applications: [AppProxyEntry] = AppProxyEntry.defaults,
                bypass: AppProxyBypassPolicy = .init()) {
        self.routes = routes; self.applications = applications
        self.bypass = bypass
    }
    private enum CodingKeys: String, CodingKey { case routes, applications, bypass }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        routes = try values.decode([String: String].self, forKey: .routes)
        applications = try values.decodeIfPresent([AppProxyEntry].self, forKey: .applications) ?? AppProxyEntry.defaults
        bypass = try values.decodeIfPresent(AppProxyBypassPolicy.self, forKey: .bypass) ?? .init()
    }
    public func validateRoutes(in snapshot: ControllerRouteSnapshot) throws {
        try validate()
        guard routes.values.allSatisfy({ snapshot.routesThroughRemoteProxy($0) }) else {
            throw AppProxySettingsError.unavailableNode
        }
    }
    public func validate() throws {
        try bypass.validate()
        let executables = applications.flatMap(\.executablePaths)
        guard executables.count <= 128, Set(executables).count == executables.count,
              applications.allSatisfy({ $0.executablePaths.count <= 32 }),
              executables.allSatisfy({ path in
                  path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096
                    && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && URL(fileURLWithPath: path).standardizedFileURL.path == path
              }) else { throw AppProxySettingsError.invalidExecutables }
        guard applications.count <= 32,
              Set(applications.map(\.id)).count == applications.count,
              Set(applications.map(\.port)).count == applications.count,
              applications.allSatisfy({ entry in
                  guard !entry.title.isEmpty, entry.title.utf8.count <= 256,
                        !entry.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
                  if let builtin = AppProxyApplication(rawValue: entry.id) {
                      return entry.path == nil && entry.port == builtin.port
                  }
                  guard entry.id.hasPrefix("app_"), UUID(uuidString: String(entry.id.dropFirst(4))) != nil,
                        (17975...18002).contains(entry.port), let path = entry.path,
                        path.hasPrefix("/"), path.utf8.count <= 4096,
                        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                        URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
                  return true
              }),
              routes.isEmpty || Set(routes.keys) == Set(applications.map(\.id)),
              routes.values.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 1024
                    && !value.hasPrefix("mihomobox-app-")
                    && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"].contains(value.uppercased())
              }) else { throw AppProxySettingsError.invalidRoutes }
    }
}

public enum AppProxySettingsError: LocalizedError {
    case invalidRoutes, unsupportedProfile, staleState, unavailableNode, invalidExecutables, overlappingFakeIP
    public var errorDescription: String? {
        switch self {
        case .overlappingFakeIP: "An App Proxy bypass overlaps this profile's Fake-IP range. Remove the overlapping bypass before applying."
        case .invalidExecutables: "Enter unique absolute executable paths (up to 32 per app and 128 total). Each executable can belong to only one app."
        case .unavailableNode: "An App Proxy target is missing or does not currently resolve to a remote proxy. Refresh the node list and choose another target."
        case .invalidRoutes: "Choose a proxy node or proxy group for each application."
        case .unsupportedProfile: "App Proxy requires a single block-style profile without custom listeners or conflicting application listener ports."
        case .staleState: "The active profile or App Proxy settings changed. Refresh before applying."
        }
    }
}

public struct AppProxyRoutingState: Codable, Equatable, Sendable {
    public var settings: AppProxySettings
    public var profile: String
    public var revision: String
    public init(settings: AppProxySettings, profile: String, revision: String) {
        self.settings = settings; self.profile = profile; self.revision = revision
    }
}

public struct AppProxyRoutingUpdate: Codable, Sendable {
    public var settings: AppProxySettings
    public var expectedRevision: String
    public init(settings: AppProxySettings, expectedRevision: String) {
        self.settings = settings; self.expectedRevision = expectedRevision
    }
}
