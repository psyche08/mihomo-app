import Foundation

public enum AppProxyApplication: String, Codable, CaseIterable, Sendable, Identifiable {
    case chatgpt, codexCLI = "codex_cli", claude, claudeCLI = "claude_cli", jetbrains
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chatgpt: "ChatGPT / Codex Desktop"
        case .codexCLI: "Codex CLI"
        case .claude: "Claude Desktop"
        case .claudeCLI: "Claude CLI"
        case .jetbrains: "JetBrains IDEs"
        }
    }
    /// Fixed listener ports. Custom applications use 17975...18002.
    public var port: UInt16 {
        switch self {
        case .jetbrains: 17970
        case .chatgpt: 17971
        case .codexCLI: 17972
        case .claude: 17973
        case .claudeCLI: 17974
        }
    }
    /// The four per-binary presets of releases before 1.1.0.
    public static let legacyPresets: [Self] = [.chatgpt, .codexCLI, .claude, .claudeCLI]
}

public struct AppProxyEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The chosen .app or CLI of a custom application; nil for presets.
    public var path: String?
    public var port: UInt16
    /// Publishers of the application's code. The provider routes a flow by the Team ID of its running code.
    public var teamIdentifiers: [String]
    /// Signing identifiers of the application's apps, helpers and CLIs. The OS rules divert exactly these.
    public var signingIdentifiers: [String]
    /// Code folders the provider's sandbox cannot read otherwise (home directory, Homebrew): it gets
    /// read-only grants for them, because NetworkExtension reads a diverted process's code to validate it.
    /// `~/` is the user's home directory. Never a folder holding user data.
    public var directories: [String]
    public init(id: String, title: String, path: String? = nil, port: UInt16, teamIdentifiers: [String] = [],
                signingIdentifiers: [String] = [], directories: [String] = []) {
        self.id = id; self.title = title; self.path = path; self.port = port
        self.teamIdentifiers = teamIdentifiers; self.signingIdentifiers = signingIdentifiers
        self.directories = directories
    }
    private enum CodingKeys: String, CodingKey { case id, title, path, port, teamIdentifiers, signingIdentifiers, directories }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let teams = try values.decodeIfPresent([String].self, forKey: .teamIdentifiers) ?? []
        self.id = id; teamIdentifiers = teams
        title = try values.decode(String.self, forKey: .title)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        port = try values.decode(UInt16.self, forKey: .port)
        let stored = try values.decodeIfPresent([String].self, forKey: .directories) ?? []
        if let identifiers = try values.decodeIfPresent([String].self, forKey: .signingIdentifiers) {
            signingIdentifiers = identifiers; directories = stored
        } else {
            // Settings before policy version 5 listed scanned executables instead. A preset with
            // its Team ID takes the preset's identifiers and code folders; custom applications
            // derive theirs from their chosen path when the rules are built.
            let preset = Self.defaults.first { $0.id == id && $0.teamIdentifiers == teams }
            signingIdentifiers = preset?.signingIdentifiers ?? []
            directories = (preset?.directories ?? []) + stored.filter { !(preset?.directories ?? []).contains($0) }
        }
    }
    public static var defaults: [Self] {
        [.init(id: "chatgpt", title: "OpenAI (ChatGPT / Codex)", port: 17971, teamIdentifiers: ["2DC432GLL2"],
               signingIdentifiers: ["com.openai.codex", "com.openai.chat", "com.openai.codex.helper",
                                    "com.openai.codex.helper.renderer", "com.openai.codex.voice-host", "codex",
                                    "codex-exec-server", "codex-code-mode-host", "node", "node_repl", "extension-host",
                                    "com.openai.sky.CUAService", "org.sparkle-project.DownloaderService", "Autoupdate"],
               directories: ["~/.codex/computer-use", "~/Library/Application Support/Codex/artifact-sessions/runtime-generations",
                             "/opt/homebrew/Caskroom/codex", "/usr/local/Caskroom/codex",
                             "/opt/homebrew/lib/node_modules/@openai/codex", "/usr/local/lib/node_modules/@openai/codex"]),
         .init(id: "claude", title: "Anthropic (Claude)", port: 17973, teamIdentifiers: ["Q6L2SF6YDW"],
               signingIdentifiers: ["com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.helper",
                                    "com.anthropic.claude-code", "ShipIt", "github-mcp-server"],
               directories: ["~/Library/Application Support/Claude/claude-code", "~/.claude/remote/ccd-cli",
                             "~/.local/share/claude/versions", "/opt/homebrew/Caskroom/claude-code",
                             "/usr/local/Caskroom/claude-code"]),
         .init(id: "jetbrains", title: "JetBrains (IntelliJ IDEA / Toolbox)", port: 17970,
               teamIdentifiers: ["2ZEFAR8TH3"], signingIdentifiers: AppProxyEntry.jetBrainsIdentifiers,
               directories: ["~/Applications", "~/Library/Application Support/JetBrains/Toolbox/apps"])]
    }
    /// JetBrains IDE and Toolbox bundle identifiers. They are also launch hosts for terminal CLIs.
    public static let jetBrainsIdentifiers = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.intellij-EAP", "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion",
        "com.jetbrains.rider", "com.jetbrains.rubymine", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip",
        "com.jetbrains.rustrover", "com.jetbrains.dataspell", "com.jetbrains.fleet", "com.jetbrains.toolbox",
        "com.jetbrains.gateway",
    ]
    /// The Team ID policies that replace the four legacy presets. Their routes
    /// carry over; a default without a legacy predecessor needs its own node.
    public static var teamPresetReplacements: [Self] {
        defaults.filter { ["chatgpt", "claude"].contains($0.id) }
    }
    public static var legacyDefaults: [Self] {
        AppProxyApplication.legacyPresets.map { .init(id: $0.rawValue, title: $0.title, port: $0.port) }
    }
    /// A configured folder: absolute, or `~/` relative to the user's home directory.
    public static func isFolderSetting(_ value: String) -> Bool {
        value.hasPrefix("~/") ? AppProxyCode.isFolder("/home" + value.dropFirst()) : AppProxyCode.isFolder(value)
    }
    /// The absolute folder for the user whose home directory is `home`.
    public static func expandFolder(_ value: String, home: String) -> String {
        value.hasPrefix("~/") ? home + value.dropFirst() : value
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
        result.applications = AppProxyEntry.teamPresetReplacements + applications.filter { !oldIDs.contains($0.id) }
        result.routes.removeValue(forKey: "codex_cli")
        result.routes.removeValue(forKey: "claude_cli")
        guard (try? result.validate()) != nil else { return nil }
        return result
    }

    /// The settings without code policy: exactly what AppProxyProfile writes into Mihomo's
    /// configuration. Equal values let a policy-only change skip a runtime restart.
    public var runtimeRouting: AppProxySettings {
        var routing = self
        routing.applications = applications.map {
            var entry = $0
            entry.teamIdentifiers = []; entry.signingIdentifiers = []; entry.directories = []
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
        // A Team ID or folder belongs to exactly one application route.
        let teams = applications.flatMap(\.teamIdentifiers), directories = applications.flatMap(\.directories)
        guard applications.allSatisfy({ $0.teamIdentifiers.count <= 8 && $0.directories.count <= 16 }),
              Set(teams).count == teams.count, Set(directories).count == directories.count,
              teams.allSatisfy(AppProxyCode.isTeamIdentifier), directories.allSatisfy(AppProxyEntry.isFolderSetting)
        else { throw AppProxySettingsError.invalidScopes }
        guard applications.allSatisfy({ entry in
                  entry.signingIdentifiers.count <= 64 && Set(entry.signingIdentifiers).count == entry.signingIdentifiers.count
                    && entry.signingIdentifiers.allSatisfy(AppProxyCode.isSigningIdentifier)
              }), applications.reduce(0, { $0 + $1.signingIdentifiers.count }) <= 256
        else { throw AppProxySettingsError.invalidIdentifiers }
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
    case invalidRoutes, unsupportedProfile, unsupportedRules, staleState, unavailableNode, invalidExecutables, invalidScopes, invalidIdentifiers, overlappingFakeIP
    public var errorDescription: String? {
        switch self {
        case .overlappingFakeIP: "An App Proxy bypass overlaps this profile's Fake-IP range. Remove the overlapping bypass before applying."
        case .invalidExecutables: "App Proxy process routes must be absolute paths without commas or line breaks."
        case .invalidScopes: "Enter 10-character Team IDs (up to 8 per app) and absolute or ~/ folders other than / (up to 16 per app). Each Team ID or folder can belong to only one app."
        case .invalidIdentifiers: "Enter signing identifiers without spaces or quotes (up to 64 per app and 256 in total)."
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

/// Code locations of each active App Proxy application, mirrored into Mihomo's process rules.
/// Connections these processes make outside App Proxy, such as to the macOS system proxy on
/// loopback, which NetworkExtension never diverts, or through TUN, follow the application's
/// sub-rules in Mihomo too. Mihomo matches by path only: it does not check signatures.
/// `paths` are exact executables (`PROCESS-PATH`); `prefixes` are application bundles and
/// vendor code folders, matching every executable below them (`PROCESS-PATH-REGEX`).
public struct AppProxyProcessRoutes: Codable, Equatable, Sendable {
    public static let maximumPaths = 1024
    public var paths: [String: [String]]
    public var prefixes: [String: [String]]
    public init(_ paths: [String: [String]] = [:], prefixes: [String: [String]] = [:]) {
        self.paths = paths; self.prefixes = prefixes
    }
    private enum CodingKeys: String, CodingKey { case paths, prefixes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paths = try values.decode([String: [String]].self, forKey: .paths)
        prefixes = try values.decodeIfPresent([String: [String]].self, forKey: .prefixes) ?? [:]
    }
    public func validate(applications: [AppProxyEntry]) throws {
        let ids = Set(applications.map(\.id))
        guard Set(paths.keys).isSubset(of: ids), Set(prefixes.keys).isSubset(of: ids),
              (paths.values.reduce(0, { $0 + $1.count }) + prefixes.values.reduce(0, { $0 + $1.count })) <= Self.maximumPaths,
              paths.values.allSatisfy({ $0.allSatisfy(Self.isRoutable) }),
              prefixes.values.allSatisfy({ $0.allSatisfy { Self.isRoutable($0) && $0 != "/" } }) else {
            throw AppProxySettingsError.invalidExecutables
        }
    }
    /// A Mihomo classical rule is comma-separated, so a path with a comma cannot be expressed.
    public static func isRoutable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024
            && !path.contains(where: { [",", "\n", "\r", "\0"].contains($0) })
    }
    /// An anchored RE2 pattern for every path below `prefix`.
    public static func pattern(prefix: String) -> String {
        var escaped = ""
        for character in prefix {
            if "\\.+*?()|[]{}^$".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "^" + escaped + "/"
    }
}
