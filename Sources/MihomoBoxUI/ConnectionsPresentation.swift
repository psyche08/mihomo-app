import Foundation

struct ConnectionClientGroup: Identifiable, Equatable, Sendable {
  var id: String
  var name: String
  var applicationBundlePath: String?
  var activeCount: Int
  var recentCount: Int
  var uploadSpeed: Int64
  var downloadSpeed: Int64
}

enum ConnectionsPresentation {
  static let unknownClientName = "Unknown Process"

  static func recent(
    active: [DashboardConnection],
    closed: [DashboardConnection]
  ) -> [DashboardConnection] {
    let activeIDs = Set(active.map(\.id))
    return (active + closed.filter { !activeIDs.contains($0.id) })
      .sorted { lhs, rhs in
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
      }
  }

  static func clientGroups(
    active: [DashboardConnection],
    closed: [DashboardConnection]
  ) -> [ConnectionClientGroup] {
    let activeIDs = Set(active.map(\.id))
    var groups: [String: ConnectionClientGroup] = [:]
    for connection in recent(active: active, closed: closed) {
      let name = clientName(for: connection)
      let id = clientID(for: connection)
      let applicationBundlePath = applicationBundlePath(for: connection)
      var group =
        groups[id]
        ?? ConnectionClientGroup(
          id: id,
          name: name,
          applicationBundlePath: applicationBundlePath,
          activeCount: 0,
          recentCount: 0,
          uploadSpeed: 0,
          downloadSpeed: 0
        )
      group.recentCount += 1
      if activeIDs.contains(connection.id) {
        group.activeCount += 1
        group.uploadSpeed += max(connection.uploadSpeed, 0)
        group.downloadSpeed += max(connection.downloadSpeed, 0)
      }
      groups[id] = group
    }
    return groups.values.sorted { lhs, rhs in
      let lhsActive = lhs.activeCount > 0
      let rhsActive = rhs.activeCount > 0
      if lhsActive != rhsActive { return lhsActive }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  static func clientID(for connection: DashboardConnection) -> String {
    if let applicationBundlePath = applicationBundlePath(for: connection) {
      return "application:\(normalizedIdentity(applicationBundlePath))"
    }
    return "process:\(normalizedIdentity(processName(for: connection)))"
  }

  static func clientName(for connection: DashboardConnection) -> String {
    if let applicationBundlePath = applicationBundlePath(for: connection) {
      let bundleName = ((applicationBundlePath as NSString).lastPathComponent as NSString)
        .deletingPathExtension
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !bundleName.isEmpty { return bundleName }
    }
    return processName(for: connection)
  }

  static func processName(for connection: DashboardConnection) -> String {
    if let process = connection.process?.trimmingCharacters(in: .whitespacesAndNewlines),
      !process.isEmpty
    {
      return process
    }
    if let path = connection.processPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    {
      let name = (path as NSString).lastPathComponent
      if !name.isEmpty { return name }
    }
    return unknownClientName
  }

  /// Returns the outermost App bundle that owns the reported executable. Helper
  /// executables frequently live in a nested `Helper.app`; using the first
  /// `.app` component keeps the main process and every helper in one client.
  static func applicationBundlePath(for connection: DashboardConnection) -> String? {
    guard
      let rawPath = connection.processPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawPath.isEmpty
    else { return nil }

    let standardizedPath = (rawPath as NSString).standardizingPath
    let components = (standardizedPath as NSString).pathComponents
    var candidate = components.first == "/" ? "/" : ""
    for component in components where component != "/" {
      candidate = (candidate as NSString).appendingPathComponent(component)
      if (component as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame {
        return candidate
      }
    }
    return nil
  }

  private static func normalizedIdentity(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}
