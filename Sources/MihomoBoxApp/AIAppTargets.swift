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
    /// Only the folders the provider holds grants for: code elsewhere would be dropped, not routed.
    func granted(_ folders: [String]) -> Self {
        Self(category: category, teams: teams, identifiers: identifiers, folders: self.folders,
             existingFolders: existingFolders.filter(folders.contains), path: path)
    }
}

/// OS rules from Team IDs and signing identifiers, without validating code.
///
/// NetworkExtension needs a rule for every process that can be a flow's responsible process:
/// a top-level application, a CLI that its application starts with responsibility disclaimed
/// (Claude Desktop's `claude.app`), a terminal, an editor or an SSH login. LaunchServices and a
/// shallow listing of the configured code folders locate these; reading each one's signature
/// (no validation) gives its designated requirement. Everything they start is matched by one
/// shared list of tools with Team ID requirements. NetworkExtension matches a tool by the
/// Mach-O UUIDs of its path; a tool without a path resolves through LaunchServices by bundle
/// identifier, which finds no CLI and few nested helpers. So each executable of a listed
/// identifier found in the applications and granted folders gets a tool with its path, located
/// by reading its embedded identifier and Team ID (cached by file metadata); an identifier
/// with no such executable keeps one path-less tool. The provider then routes each flow by the
/// identifier and Team ID of its running code.
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
    /// An executable of a listed identifier, matched by its path.
    struct Located: Equatable, Sendable {
        let category: String
        let identifier: String
        let path: String
    }
    let applications: [Application]
    let located: [Located]
    let rules: [NEAppRule]
    let tools: [NEAppRule]
    let routes: [AppProxyPolicy.Route]
    let processRoutes: AppProxyProcessRoutes
    /// Digest of the top-level executables and existing folders; see `AppProxyPolicy.codeStamp`.
    let codeStamp: String
    /// "category:reason" -> count, for status. Never paths.
    let issues: [String: Int]

    /// At most this many path tools; NetworkExtension's configuration grows with rules × tools.
    static let maximumLocated = 256

    init(applications policies: [AppProxyApplicationPolicy],
         lookup: (String) -> [URL] = AIAppTargets.launchServicesURLs,
         register: (URL) -> Void = AIAppTargets.registerWithLaunchServices,
         hostExecutables: [String] = AIAppTargets.launchHostExecutables,
         identify: (String) -> Identity? = AIAppTargets.cachedIdentity) {
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
        // Executables of the listed identifiers in each application's bundles and granted folders.
        var located: [Located] = [], seen = Set<String>()
        for policy in policies {
            let wanted = Set(policy.identifiers), teams = Set(policy.teams)
            let own = applications.filter { $0.category == policy.category }
            var candidates = own.filter { $0.bundle == nil }.map(\.path)
            for bundle in own.compactMap(\.bundle) { candidates += Self.executables(in: bundle, bundle: true) }
            for folder in policy.existingFolders { candidates += Self.executables(in: folder, bundle: false) }
            for path in candidates where !seen.contains(path) && Self.providerCanRead(path, folders: policy.existingFolders) {
                guard let code = identify(path), wanted.contains(code.identifier), let team = code.team, teams.contains(team) else { continue }
                guard located.count < Self.maximumLocated else { issues[policy.category + ":tooManyExecutables", default: 0] += 1; break }
                seen.insert(path)
                located.append(.init(category: policy.category, identifier: code.identifier, path: path))
            }
        }
        // Tools: an identifier several publishers use (`node`) admits each of them.
        var teamsByIdentifier: [String: [String]] = [:]
        for policy in policies {
            for id in policy.identifiers {
                teamsByIdentifier[id, default: []] += policy.teams.filter { !(teamsByIdentifier[id] ?? []).contains($0) }
            }
        }
        let toolPaths = Dictionary(grouping: located, by: \.identifier).mapValues { $0.map(\.path).sorted() }
        // NetworkExtension keeps one rule per signing identifier. It caches Mach-O UUIDs per
        // identifier, and each lookup by path replaces that cache, so a path-less rule or tool
        // reads whichever path came last. An identifier is therefore matched by path
        // everywhere or nowhere: copies of an identifier that also has path tools get the
        // preferred copy's path; other copies (Xcode and Xcode-beta) share one rule without a
        // path, which NetworkExtension resolves through LaunchServices, and admit any of
        // their requirements.
        let top = applications + hosts
        let grouped = Dictionary(grouping: top, by: \.identifier)
        var rulePaths: [String: String] = [:]
        for (id, members) in grouped {
            let paths = Set(members.map(\.path))
            if paths.count == 1 { rulePaths[id] = paths.first } else if toolPaths[id] != nil { rulePaths[id] = Self.preferredCopy(members) }
        }
        let tools = teamsByIdentifier.keys.sorted().flatMap { id -> [NEAppRule] in
            let requirement = AppProxyCode.requirement(identifier: id, teams: teamsByIdentifier[id] ?? [])
            guard let found = toolPaths[id] ?? rulePaths[id].map({ [$0] }) else {
                return [NEAppRule(signingIdentifier: id, designatedRequirement: requirement)]
            }
            return found.map { path in
                let tool = NEAppRule(signingIdentifier: id, designatedRequirement: requirement)
                tool.matchPath = path
                return tool
            }
        }
        rules = tools.isEmpty ? [] : grouped.keys.sorted().map { id in
            let members = grouped[id] ?? []
            let rule = NEAppRule(signingIdentifier: id, designatedRequirement: Self.requirement(members.map(\.requirement)))
            rule.matchPath = rulePaths[id]
            rule.matchTools = tools
            return rule
        }
        self.tools = tools
        self.located = located.sorted { ($0.category, $0.path) < ($1.category, $1.path) }
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
        codeStamp = Self.stamp(paths: top.map(\.path) + located.map(\.path), folders: policies.flatMap(\.existingFolders))
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

    /// Mach-O executables to match by path. In an application: the files in its `MacOS` and
    /// `Helpers` folders, which include nested apps, XPC services and framework helpers. In a code
    /// folder: every executable file. Links are not followed; reads directory entries and the first
    /// four bytes of each candidate.
    static func executables(in root: String, bundle: Bool, depth: Int = 10, limit: Int = 20000) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true),
                                                           includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = [], visited = 0
        for case let entry as URL in entries {
            visited += 1
            guard visited <= limit else { break }
            if entries.level > depth { entries.skipDescendants(); continue }
            if bundle, !["MacOS", "Helpers"].contains(entry.deletingLastPathComponent().lastPathComponent) { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true, FileManager.default.isExecutableFile(atPath: entry.path),
                  isMachO(entry.path) else { continue }
            found.append(entry.standardizedFileURL.path)
        }
        return found.sorted()
    }
    /// The copy a rule names when several share an identifier: the highest bundle version
    /// (an updater installs the new version beside the old one), then the last path.
    static func preferredCopy(_ members: [Application]) -> String? {
        func version(_ member: Application) -> String {
            guard let bundle = member.bundle else { return "" }
            let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")
            return (info?["CFBundleVersion"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? ""
        }
        return members.max { a, b in
            switch version(a).compare(version(b), options: .numeric) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.path < b.path
            }
        }?.path
    }
    static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)
    }

    /// The embedded signing identifier and Team ID, without validating the code.
    struct Identity: Equatable, Sendable { let identifier: String; let team: String? }
    static func identity(_ path: String) -> Identity? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let id = values[kSecCodeInfoIdentifier as String] as? String,
              AppProxyCode.isSigningIdentifier(id) else { return nil }
        let team = (values[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { AppProxyCode.isTeamIdentifier($0) ? $0 : nil }
        return Identity(identifier: id, team: team)
    }
    /// `identity`, reread only when the file's device, inode, size or modification time changes.
    static func cachedIdentity(_ path: String) -> Identity? { identityCache.value(path) }
    private static let identityCache = IdentityCache()
    private final class IdentityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (key: String, identity: Identity?)] = [:]
        func value(_ path: String) -> Identity? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            let key = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            lock.lock()
            if let cached = entries[path], cached.key == key { lock.unlock(); return cached.identity }
            lock.unlock()
            let identity = AIAppTargets.identity(path)
            lock.lock()
            if entries.count >= 8192 { entries.removeAll() }
            entries[path] = (key, identity)
            lock.unlock()
            return identity
        }
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
