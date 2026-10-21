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

/// Empty routes means unconfigured. A configured set is complete, so an
/// unidentified/missing category can never fall back to a shared proxy.
public struct AppProxySettings: Codable, Equatable, Sendable {
    public var routes: [String: String]
    public init(routes: [String: String] = [:]) { self.routes = routes }
    public func validateRoutes(in snapshot: ControllerRouteSnapshot) throws {
        try validate()
        guard routes.values.allSatisfy({ snapshot.routesThroughRemoteProxy($0) }) else {
            throw AppProxySettingsError.unavailableNode
        }
    }
    public func validate() throws {
        guard routes.isEmpty || Set(routes.keys) == Set(AppProxyApplication.allCases.map(\.rawValue)),
              routes.values.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 1024
                    && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"].contains(value.uppercased())
              }) else { throw AppProxySettingsError.invalidRoutes }
    }
}

public enum AppProxySettingsError: LocalizedError {
    case invalidRoutes, unsupportedProfile, staleState, unavailableNode
    public var errorDescription: String? {
        switch self {
        case .unavailableNode: "An App Proxy target is missing or does not currently resolve to a remote proxy. Refresh the node list and choose another target."
        case .invalidRoutes: "Choose a proxy node or proxy group for each application."
        case .unsupportedProfile: "App Proxy requires a single block-style profile without custom listeners or conflicting ports (17971–17974)."
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
