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
        func scan(_ root: URL, category: String, team: String?, identifier: String? = nil) {
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
                                   Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca])].contains(header) else { continue }
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
        for entry in applications {
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
        // Publish the exact verified version/path set to both OS and provider.
        // Multiple versions sharing one signing identifier remain separate records.
        var roots = Array(found.values)
        if ruleSet == "apps" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) }
        } else if ruleSet == "primary" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) || ["codex_cli", "claude_cli"].contains($0.category) }
        } else if ruleSet == "cli" { roots = tools }
        // nil matchTools inherits *all* child processes, including newly downloaded, unauthorized code.
        // Bound responsible-app inheritance to this verified snapshot, including the app itself.
        var rules = roots.sorted { $0.path < $1.path }.map { target in
            let rule = target.rule
            rule.matchTools = roots.filter { $0.category == target.category }.map(\.rule)
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
            if ruleSet != "apps" { rules.append(rule) }
            // A terminal explicitly selected as an application retains its
            // own category; matchTools host records must not overwrite it.
            if found[terminal.path] == nil { found[terminal.path] = terminal }
        }
        guard found.count <= 512, rules.reduce(0, { $0 + ($1.matchTools?.count ?? 0) }) <= 8192 else { throw Failure.tooManyTargets }
        self.issues = issues
        self.targets = found.values.sorted { $0.path < $1.path }
        self.rules = rules
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

    private static func inspect(_ path: URL, category: String, team: String?, identifier: String? = nil) -> Target? {
        guard let identity = try? AppProxyCodeIdentity.inspect(path: path.path, category: category, team: team, identifier: identifier) else { return nil }
        return Target(identity: identity)
    }
}
