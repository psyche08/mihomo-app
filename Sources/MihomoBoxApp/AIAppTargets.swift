import Foundation
import NetworkExtension
import Security
import MihomoControl

/// Discover executable identities, never process names or command-line arguments.
/// Exact paths keep generic identifiers such as `node` scoped to the chosen app.
struct AIAppTargets {
    struct Target {
        let id: String
        let requirement: String
        let path: String
        let category: String
        let team: String?
        var rule: NEAppRule {
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: requirement)
            rule.matchPath = path
            return rule
        }
        var record: [String: String] {
            ["id": id, "requirement": requirement, "path": path, "category": category]
        }
    }
    let targets: [Target]
    let rules: [NEAppRule]

    init(ruleSet: String = "all", requireAll: Bool = true, applications: [AppProxyEntry] = AppProxyEntry.defaults) throws {
        try AppProxySettings(applications: applications).validate()
        let selected = Set(applications.map(\.id))
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [String: Target] = [:]
        var duplicate = false
        func add(_ url: URL, category: String, team: String?) {
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            guard let target = Self.inspect(path, category: category, team: team) else { return }
            if let prior = found[path.path], prior.category != category { duplicate = true; return }
            found[path.path] = target
        }
        func scan(_ root: URL, category: String, team: String?) {
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            guard let files = fm.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in files {
                let path = url.resolvingSymlinksInPath().standardizedFileURL
                guard path.path.hasPrefix(canonical.path + "/"),
                      fm.isExecutableFile(atPath: path.path),
                      !["dylib", "node"].contains(path.pathExtension),
                      let file = try? FileHandle(forReadingFrom: path) else { continue }
                let header = try? file.read(upToCount: 4)
                try? file.close()
                guard let header, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xce,0xfa,0xed,0xfe]),
                                   Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca])].contains(header) else { continue }
                add(path, category: category, team: team)
            }
        }
        for (name, category, team) in [("ChatGPT.app", "chatgpt", "2DC432GLL2"),
                                        ("Codex.app", "chatgpt", "2DC432GLL2"),
                                        ("Claude.app", "claude", "Q6L2SF6YDW")] {
            guard selected.contains(category) else { continue }
            for base in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
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
        // Claude's local remote server may be ad-hoc signed. Its designated
        // requirement pins its current code hash as well as its absolute path.
        if selected.contains("claude") { scan(home.appendingPathComponent(".claude/remote/srv"), category: "claude", team: nil) }
        for (name, category, team) in [("codex", "codex_cli", "2DC432GLL2"),
                                        ("claude", "claude_cli", "Q6L2SF6YDW")] {
            guard selected.contains(category) else { continue }
            for base in ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path] {
                add(URL(fileURLWithPath: base).appendingPathComponent(name), category: category, team: team)
            }
        }
        var toolCategories: Set<String> = ["codex_cli", "claude_cli"]
        var explicitToolPaths = Set<String>()
        for entry in applications {
            for path in entry.executablePaths {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
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
                      Self.inspect(executable, category: entry.id, team: nil) != nil else { throw Failure.unsignedTarget }
                scan(url, category: entry.id, team: nil)
            } else {
                guard fm.isExecutableFile(atPath: url.path),
                      Self.inspect(url, category: entry.id, team: nil) != nil else { throw Failure.unsignedTarget }
                add(url, category: entry.id, team: nil)
                toolCategories.insert(entry.id)
            }
        }
        guard !duplicate else { throw Failure.duplicateTarget }
        let tools = found.values.filter { toolCategories.contains($0.category) || explicitToolPaths.contains($0.path) }.sorted { $0.path < $1.path }
        if requireAll {
        guard found.values.contains(where: { $0.category == "chatgpt" }),
              found.values.contains(where: { $0.category == "claude" }),
              Set(tools.map(\.category)).isSuperset(of: ["codex_cli", "claude_cli"]) else { throw Failure.missingTarget }
        }
        // NE treats application rules as identity records. Consolidate repeated
        // identities (multiple renderers, versions and remote servers) and keep
        // executable-path validation inside the provider.
        var roots = Array(found.values)
        if ruleSet == "apps" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) }
        } else if ruleSet == "primary" {
            roots = roots.filter { ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"].contains($0.id) || ["codex_cli", "claude_cli"].contains($0.category) }
        } else if ruleSet == "cli" { roots = tools }
        var rules: [NEAppRule]
        if ruleSet == "all-paths" { rules = roots.sorted { $0.path < $1.path }.map(\.rule) }
        else {
            rules = Dictionary(grouping: roots, by: \.id).sorted { $0.key < $1.key }.map { id, items in
                let requirements = Set(items.map(\.requirement)).sorted().map { "(" + $0 + ")" }.joined(separator: " or ")
                return NEAppRule(signingIdentifier: id, designatedRequirement: requirements)
            }
        }
        // The responsible application can be the terminal/editor. Restrict
        // those rules to the verified tools; never select the whole terminal.
        for path in ["/System/Applications/Utilities/Terminal.app", "/Applications/iTerm.app",
                     "/Applications/Warp.app", "/Applications/Ghostty.app", "/Applications/kitty.app",
                     "/Applications/Alacritty.app", "/Applications/Visual Studio Code.app"] {
            guard !tools.isEmpty, let executable = Bundle(url: URL(fileURLWithPath: path))?.executableURL,
                  let terminal = Self.inspect(executable.resolvingSymlinksInPath(), category: "cli_host", team: nil) else { continue }
            let rule = NEAppRule(signingIdentifier: terminal.id, designatedRequirement: terminal.requirement)
            rule.matchTools = tools.map { NEAppRule(signingIdentifier: $0.id, designatedRequirement: $0.requirement) }
            if ruleSet != "apps" { rules.append(rule) }
            // A terminal explicitly selected as an application retains its
            // own category; matchTools host records must not overwrite it.
            if found[terminal.path] == nil { found[terminal.path] = terminal }
        }
        guard found.count <= 512 else { throw Failure.tooManyTargets }
        self.targets = found.values.sorted { $0.path < $1.path }
        self.rules = rules
    }

    enum Failure: LocalizedError {
        case missingTarget, tooManyTargets, unsignedTarget, duplicateTarget
        var errorDescription: String? {
            switch self {
            case .missingTarget: "No signed application executables were found."
            case .tooManyTargets: "The selected applications exceed the 512-executable limit."
            case .unsignedTarget: "Choose an installed signed .app or signed CLI executable."
            case .duplicateTarget: "This executable is already included in another application entry."
            }
        }
    }

    private static func inspect(_ path: URL, category: String, team: String?) -> Target? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let id = values[kSecCodeInfoIdentifier as String] as? String else { return nil }
        if let team {
            guard values[kSecCodeInfoTeamIdentifier as String] as? String == team else { return nil }
            var anchor: SecRequirement?
            guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &anchor) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, [], anchor) == errSecSuccess else { return nil }
        }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return Target(id: id, requirement: text as String, path: path.path, category: category,
                      team: values[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}
