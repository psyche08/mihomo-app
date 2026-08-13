import SwiftUI

@MainActor
public struct LogsView: View {
  private enum SortColumn: String {
    case sequence
    case level
    case type
  }

  private enum Grouping: String {
    case none
    case level
    case type
  }

  private enum TableDensity: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case regular = "Regular"
    case comfortable = "Comfortable"

    var id: String { rawValue }

    var verticalPadding: CGFloat {
      switch self {
      case .compact: 5
      case .regular: 8
      case .comfortable: 11
      }
    }
  }

  private struct LogGroup: Identifiable {
    var id: String { key }
    var key: String
    var entries: [DashboardLogEntry]
  }

  @ObservedObject private var store: DashboardStore
  @State private var search = ""
  @State private var sortColumn: SortColumn = .sequence
  @State private var sortDescending = true
  @State private var grouping: Grouping = .none
  @State private var expandedGroups: Set<String> = []
  @State private var expandedRows: Set<UInt64> = []
  @State private var density: TableDensity = .regular

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      logsToolbar

      switch store.logsState {
      case .loaded:
        logsTable
      case .loading, .empty, .failed:
        DashboardPageStateView(state: store.logsState, emptyTitle: "No logs available") {
          Task { await store.refresh(.logs) }
        }
      }
    }
    .padding(DashboardTheme.sectionSpacing)
    .background(DashboardTheme.background)
  }

  private var logsToolbar: some View {
    HStack(spacing: 10) {
      DashboardSearchField("Search", text: $search)
        .frame(maxWidth: .infinity)

      squareButton("trash", help: "Clear local buffer") {
        Task { await store.clearLogs() }
      }
      .disabled(store.logs.isEmpty)

      squareButton("arrow.clockwise", help: "Refresh logs") {
        Task { await store.refresh(.logs) }
      }

      squareButton(
        store.logsPaused ? "play.fill" : "pause.fill",
        help: store.logsPaused ? "Resume log stream" : "Pause log stream",
        highlighted: store.logsPaused
      ) {
        store.setLogsPaused(!store.logsPaused)
      }

      settingsMenu
    }
    .frame(height: 36)
    .accessibilityElement(children: .contain)
  }

  private var settingsMenu: some View {
    Menu {
      Section("Table size") {
        Picker("Table size", selection: $density) {
          ForEach(TableDensity.allCases) { option in
            Text(option.rawValue).tag(option)
          }
        }
      }
      Section("Log level") {
        ForEach(DashboardLogLevel.allCases) { level in
          Button {
            Task { await store.setLogLevel(level) }
          } label: {
            if store.logLevel == level {
              Label(level.rawValue, systemImage: "checkmark")
            } else {
              Text(level.rawValue)
            }
          }
        }
      }
      Section("Grouping") {
        Button("No grouping") { setGrouping(.none) }
        Button("Group by level") { setGrouping(.level) }
        Button("Group by type") { setGrouping(.type) }
      }
      Divider()
      Text("Maximum rows: 500 (session only)")
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DashboardTheme.content)
        .frame(width: 34, height: 34)
        .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(DashboardTheme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Log table settings")
    .accessibilityLabel("Log table settings")
  }

  private var logsTable: some View {
    VStack(spacing: 0) {
      logsHeader
      Divider().overlay(DashboardTheme.divider)

      if sortedLogs.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 28))
          Text(search.isEmpty ? "No logs" : "No matching logs")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(DashboardTheme.muted.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            logRows
          }
        }
      }
    }
    .background(DashboardTheme.surface.opacity(0.64))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var logsHeader: some View {
    HStack(spacing: 12) {
      columnHeader("Sequence", column: .sequence, width: 96)
      columnHeader("Level", column: .level, width: 118, groupable: .level)
      columnHeader("Type", column: .type, width: 120, groupable: .type)
      Text("Payload")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(DashboardTheme.muted)
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(DashboardTheme.surface)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var logRows: some View {
    if grouping == .none {
      ForEach(sortedLogs) { entry in
        logRow(entry)
        Divider().overlay(DashboardTheme.divider.opacity(0.64))
      }
    } else {
      ForEach(logGroups) { group in
        Button {
          toggleExpanded(group.key)
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: expandedGroups.contains(group.key)
                ? "chevron.down" : "chevron.right"
            )
            .font(.system(size: 10, weight: .bold))
            Text(group.key)
              .font(.system(size: 12, weight: .semibold))
            Text("(\(group.entries.count))")
              .font(.system(size: 10))
              .foregroundStyle(DashboardTheme.muted)
            Spacer()
          }
          .foregroundStyle(DashboardTheme.primary)
          .padding(.horizontal, 12)
          .frame(height: 36)
          .background(DashboardTheme.primary.opacity(0.06))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Divider().overlay(DashboardTheme.divider.opacity(0.64))

        if expandedGroups.contains(group.key) {
          ForEach(group.entries) { entry in
            logRow(entry)
            Divider().overlay(DashboardTheme.divider.opacity(0.64))
          }
        }
      }
    }
  }

  private func logRow(_ entry: DashboardLogEntry) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(entry.id.formatted(.number.grouping(.never)))
        .foregroundStyle(DashboardTheme.muted)
        .frame(width: 96, alignment: .leading)
      Text("[\(entry.level.rawValue.lowercased())]")
        .fontWeight(.semibold)
        .foregroundStyle(entry.level.color)
        .frame(width: 118, alignment: .leading)
      Text(logType(entry.message))
        .foregroundStyle(DashboardTheme.muted.opacity(0.78))
        .frame(width: 120, alignment: .leading)
      Text(entry.message)
        .foregroundStyle(DashboardTheme.content)
        .lineLimit(expandedRows.contains(entry.id) ? nil : 1)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 11, design: .monospaced))
    .monospacedDigit()
    .padding(.horizontal, 12)
    .padding(.vertical, density.verticalPadding)
    .contentShape(Rectangle())
    .onTapGesture {
      if expandedRows.contains(entry.id) {
        expandedRows.remove(entry.id)
      } else {
        expandedRows.insert(entry.id)
      }
    }
    .help("\(entry.timestamp.formatted(date: .abbreviated, time: .standard))\n\(entry.message)")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Sequence \(entry.id), \(entry.level.rawValue), \(logType(entry.message)), \(entry.message)"
    )
    .accessibilityHint(expandedRows.contains(entry.id) ? "Collapse payload" : "Expand payload")
  }

  private func columnHeader(
    _ title: String,
    column: SortColumn,
    width: CGFloat,
    groupable: Grouping? = nil
  ) -> some View {
    HStack(spacing: 4) {
      Button {
        updateSort(column)
      } label: {
        HStack(spacing: 4) {
          Text(title)
          Image(
            systemName: sortColumn == column
              ? (sortDescending ? "arrow.down" : "arrow.up") : "arrow.up.arrow.down"
          )
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(
            sortColumn == column ? DashboardTheme.primary : DashboardTheme.muted.opacity(0.42)
          )
        }
      }
      .buttonStyle(.plain)

      if let groupable {
        Button {
          setGrouping(grouping == groupable ? .none : groupable)
        } label: {
          Image(
            systemName: grouping == groupable
              ? "rectangle.3.group.fill" : "rectangle.3.group"
          )
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(
            grouping == groupable ? DashboardTheme.primary : DashboardTheme.muted.opacity(0.58)
          )
        }
        .buttonStyle(.plain)
        .help(grouping == groupable ? "Remove grouping" : "Group by \(title.lowercased())")
      }

      Spacer(minLength: 0)
    }
    .frame(width: width, alignment: .leading)
  }

  private func squareButton(
    _ symbol: String,
    help: String,
    highlighted: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(highlighted ? DashboardTheme.warning : DashboardTheme.content)
    .background(
      highlighted ? DashboardTheme.warning.opacity(0.12) : DashboardTheme.surface.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          highlighted ? DashboardTheme.warning.opacity(0.30) : DashboardTheme.divider,
          lineWidth: 1
        )
    }
    .help(help)
    .accessibilityLabel(help)
  }

  private var sortedLogs: [DashboardLogEntry] {
    let filtered = store.logs.filter { entry in
      let levelMatches =
        store.logLevel == .all || levelRank(entry.level) >= levelRank(store.logLevel)
      guard levelMatches else { return false }
      guard !search.isEmpty else { return true }
      return entry.message.localizedCaseInsensitiveContains(search)
        || entry.level.rawValue.localizedCaseInsensitiveContains(search)
        || logType(entry.message).localizedCaseInsensitiveContains(search)
    }

    return filtered.sorted { lhs, rhs in
      let comparison: ComparisonResult
      switch sortColumn {
      case .sequence:
        if lhs.id == rhs.id {
          comparison = .orderedSame
        } else {
          comparison = lhs.id < rhs.id ? .orderedAscending : .orderedDescending
        }
      case .level:
        comparison = lhs.level.rawValue.localizedStandardCompare(rhs.level.rawValue)
      case .type:
        comparison = logType(lhs.message).localizedStandardCompare(logType(rhs.message))
      }

      if comparison == .orderedSame { return lhs.id > rhs.id }
      return sortDescending ? comparison == .orderedDescending : comparison == .orderedAscending
    }
  }

  private var logGroups: [LogGroup] {
    let grouped = Dictionary(grouping: sortedLogs) { entry in
      switch grouping {
      case .none: ""
      case .level: entry.level.rawValue
      case .type: logType(entry.message)
      }
    }
    return grouped.keys.sorted().map { key in
      LogGroup(key: key, entries: grouped[key] ?? [])
    }
  }

  private func logType(_ payload: String) -> String {
    guard payload.first == "[", let end = payload.firstIndex(of: "]"), end > payload.startIndex
    else {
      return "—"
    }
    let start = payload.index(after: payload.startIndex)
    let type = String(payload[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return type.isEmpty ? "—" : type
  }

  private func levelRank(_ level: DashboardLogLevel) -> Int {
    switch level {
    case .all, .debug: 0
    case .info: 1
    case .warning: 2
    case .error: 3
    }
  }

  private func updateSort(_ column: SortColumn) {
    if sortColumn == column {
      sortDescending.toggle()
    } else {
      sortColumn = column
      sortDescending = true
    }
  }

  private func setGrouping(_ newGrouping: Grouping) {
    grouping = newGrouping
    expandedGroups.removeAll()
  }

  private func toggleExpanded(_ key: String) {
    if expandedGroups.contains(key) {
      expandedGroups.remove(key)
    } else {
      expandedGroups.insert(key)
    }
  }
}
