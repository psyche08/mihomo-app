import Foundation

struct ConnectionClientGroup: Identifiable, Equatable, Sendable {
  var id: String
  var name: String
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
      var group =
        groups[id]
        ?? ConnectionClientGroup(
          id: id,
          name: name,
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
    clientName(for: connection).folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
  }

  static func clientName(for connection: DashboardConnection) -> String {
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
}
