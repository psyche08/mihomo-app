import Darwin
import Foundation

enum LoginAutostartOutcome: String, Sendable {
  case applied
  case alreadyApplied = "already_applied"
  case repairedMovedApp = "repaired_moved_app"
  case userDisabled = "user_disabled"
  case userConfigured = "user_configured"
  case notInstalled = "not_installed"
  case notHealthy = "not_healthy"
}

enum LoginAutostartError: Error, LocalizedError {
  case invalidState
  case modifiedEntry
  case readbackFailed

  var errorDescription: String? {
    switch self {
    case .invalidState: "the login-start default state is invalid"
    case .modifiedEntry: "the MihomoBox login item was modified outside the App"
    case .readbackFailed: "the login item did not pass atomic readback"
    }
  }
}

enum LoginAutostartWriteTarget: Sendable {
  case agent
  case state
}

/// Applies the healthy-TUN login-start default once, in the current-user
/// boundary. A later user removal is remembered and never undone.
actor LoginAutostartController {
  private static let label = "dev.linsheng.mihomo-app"
  private static let stateVersion = 1
  private static let allowedAgentKeys: Set<String> = [
    "Label", "ProgramArguments", "RunAtLoad", "AssociatedBundleIdentifiers",
  ]

  private let fileManager: FileManager
  private let home: URL
  private let executable: URL?
  private let beforeWrite: @Sendable (LoginAutostartWriteTarget) throws -> Void

  init(
    fileManager: FileManager = .default,
    home: URL? = nil,
    executable: URL? = Bundle.main.executableURL,
    beforeWrite: @escaping @Sendable (LoginAutostartWriteTarget) throws -> Void = { _ in }
  ) {
    self.fileManager = fileManager
    self.home =
      (home ?? fileManager.homeDirectoryForCurrentUser)
      .resolvingSymlinksInPath().standardizedFileURL
    self.executable = executable
    self.beforeWrite = beforeWrite
  }

  func applyIfHealthy(enhancedTUN: Bool, networkHealthy: Bool?) throws -> LoginAutostartOutcome {
    guard enhancedTUN, networkHealthy == true else { return .notHealthy }
    guard let executable = installedExecutable() else { return .notInstalled }
    return try reconcile(executable: executable)
  }

  private var agentURL: URL {
    home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
  }

  private var stateURL: URL {
    home.appendingPathComponent(
      "Library/Application Support/MihomoBox/.login-autostart-default.json"
    )
  }

  private func installedExecutable() -> URL? {
    guard let executable else { return nil }
    let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
    let macOS = resolved.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let bundle = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      bundle.pathExtension == "app"
    else { return nil }
    let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
    guard
      bundle.path.hasPrefix(applications.path + "/")
        || bundle.path.hasPrefix(userApplications.path + "/")
    else { return nil }
    return resolved
  }

  private func reconcile(executable: URL) throws -> LoginAutostartOutcome {
    let state = try readState()
    let status = try readAgent()
    if let state {
      guard state.version == Self.stateVersion else { throw LoginAutostartError.invalidState }
      switch status {
      case .missing:
        return .userDisabled
      case .valid(let current) where current == executable.path:
        if state.executable != executable.path {
          try writeState(executable.path)
          return .repairedMovedApp
        }
        return .alreadyApplied
      case .valid(let current) where current == state.executable:
        try replaceAgentAndState(executable.path)
        return .repairedMovedApp
      case .valid, .invalid:
        throw LoginAutostartError.modifiedEntry
      }
    }

    switch status {
    case .missing:
      try replaceAgentAndState(executable.path)
      return .applied
    case .valid(let current) where current == executable.path:
      try writeState(executable.path)
      return .applied
    case .valid, .invalid:
      return .userConfigured
    }
  }

  private func replaceAgentAndState(_ executable: String) throws {
    let agentBackup = try backupFile(agentURL, maximumBytes: 64 * 1_024)
    let stateBackup = try backupFile(stateURL, maximumBytes: 16 * 1_024)
    do {
      try writeAgent(executable)
      guard case .valid(let observed) = try readAgent(), observed == executable else {
        throw LoginAutostartError.readbackFailed
      }
      try writeState(executable)
    } catch {
      try? restoreFile(agentURL, from: agentBackup)
      try? restoreFile(stateURL, from: stateBackup)
      throw error
    }
  }

  private enum AgentStatus {
    case missing
    case valid(String)
    case invalid
  }
  private struct State {
    var version: Int
    var executable: String
  }
  private struct Backup {
    var data: Data
    var mode: Int
  }

  private func readAgent() throws -> AgentStatus {
    guard let attributes = try attributesIfPresent(agentURL) else { return .missing }
    guard (attributes[.type] as? FileAttributeType) == .typeRegular,
      ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 64 * 1_024
    else { return .invalid }
    let data = try Data(contentsOf: agentURL)
    guard
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ), let dictionary = propertyList as? [String: Any],
      Set(dictionary.keys) == Self.allowedAgentKeys,
      dictionary["Label"] as? String == Self.label,
      dictionary["RunAtLoad"] as? Bool == true,
      dictionary["AssociatedBundleIdentifiers"] as? [String] == [Self.label],
      let arguments = dictionary["ProgramArguments"] as? [String], arguments.count == 1
    else { return .invalid }
    return .valid(arguments[0])
  }

  private func readState() throws -> State? {
    guard let attributes = try attributesIfPresent(stateURL) else { return nil }
    guard (attributes[.type] as? FileAttributeType) == .typeRegular,
      ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 16 * 1_024
    else { throw LoginAutostartError.invalidState }
    let data = try Data(contentsOf: stateURL)
    guard let decoded = try? JSONSerialization.jsonObject(with: data),
      let object = decoded as? [String: Any],
      Set(object.keys) == ["format_version", "executable"],
      let version = object["format_version"] as? Int,
      let executable = object["executable"] as? String
    else { throw LoginAutostartError.invalidState }
    return State(version: version, executable: executable)
  }

  private func writeAgent(_ executable: String) throws {
    let value: [String: Any] = [
      "Label": Self.label,
      "ProgramArguments": [executable],
      "RunAtLoad": true,
      "AssociatedBundleIdentifiers": [Self.label],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try beforeWrite(.agent)
    try atomicWrite(data, to: agentURL, mode: 0o644, parentMode: nil)
  }

  private func writeState(_ executable: String) throws {
    let value: [String: Any] = [
      "format_version": Self.stateVersion,
      "executable": executable,
    ]
    var data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try beforeWrite(.state)
    try atomicWrite(data, to: stateURL, mode: 0o600, parentMode: 0o700)
  }

  private func atomicWrite(_ data: Data, to destination: URL, mode: Int, parentMode: Int?) throws {
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: parentMode.map { [.posixPermissions: $0] }
    )
    if let parentMode {
      try fileManager.setAttributes([.posixPermissions: parentMode], ofItemAtPath: parent.path)
    }
    let staged = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      guard
        fileManager.createFile(
          atPath: staged.path,
          contents: data,
          attributes: [.posixPermissions: mode]
        )
      else { throw CocoaError(.fileWriteUnknown) }
      let handle = try FileHandle(forWritingTo: staged)
      try handle.synchronize()
      try handle.close()
      guard rename(staged.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try syncDirectory(parent)
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 {
      guard (metadata.st_mode & S_IFMT) == S_IFREG else {
        return [.type: FileAttributeType.typeUnknown]
      }
      return try fileManager.attributesOfItem(atPath: url.path)
    }
    if errno == ENOENT { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func backupFile(_ url: URL, maximumBytes: Int) throws -> Backup? {
    guard let attributes = try attributesIfPresent(url) else { return nil }
    guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
      throw LoginAutostartError.modifiedEntry
    }
    guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumBytes else {
      throw LoginAutostartError.modifiedEntry
    }
    return Backup(
      data: try Data(contentsOf: url),
      mode: (attributes[.posixPermissions] as? Int) ?? 0o644
    )
  }

  private func restoreFile(_ url: URL, from backup: Backup?) throws {
    if let backup {
      try atomicWrite(backup.data, to: url, mode: backup.mode, parentMode: nil)
    } else if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
      try syncDirectory(url.deletingLastPathComponent())
    }
  }
}
