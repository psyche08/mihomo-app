import Foundation

/// The root LaunchDaemon definition is written only by the verified installer.
/// Component synchronization replaces the daemon, agent and Mihomo executables
/// but never this plist, so a definition that a later release changed (its
/// process class, for example) stays in effect until an explicit repair.
public enum LaunchDaemonDefinition {
  public static let installedPath = "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist"
  public static let bundledRelativePath =
    "Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist"
  static let maximumSize = 64 * 1_024

  public enum State: Equatable, Sendable {
    /// The installed definition equals the bundled one.
    case current
    /// An installed definition exists and differs from the bundled one.
    case outdated
    /// Either definition is absent or unreadable; nothing to recommend.
    case unknown
  }

  /// Compares parsed property lists, so formatting differences do not count.
  public static func state(installed: Data?, bundled: Data?) -> State {
    guard let bundled = bundled.flatMap(dictionary(from:)), let installed else {
      return .unknown
    }
    guard let parsed = dictionary(from: installed) else { return .outdated }
    return NSDictionary(dictionary: parsed).isEqual(to: bundled) ? .current : .outdated
  }

  public static func state(bundleURL: URL) -> State {
    state(
      installed: load(URL(fileURLWithPath: installedPath)),
      bundled: load(bundleURL.appendingPathComponent(bundledRelativePath, isDirectory: false))
    )
  }

  /// A fixed, privacy-safe token for the definition's launchd process class.
  public static func processTypeToken(_ data: Data?) -> String {
    guard let data else { return "unreadable" }
    guard let definition = dictionary(from: data) else { return "malformed" }
    guard let value = definition["ProcessType"] as? String else { return "unset" }
    switch value {
    case "Standard", "Background", "Adaptive", "Interactive": return value.lowercased()
    default: return "other"
    }
  }

  /// Reads a bounded regular file; symbolic links and oversized files are ignored.
  public static func load(_ url: URL) -> Data? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size > 0,
      size <= maximumSize
    else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func dictionary(from data: Data) -> [String: Any]? {
    guard data.count <= maximumSize else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil))
      as? [String: Any]
  }
}
