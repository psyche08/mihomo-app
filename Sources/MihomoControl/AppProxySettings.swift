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
    /// Exact CLI scope: these executables only.
    public var executablePaths: [String]
    /// Team scope: all code signed by these Team IDs. Directory scope: all code under these directories.
    public var teamIdentifiers: [String]
    public var directories: [String]
    /// CLIs of other selected applications launched by this one keep their own routes. Off, they connect directly.
    public var capturesLaunchedCLIs: Bool
    public init(id: String, title: String, path: String? = nil, port: UInt16, executablePaths: [String] = [],
                teamIdentifiers: [String] = [], directories: [String] = [], capturesLaunchedCLIs: Bool = true) {
        self.id = id; self.title = title; self.path = path; self.port = port
        self.executablePaths = executablePaths
        self.teamIdentifiers = teamIdentifiers; self.directories = directories
        self.capturesLaunchedCLIs = capturesLaunchedCLIs
    }
    public var scopes: [AppProxyScope] {
        teamIdentifiers.map { .init(category: id, kind: .team, value: $0) }
            + directories.map { .init(category: id, kind: .directory, value: $0) }
    }
    private enum CodingKeys: String, CodingKey { case id, title, path, port, executablePaths, teamIdentifiers, directories, capturesLaunchedCLIs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        port = try values.decode(UInt16.self, forKey: .port)
        executablePaths = try values.decodeIfPresent([String].self, forKey: .executablePaths) ?? []
        teamIdentifiers = try values.decodeIfPresent([String].self, forKey: .teamIdentifiers) ?? []
        directories = try values.decodeIfPresent([String].self, forKey: .directories) ?? []
        capturesLaunchedCLIs = try values.decodeIfPresent(Bool.self, forKey: .capturesLaunchedCLIs) ?? true
    }
    public static var defaults: [Self] {
        [.init(id: "chatgpt", title: "OpenAI (ChatGPT / Codex)", port: 17971, teamIdentifiers: ["2DC432GLL2"]),
         .init(id: "claude", title: "Anthropic (Claude)", port: 17973, teamIdentifiers: ["Q6L2SF6YDW"])]
    }
    public static var legacyDefaults: [Self] {
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
    /// Merge only untouched historical presets with compatible routes. Never discard custom scopes
    /// or choose between different desktop/CLI nodes. Applying still requires an explicit action.
    public var teamPresetMigration: Self? {
        let old = AppProxyEntry.legacyDefaults
        guard old.allSatisfy({ applications.contains($0) }) else { return nil }
        for pair in [("chatgpt", "codex_cli"), ("claude", "claude_cli")] {
            guard routes[pair.0] == routes[pair.1] else { return nil }
        }
        var result = self
        let oldIDs = Set(old.map(\.id))
        result.applications = AppProxyEntry.defaults + applications.filter { !oldIDs.contains($0.id) }
        result.routes.removeValue(forKey: "codex_cli")
        result.routes.removeValue(forKey: "claude_cli")
        guard (try? result.validate()) != nil else { return nil }
        return result
    }

    /// The settings without code scopes or OS-rule options: exactly what AppProxyProfile writes into Mihomo's
    /// configuration. Equal values let a scope-only change skip a runtime restart.
    public var runtimeRouting: AppProxySettings {
        var routing = self
        routing.applications = applications.map {
            var entry = $0
            entry.executablePaths = []; entry.teamIdentifiers = []; entry.directories = []
            entry.capturesLaunchedCLIs = true
            return entry
        }
        return routing
    }
    private enum CodingKeys: String, CodingKey { case routes, applications, bypass }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        routes = try values.decode([String: String].self, forKey: .routes)
        applications = try values.decodeIfPresent([AppProxyEntry].self, forKey: .applications) ?? (routes.isEmpty ? AppProxyEntry.defaults : AppProxyEntry.legacyDefaults)
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
        // A Team ID or directory belongs to exactly one application route.
        let teams = applications.flatMap(\.teamIdentifiers), directories = applications.flatMap(\.directories)
        guard teams.count + directories.count <= 64,
              applications.allSatisfy({ $0.teamIdentifiers.count <= 8 && $0.directories.count <= 16 }),
              Set(teams).count == teams.count, Set(directories).count == directories.count,
              teams.allSatisfy(AppProxyScope.isTeamIdentifier), directories.allSatisfy(AppProxyScope.isDirectory)
        else { throw AppProxySettingsError.invalidScopes }
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
    case invalidRoutes, unsupportedProfile, unsupportedRules, staleState, unavailableNode, invalidExecutables, invalidScopes, overlappingFakeIP
    public var errorDescription: String? {
        switch self {
        case .overlappingFakeIP: "An App Proxy bypass overlaps this profile's Fake-IP range. Remove the overlapping bypass before applying."
        case .invalidExecutables: "Enter unique absolute executable paths (up to 32 per app and 128 total). Each executable can belong to only one app."
        case .invalidScopes: "Enter 10-character Team IDs (up to 8 per app) and absolute directories other than / (up to 16 per app). Each Team ID or directory can belong to only one app."
        case .unavailableNode: "An App Proxy target is missing or does not currently resolve to a remote proxy. Refresh the node list and choose another target."
        case .invalidRoutes: "Choose a proxy node or proxy group for each application."
        case .unsupportedProfile: "App Proxy requires a single block-style profile without custom listeners or conflicting application listener ports."
        case .unsupportedRules: "App Proxy requires unambiguous block-style rules and sub-rules with one rule string per line. Expand rule aliases or inline lists before applying."
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

/// Verified executable paths of each active App Proxy application. Connections these
/// processes make outside App Proxy, such as to the macOS system proxy on loopback, which
/// NetworkExtension never diverts, follow the application's sub-rules in Mihomo too. The
/// match is by path only: Mihomo does not check signatures.
public struct AppProxyProcessRoutes: Codable, Equatable, Sendable {
    public static let maximumPaths = 1024
    public var paths: [String: [String]]
    public init(_ paths: [String: [String]] = [:]) { self.paths = paths }
    public func validate(applications: [AppProxyEntry]) throws {
        guard Set(paths.keys).isSubset(of: Set(applications.map(\.id))),
              paths.values.reduce(0, { $0 + $1.count }) <= Self.maximumPaths,
              paths.values.allSatisfy({ $0.allSatisfy(Self.isRoutable) }) else { throw AppProxySettingsError.invalidExecutables }
    }
    /// A Mihomo classical rule is comma-separated, so a path with a comma cannot be expressed.
    public static func isRoutable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024
            && !path.contains(where: { [",", "\n", "\r", "\0"].contains($0) })
    }
}
