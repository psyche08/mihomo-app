import CoreServices
import CryptoKit
import Foundation
import NetworkExtension
import Security
import MihomoControl

/// One requested application, resolved for the current user: Team IDs, the signing identifiers
/// the OS diverts, and its code folders as absolute paths.
struct AppProxyApplicationPolicy: Equatable, Sendable {
    let category: String
    let teams: [String]
    let identifiers: [String]
    /// Every configured folder; `existingFolders` are the ones present now.
    let folders: [String]
    let existingFolders: [String]
    /// A custom application's chosen .app or CLI.
    let path: String?

    /// Custom applications saved before policy version 5 have no Team ID or identifiers:
    /// they come from the chosen code's signature, as when it is added now.
    static func resolve(_ entry: AppProxyEntry, home: String) throws -> Self {
        var teams = entry.teamIdentifiers, identifiers = entry.signingIdentifiers
        if let path = entry.path, teams.isEmpty || identifiers.isEmpty {
            let code = try AIAppTargets.codeIdentity(of: path)
            if teams.isEmpty { teams = [code.team] }
            if identifiers.isEmpty { identifiers = code.identifiers }
        }
        guard !teams.isEmpty, !identifiers.isEmpty else { throw AppProxyIdentityFailure.undiscoveredTarget }
        let folders = entry.directories.map { AppProxyEntry.expandFolder($0, home: home) }
        let existing = folders.filter { folder in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
                && URL(fileURLWithPath: folder).resolvingSymlinksInPath().path == folder
        }
        return Self(category: entry.id, teams: teams, identifiers: identifiers, folders: folders,
                    existingFolders: existing, path: entry.path)
    }
}

/// OS rules from Team IDs and signing identifiers, without scanning code.
///
/// NetworkExtension needs a rule for every process that can be a flow's responsible process:
/// a top-level application, a CLI that its application starts with responsibility disclaimed
/// (Claude Desktop's `claude.app`), a terminal, an editor or an SSH login. LaunchServices and a
/// shallow listing of the configured code folders locate these; reading each one's signature
/// (no validation) gives its designated requirement. Everything they start is matched by one
/// shared, version-independent list of tools: one path-less entry per signing identifier with a
/// Team ID requirement. The provider then routes each flow by the Team ID of its running code.
struct AIAppTargets {
    /// Top-level code with a rule of its own.
    struct Application: Equatable, Sendable {
        let identifier: String
        let team: String?
        let requirement: String
        /// The main executable.
        let path: String
        /// The enclosing .app, nil for a standalone executable.
        let bundle: String?
        /// nil for a launch host, which only selects tools and is never routed.
        let category: String?
    }
    let applications: [Application]
    let rules: [NEAppRule]
    let tools: [NEAppRule]
    let routes: [AppProxyPolicy.Route]
    let processRoutes: AppProxyProcessRoutes
    /// Digest of the top-level executables and existing folders; see `AppProxyPolicy.codeStamp`.
    let codeStamp: String
    /// "category:reason" -> count, for status. Never paths.
    let issues: [String: Int]

