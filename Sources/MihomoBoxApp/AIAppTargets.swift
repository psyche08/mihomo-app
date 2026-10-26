import Foundation
import NetworkExtension
import Security
import MihomoControl

/// Discover executable identities, never process names or command-line arguments.
/// Exact paths keep generic identifiers such as `node` scoped to the chosen app.
struct AIAppTargets {
    struct Target {
        let identity: AppProxyCodeIdentity
        var id: String { identity.id }
        var requirement: String { identity.requirement }
        var path: String { identity.path }
        var category: String { identity.category }
        var team: String? { identity.team }
        var rule: NEAppRule {
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: requirement)
            rule.matchPath = path
            return rule
        }
        var record: [String: String] {
            ["id": id, "requirement": requirement, "path": path, "category": category]
        }
    }
    struct DiscoveryIssue: Equatable, Sendable {
        let category: String
        let failure: AppProxyIdentityFailure
    }
    let issues: [DiscoveryIssue]
    let targets: [Target]
    let rules: [NEAppRule]

    init(ruleSet: String = "all", requireAll: Bool = true, applications: [AppProxyEntry] = AppProxyEntry.defaults, homeDirectory: URL? = nil, applicationDirectories: [URL]? = nil) throws {
        try AppProxySettings(applications: applications).validate()
        let selected = Set(applications.map(\.id))
        let fm = FileManager.default
        let home = homeDirectory ?? fm.homeDirectoryForCurrentUser
        var issues: [DiscoveryIssue] = []
        var overflow = false
        var found: [String: Target] = [:]
        var duplicate = false
        func add(_ url: URL, category: String, team: String?, identifier: String? = nil) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath()
            let target: Target
            do { target = Target(identity: try AppProxyCodeIdentity.inspect(path: path.path, category: category, team: team, identifier: identifier)) }
            catch {
                if issues.count < 64 { issues.append(.init(category: category, failure: error as? AppProxyIdentityFailure ?? .signature)) }
                return
            }
            if let prior = found[path.path], prior.category != category { duplicate = true; return }
            found[path.path] = target
        }
        func scan(_ root: URL, category: String, team: String?, identifier: String? = nil, excludingAppleCode: Bool = false) {
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path == root.standardizedFileURL.path else {
                if issues.count < 64 { issues.append(.init(category: category, failure: .escapedPath)) }; return
            }
            guard let files = fm.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { return }
            var visited = 0
            for case let url as URL in files {
                visited += 1
                if visited > 20000 || found.count > 512 { overflow = true; break }
                if files.level > 16 { files.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    if issues.count < 64 { issues.append(.init(category: category, failure: .escapedPath)) }
                    files.skipDescendants(); continue
                }
                let path = url.standardizedFileURL.resolvingSymlinksInPath()
                guard path.path.hasPrefix(canonical.path + "/"),
                      fm.isExecutableFile(atPath: path.path),
                      !["dylib", "node"].contains(path.pathExtension),
                      let file = try? FileHandle(forReadingFrom: path) else { continue }
                let header = try? file.read(upToCount: 4)
                try? file.close()
                guard let header, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xce,0xfa,0xed,0xfe]),
                                   Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca])].contains(header),
                      !(excludingAppleCode && Self.isAppleCode(path)) else { continue }
                add(path, category: category, team: team, identifier: identifier)
            }
        }
        for (name, category, team) in [("ChatGPT.app", "chatgpt", "2DC432GLL2"),
                                        ("Codex.app", "chatgpt", "2DC432GLL2"),
                                        ("Claude.app", "claude", "Q6L2SF6YDW")] {
            guard selected.contains(category) else { continue }
            for base in applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
                scan(base.appendingPathComponent(name), category: category, team: team)
            }
        }
        if selected.contains("chatgpt") {
        scan(home.appendingPathComponent(".codex/computer-use"), category: "chatgpt", team: "2DC432GLL2")
        let generations = home.appendingPathComponent("Library/Application Support/Codex/artifact-sessions/runtime-generations")
        for generation in (try? fm.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil)) ?? [] {
            scan(generation.appendingPathComponent("runtime/bin"), category: "chatgpt", team: "2DC432GLL2")
        }
        }
        // Desktop downloads and remote runtimes are independently versioned code trees.
        // Do not auto-trust remote/srv ad-hoc servers; explicit enrollment pins their hash.
        for (relative, category) in Self.claudeCodeRoots {
            guard selected.contains(category) else { continue }
            scan(home.appendingPathComponent(relative), category: category, team: "Q6L2SF6YDW",
                 identifier: "com.anthropic.claude-code")
        }
        for (name, category, team) in [("codex", "codex_cli", "2DC432GLL2"),
                                        ("claude", "claude_cli", "Q6L2SF6YDW")] {
            guard selected.contains(category) else { continue }
            for base in ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path] {
                add(URL(fileURLWithPath: base).appendingPathComponent(name), category: category, team: team,
                    identifier: name == "claude" ? "com.anthropic.claude-code" : nil)
            }
        }
        var toolCategories: Set<String> = ["codex_cli", "claude_cli"]
        var explicitToolPaths = Set<String>()
        let cliDirectories = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
                              home.appendingPathComponent(".local/bin")]
        for entry in applications {
            // Team scope: apps and conventional CLIs signed by the team. Code elsewhere needs a directory scope.
            for team in entry.teamIdentifiers {
                for base in applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
                    for app in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                        guard let executable = Bundle(url: app)?.executableURL, Self.teamIdentifier(executable) == team else { continue }
                        scan(app, category: entry.id, team: team)
                    }
                }
                for base in cliDirectories {
                    for file in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                        let url = file.standardizedFileURL.resolvingSymlinksInPath()
                        guard fm.isExecutableFile(atPath: url.path), Self.teamIdentifier(url) == team else { continue }
                        add(url, category: entry.id, team: team)
                        explicitToolPaths.insert(url.path)
                    }
                }
            }
            // Directory scope: every signed executable below it; code outside an .app is a CLI tool.
            // Apple's own code is skipped: its requirement also matches the system original, so the
            // OS rule would capture e.g. /usr/bin/curl and the provider would close it as out of scope.
            for directory in entry.directories {
                scan(URL(fileURLWithPath: directory, isDirectory: true), category: entry.id, team: nil, excludingAppleCode: true)
                for target in found.values where target.category == entry.id && target.path.hasPrefix(directory + "/")
                    && !target.path.contains(".app/") { explicitToolPaths.insert(target.path) }
            }
            for path in entry.executablePaths {
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fm.isExecutableFile(atPath: url.path),
                      Self.inspect(url, category: entry.id, team: nil) != nil else { throw Failure.unsignedTarget }
                add(url, category: entry.id, team: nil)
                explicitToolPaths.insert(url.path)
            }
            guard let path = entry.path else { continue }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if url.pathExtension == "app" {
                guard let executable = Bundle(url: url)?.executableURL,
                      let main = Self.inspect(executable, category: entry.id, team: nil) else { throw Failure.unsignedTarget }
                scan(url, category: entry.id, team: main.team)
            } else {
                guard fm.isExecutableFile(atPath: url.path),
                      Self.inspect(url, category: entry.id, team: nil) != nil else { throw Failure.unsignedTarget }
                add(url, category: entry.id, team: nil)
                toolCategories.insert(entry.id)
            }
        }
        guard !overflow else { throw Failure.tooManyTargets }
        guard !duplicate else { throw Failure.duplicateTarget }
        let tools = found.values.filter { toolCategories.contains($0.category) || $0.id == "com.anthropic.claude-code" || explicitToolPaths.contains($0.path) }.sorted { $0.path < $1.path }
        if requireAll {
        guard found.values.contains(where: { $0.category == "chatgpt" }),
              found.values.contains(where: { $0.category == "claude" }),
              Set(tools.map(\.category)).isSuperset(of: ["codex_cli", "claude_cli"]) else { throw Failure.missingTarget }
        }
        // The provider receives every exact version/path as a separate record.
        // NE keeps one app rule per signing identifier, so the OS gets one rule each.
        var roots = Array(found.values)
        if ruleSet == "apps" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) }
        } else if ruleSet == "primary" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) || ["codex_cli", "claude_cli"].contains($0.category) }
        } else if ruleSet == "cli" { roots = tools }
        // nil matchTools inherits *all* child processes, including newly downloaded, unauthorized code.
        // Bound responsible-app inheritance to this verified snapshot, including the app itself.
        let byIdentifier = Dictionary(grouping: roots, by: \.id)
        var rules: [NEAppRule] = byIdentifier.keys.sorted().map { id in
            let members = byIdentifier[id] ?? []
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: Self.requirement(members.map(\.requirement)))
            if members.count == 1 { rule.matchPath = members[0].path }
            let categories = Set(members.map(\.category))
            rule.matchTools = roots.filter { categories.contains($0.category) }.sorted { $0.path < $1.path }.map(\.rule)
            return rule
        }
        guard rules.reduce(0, { $0 + ($1.matchTools?.count ?? 0) }) <= 8192 else { throw Failure.tooManyTargets }
        // The responsible application can be the terminal/editor. Restrict
        // those rules to the verified tools; never select the whole terminal.
        for path in ["/System/Applications/Utilities/Terminal.app", "/Applications/iTerm.app",
                     "/Applications/Warp.app", "/Applications/Ghostty.app", "/Applications/kitty.app",
                     "/Applications/Alacritty.app", "/Applications/Visual Studio Code.app"] {
            guard !tools.isEmpty, let executable = Bundle(url: URL(fileURLWithPath: path))?.executableURL,
                  let terminal = Self.inspect(executable.resolvingSymlinksInPath(), category: "cli_host", team: nil) else { continue }
            let rule = NEAppRule(signingIdentifier: terminal.id, designatedRequirement: terminal.requirement)
            rule.matchTools = tools.map(\.rule)
            if ruleSet != "apps" {
                // A terminal chosen as an application already owns its identifier's single rule.
                if let existing = rules.first(where: { $0.matchSigningIdentifier == terminal.id }) {
                    existing.matchTools = Self.uniqueByPath((existing.matchTools ?? []) + tools.map(\.rule))
                } else { rules.append(rule) }
            }
            // A terminal explicitly selected as an application retains its
            // own category; matchTools host records must not overwrite it.
            if found[terminal.path] == nil { found[terminal.path] = terminal }
        }
        guard found.count <= 512, rules.reduce(0, { $0 + ($1.matchTools?.count ?? 0) }) <= 8192 else { throw Failure.tooManyTargets }
        self.issues = issues
        self.targets = found.values.sorted { $0.path < $1.path }
        self.rules = rules
    }

    /// Union already verified per-application discoveries. Shared responsible
    /// hosts merge only their explicit tools; nil must never expand inheritance.
    init(combining groups: [AIAppTargets]) throws {
        var identities: [String: Target] = [:]
        var tools: [String: [NEAppRule]] = [:], requirements: [String: [String]] = [:], paths: [String: Set<String>] = [:]
        var pathless = Set<String>()
        for group in groups {
            for target in group.targets {
                if let existing = identities[target.path], existing.identity != target.identity {
                    throw Failure.duplicateTarget
                }
                identities[target.path] = target
            }
            for rule in group.rules {
                guard let ruleTools = rule.matchTools, !ruleTools.isEmpty,
                      ruleTools.allSatisfy({ $0.matchPath != nil }) else { throw Failure.unsignedTarget }
                let id = rule.matchSigningIdentifier
                tools[id, default: []] += ruleTools
                requirements[id, default: []].append(rule.matchDesignatedRequirement)
                if let path = rule.matchPath { paths[id, default: []].insert(path) } else { pathless.insert(id) }
            }
        }
        targets = identities.values.sorted { $0.path < $1.path }
        rules = tools.keys.sorted().map { id in
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: Self.requirement(requirements[id] ?? []))
            if !pathless.contains(id), let only = paths[id], only.count == 1 { rule.matchPath = only.first }
            rule.matchTools = Self.uniqueByPath(tools[id] ?? [])
            return rule
        }
        issues = groups.flatMap(\.issues)
        guard targets.count <= 512, rules.reduce(0, { $0 + ($1.matchTools?.count ?? 0) }) <= 8192 else { throw Failure.tooManyTargets }
    }

    enum Failure: LocalizedError {
        case missingTarget, tooManyTargets, unsignedTarget, duplicateTarget
        var errorDescription: String? {
            switch self {
            case .missingTarget: "No signed application executables were found."
            case .tooManyTargets: "The selected applications exceed the executable or rule-complexity limit."
            case .unsignedTarget: "Choose an installed signed .app or signed CLI executable."
            case .duplicateTarget: "This executable is already included in another application entry."
            }
        }
    }

    static let claudeCodeRoots: [(String, String)] = [
        ("Library/Application Support/Claude/claude-code", "claude"),
        (".claude/remote/ccd-cli", "claude"),
        (".local/share/claude/versions", "claude_cli"),
    ]

    /// One OS rule may stand for several approved copies of an identifier: match any of their requirements.
    static func requirement(_ texts: [String]) -> String {
        let unique = Array(Set(texts)).sorted()
        return unique.count == 1 ? unique[0] : unique.map { "(\($0))" }.joined(separator: " or ")
    }
    static func uniqueByPath(_ tools: [NEAppRule]) -> [NEAppRule] {
        var byPath: [String: NEAppRule] = [:]
        for tool in tools { if let path = tool.matchPath { byPath[path] = tool } }
        return byPath.keys.sorted().compactMap { byPath[$0] }
    }
    /// A cheap, unvalidated Team ID read used only to pick candidates; matches are fully inspected afterwards.
    private static func teamIdentifier(_ url: URL) -> String? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isAppleCode(_ url: URL) -> Bool {
        var code: SecStaticCode?; var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func inspect(_ path: URL, category: String, team: String?, identifier: String? = nil) -> Target? {
        guard let identity = try? AppProxyCodeIdentity.inspect(path: path.path, category: category, team: team, identifier: identifier) else { return nil }
        return Target(identity: identity)
    }
}