    init(applications policies: [AppProxyApplicationPolicy],
         lookup: (String) -> [URL] = AIAppTargets.launchServicesURLs,
         register: (URL) -> Void = AIAppTargets.registerWithLaunchServices,
         hostExecutables: [String] = AIAppTargets.launchHostExecutables) {
        var applications: [Application] = [], issues: [String: Int] = [:]
        for policy in policies {
            var bundles = Set<String>(), standalone = Set<String>()
            let known = Set(policy.identifiers.flatMap(lookup).map { $0.standardizedFileURL.path })
            bundles.formUnion(known)
            for folder in policy.existingFolders {
                for bundle in Self.bundles(in: folder, identifiers: Set(policy.identifiers)) where !known.contains(bundle) {
                    // A vendor updater may not have registered a new version yet. NetworkExtension
                    // resolves a rule without a path through LaunchServices, so register it.
                    register(URL(fileURLWithPath: bundle)); bundles.insert(bundle)
                }
            }
            if let path = policy.path {
                if path.hasSuffix(".app") { bundles.insert(path) } else { standalone.insert(path) }
            }
            for location in bundles.sorted() + standalone.sorted() {
                let isBundle = bundles.contains(location)
                guard !isBundle || Self.isTopLevelBundle(location) else { continue }
                guard Self.providerCanRead(location, folders: policy.existingFolders) else {
                    issues[policy.category + ":unreadableCode", default: 0] += 1; continue
                }
                guard let executable = isBundle ? Self.mainExecutable(of: location) : location,
                      let code = Self.signature(executable), let team = code.team, policy.teams.contains(team),
                      policy.identifiers.contains(code.identifier) else { continue }
                applications.append(.init(identifier: code.identifier, team: team, requirement: code.requirement, path: executable,
                                          bundle: isBundle ? location : nil, category: policy.category))
            }
        }
        // Responsible processes that start CLIs: SSH logins, terminals and editors.
        var hosts: [Application] = []
        if !policies.isEmpty {
            for (path, bundle) in Self.launchHostLocations(lookup: lookup, executables: hostExecutables)
            where !applications.contains(where: { $0.path == path }) {
                guard let code = Self.signature(path) else { continue }
                hosts.append(.init(identifier: code.identifier, team: code.team, requirement: code.requirement, path: path,
                                   bundle: bundle, category: nil))
            }
        }
        // One tool entry per identifier. An identifier several publishers use (`node`) admits each of them.
        var teamsByIdentifier: [String: [String]] = [:]
        for policy in policies {
            for id in policy.identifiers {
                teamsByIdentifier[id, default: []] += policy.teams.filter { !(teamsByIdentifier[id] ?? []).contains($0) }
            }
        }
        let tools = teamsByIdentifier.keys.sorted().map {
            NEAppRule(signingIdentifier: $0, designatedRequirement: AppProxyCode.requirement(identifier: $0, teams: teamsByIdentifier[$0] ?? []))
        }
        // NetworkExtension keeps one rule per signing identifier. Several copies (versions,
        // Xcode and Xcode-beta) share one rule without a path, which it resolves through
        // LaunchServices, and admit any of their requirements.
        let top = applications + hosts
        let grouped = Dictionary(grouping: top, by: \.identifier)
        rules = tools.isEmpty ? [] : grouped.keys.sorted().map { id in
            let members = grouped[id] ?? []
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: Self.requirement(members.map(\.requirement)))
            let paths = Set(members.map(\.path))
            if paths.count == 1 { rule.matchPath = paths.first }
            rule.matchTools = tools
            return rule
        }
        self.tools = tools
        self.applications = top.sorted { $0.path < $1.path }
        routes = policies.map { .init(category: $0.category, teams: $0.teams, identifiers: $0.identifiers) }
        var prefixes: [String: [String]] = [:], paths: [String: [String]] = [:]
        for policy in policies {
            // Folders named Applications or bin hold other vendors' code: only bundles found there are routed.
            let own = policy.folders.filter { !["Applications", "bin"].contains(URL(fileURLWithPath: $0).lastPathComponent) }
            let found = applications.filter { $0.category == policy.category }
            prefixes[policy.category] = Array(Set(own + found.compactMap(\.bundle))).sorted()
                .filter(AppProxyProcessRoutes.isRoutable)
            paths[policy.category] = found.filter { $0.bundle == nil }.map(\.path).filter(AppProxyProcessRoutes.isRoutable)
        }
        processRoutes = AppProxyProcessRoutes(paths.filter { !$0.value.isEmpty }, prefixes: prefixes.filter { !$0.value.isEmpty })
        codeStamp = Self.stamp(paths: top.map(\.path), folders: policies.flatMap(\.existingFolders))
        for policy in policies where !applications.contains(where: { $0.category == policy.category }) && policy.existingFolders.isEmpty {
            issues[policy.category + ":notInstalled", default: 0] += 1
        }
        self.issues = issues
    }

    enum Failure: LocalizedError {
        case unsignedTarget
        var errorDescription: String? {
            switch self {
            case .unsignedTarget: "Choose an installed .app or CLI signed with a Developer ID (a Team ID)."
            }
        }
    }

    // MARK: Locating code

    static func launchServicesURLs(_ identifier: String) -> [URL] {
        (LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
    }
    static func registerWithLaunchServices(_ url: URL) { _ = LSRegisterURL(url as CFURL, false) }

    /// `.app` bundles directly below `folder` or up to three levels down whose bundle identifier
    /// is listed. Reads directory entries and Info.plist files only, never code.
    static func bundles(in folder: String, identifiers: Set<String>, depth: Int = 3, limit: Int = 4000) -> [String] {
        var found: [String] = [], visited = 0
        func walk(_ directory: URL, _ level: Int) {
            guard level <= depth, let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                visited += 1
                guard visited <= limit else { return }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if entry.pathExtension == "app" {
                    if let id = bundleIdentifier(entry.path), identifiers.contains(id) { found.append(entry.standardizedFileURL.path) }
                } else { walk(entry, level + 1) }
            }
        }
        walk(URL(fileURLWithPath: folder, isDirectory: true), 1)
        return found
    }

    /// An application started on its own: not nested in another bundle and not in the Trash.
    static func isTopLevelBundle(_ path: String) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path + "/"
        return path.hasSuffix(".app") && !parent.contains(".app/") && !path.contains("/.Trash/")
            && FileManager.default.fileExists(atPath: path)
    }

    /// Locations the provider's sandbox reads without a grant (application.sb).
    static let providerReadableRoots = ["/Applications/", "/System/", "/Library/", "/usr/bin/", "/usr/sbin/",
                                        "/usr/libexec/", "/bin/", "/sbin/"]
    /// NetworkExtension validates a diverted process inside the provider's sandbox; code it cannot
    /// read is dropped ("Failed to get a SecCodeRef") instead of routed.
    static func providerCanRead(_ path: String, folders: [String]) -> Bool {
        providerReadableRoots.contains(where: path.hasPrefix) || folders.contains { path.hasPrefix($0 + "/") }
    }

    /// Read Info.plist directly: Bundle(url:) returns Bundle.main for the running app.
    static func bundleIdentifier(_ bundle: String) -> String? {
        NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }
    static func mainExecutable(of bundle: String) -> String? {
        guard let name = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleExecutable"] as? String,
              !name.contains("/") else { return nil }
        let path = bundle + "/Contents/MacOS/" + name
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    struct Signature: Equatable { let identifier: String; let team: String?; let requirement: String }
    /// The embedded signature's identifier, Team ID and designated requirement, without
    /// validating the code: NetworkExtension and the provider validate the running process.
    static func signature(_ path: String) -> Signature? {
        var code: SecStaticCode?; var info: CFDictionary?; var requirement: SecRequirement?; var text: CFString?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let id = values[kSecCodeInfoIdentifier as String] as? String,
              AppProxyCode.isSigningIdentifier(id),
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        let team = (values[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { AppProxyCode.isTeamIdentifier($0) ? $0 : nil }
        return Signature(identifier: id, team: team, requirement: text as String)
    }

    /// The Team ID and signing identifiers of a chosen .app (with its nested helper apps and
    /// executables) or CLI. Read once when an application is added, not on every pass.
    static func codeIdentity(of path: String) throws -> (team: String, identifiers: [String]) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension == "app" else {
            guard let code = signature(url.path), let team = code.team else { throw Failure.unsignedTarget }
            return (team, [code.identifier])
        }
        guard let main = mainExecutable(of: url.path), let code = signature(main), let team = code.team else {
            throw Failure.unsignedTarget
        }
        var identifiers = [code.identifier]
        let contents = url.appendingPathComponent("Contents")
        guard let files = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return (team, identifiers)
        }
        var visited = 0
        for case let file as URL in files {
            visited += 1
            guard visited <= 20000, identifiers.count < 64 else { break }
            if file.pathExtension == "app" {
                if let id = bundleIdentifier(file.path), AppProxyCode.isSigningIdentifier(id), !identifiers.contains(id) { identifiers.append(id) }
                continue
            }
            // Standalone helpers sit in MacOS or Helpers folders; frameworks hold libraries, not processes.
            guard ["MacOS", "Helpers"].contains(file.deletingLastPathComponent().lastPathComponent),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isExecutableFile(atPath: file.path),
                  let nested = signature(file.path), nested.team == team, !identifiers.contains(nested.identifier) else { continue }
            identifiers.append(nested.identifier)
        }
        return (team, identifiers)
    }

    // MARK: Launch hosts

    /// Installed launch hosts: each one's main executable and, for an application, its bundle.
    static func launchHostLocations(lookup: (String) -> [URL] = launchServicesURLs,
                                    executables: [String] = launchHostExecutables) -> [(path: String, bundle: String?)] {
        var locations: [(path: String, bundle: String?)] = executables.filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { ($0, nil) }
        for id in launchHostBundles.sorted() {
            for url in lookup(id) {
                let bundle = url.standardizedFileURL.path
                guard isTopLevelBundle(bundle), let executable = mainExecutable(of: bundle),
                      !locations.contains(where: { $0.path == executable }) else { continue }
                locations.append((executable, bundle))
            }
        }
        return locations
    }

    /// Responsible processes that start CLIs: SSH logins, terminals and editors. tmux, screen
    /// and shells inherit the process that started them, so they need no rule of their own.
    static let launchHostExecutables = ["/usr/libexec/sshd-session", "/usr/sbin/sshd"]
    static let launchHostBundles: Set<String> = Set([
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode",
        "com.google.android.studio",
    ]).union(AppProxyEntry.jetBrainsIdentifiers)

    // MARK: Helpers

    /// The folder a chosen custom application needs granted, in settings form (`~/` for the home
    /// directory); none when the provider can read it already. A Homebrew formula or cask keeps
    /// its versions under one folder, so that folder survives an upgrade.
    static func codeFolders(for path: String, home: String) -> [String] {
        guard !providerReadableRoots.contains(where: path.hasPrefix) else { return [] }
        var folder = path.hasSuffix(".app") ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
        for root in ["/opt/homebrew/Cellar/", "/opt/homebrew/Caskroom/", "/usr/local/Cellar/", "/usr/local/Caskroom/"]
        where path.hasPrefix(root) {
            if let name = path.dropFirst(root.count).split(separator: "/").first { folder = root + name }
        }
        if folder.hasPrefix(home + "/") { folder = "~" + folder.dropFirst(home.count) }
        return AppProxyEntry.isFolderSetting(folder) ? [folder] : []
    }

    /// Watched for updates: the application folders and the requested applications' existing code folders.
    static func updateRoots(applications: [AppProxyApplicationPolicy], home: String) -> [String] {
        Array(Set(["/Applications", home + "/Applications"] + applications.flatMap(\.existingFolders))).sorted()
    }

    /// Changes when an executable with its own rule or a granted folder is replaced. Metadata only.
    static func stamp(paths: [String], folders: [String]) -> String {
        func describe(_ path: String) -> String {
            var info = stat()
            guard stat(path, &info) == 0 else { return path + "\u{0}missing" }
            return [path, "\(info.st_dev)", "\(info.st_ino)", "\(info.st_size)",
                    "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"].joined(separator: "\u{0}")
        }
        let lines = Set(paths).sorted().map { "x" + describe($0) } + Set(folders).sorted().map { "d" + describe($0) }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One OS rule may stand for several copies of an identifier: match any of their requirements.
    static func requirement(_ texts: [String]) -> String {
        let unique = Array(Set(texts)).sorted()
        return unique.count == 1 ? unique[0] : unique.map { "(\($0))" }.joined(separator: " or ")
    }
}
