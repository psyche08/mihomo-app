import Foundation
import SwiftUI

@MainActor
public struct ConnectionsView: View {
  private enum Scope: String, CaseIterable, Identifiable {
    case active = "Active"
    case closed = "Closed"

    var id: String { rawValue }
  }

  private enum SortColumn: String, CaseIterable, Identifiable {
    case time = "Time"
    case host = "Host"
    case downloadSpeed = "Download speed"
    case uploadSpeed = "Upload speed"
    case traffic = "Traffic"

    var id: String { rawValue }
  }

  @ObservedObject private var store: DashboardStore
  @State private var scope: Scope = .active
  @State private var search = ""
  @State private var quickFilterEnabled = false
  @State private var sourceFilter = "All"
  @State private var sortColumn: SortColumn = .time
  @State private var sortDescending = true
  @State private var currentPage = 0
  @State private var pageSize = 50
  @State private var selectedConnection: DashboardConnection?
  @State private var showingSettings = false
  @State private var compactRows = true
  @State private var closingConnections = false

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar

      switch store.connectionsState {
      case .loaded:
        loadedContent
      case .loading, .empty, .failed:
        DashboardPageStateView(
          state: store.connectionsState,
          emptyTitle: "No connection data"
        ) {
          Task { await store.refresh(.connections) }
        }
      }
    }
    .padding(DashboardTheme.spacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DashboardTheme.background)
    .sheet(item: $selectedConnection) { connection in
      connectionDetail(connection)
    }
    .onChange(of: scope) { _, _ in currentPage = 0 }
    .onChange(of: search) { _, _ in currentPage = 0 }
    .onChange(of: quickFilterEnabled) { _, _ in currentPage = 0 }
    .onChange(of: sourceFilter) { _, _ in currentPage = 0 }
    .onChange(of: sortColumn) { _, _ in currentPage = 0 }
    .onChange(of: pageSize) { _, _ in currentPage = 0 }
    .onChange(of: filteredConnections.count) { _, _ in clampCurrentPage() }
  }

  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        scopeTabs
        quickFilterControl
        networkMenu
        sortMenu
        sortDirectionButton
        DashboardSearchField("Search", text: $search)
          .frame(maxWidth: .infinity)
        streamActions
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          scopeTabs
          quickFilterControl
          networkMenu
          Spacer(minLength: 2)
          streamActions
        }
        HStack(spacing: 8) {
          sortMenu
          sortDirectionButton
          DashboardSearchField("Search", text: $search)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var scopeTabs: some View {
    HStack(spacing: 4) {
      ForEach(Scope.allCases) { item in
        Button {
          scope = item
        } label: {
          HStack(spacing: 7) {
            Text(item.rawValue)
              .font(.system(size: 13, weight: .semibold))
            Text(scopeCount(item).formatted())
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .monospacedDigit()
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                (scope == item ? Color.black.opacity(0.16) : DashboardTheme.content.opacity(0.08)),
                in: Capsule()
              )
          }
          .foregroundStyle(scope == item ? DashboardTheme.primaryContent : DashboardTheme.muted)
          .padding(.horizontal, 11)
          .frame(height: 34)
          .background(
            scope == item ? DashboardTheme.primary : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private var quickFilterControl: some View {
    Toggle("Quick Filter", isOn: $quickFilterEnabled)
      .toggleStyle(.switch)
      .controlSize(.mini)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(DashboardTheme.muted)
      .fixedSize()
      .help("Show connections currently transferring data")
  }

  private var networkMenu: some View {
    Menu {
      Button("All") { sourceFilter = "All" }
      ForEach(sourceOptions, id: \.self) { source in
        Button(source) { sourceFilter = source }
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "desktopcomputer")
        Text(sourceFilter)
          .lineLimit(1)
      }
      .toolbarControl()
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Filter by source")
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort connections", selection: $sortColumn) {
        ForEach(SortColumn.allCases) { column in
          Text(column.rawValue).tag(column)
        }
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "arrow.up.arrow.down")
        Text("Sort by")
          .foregroundStyle(DashboardTheme.muted)
        Text(sortColumn.rawValue)
          .lineLimit(1)
      }
      .toolbarControl()
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var sortDirectionButton: some View {
    Button {
      sortDescending.toggle()
    } label: {
      toolbarIcon(
        sortDescending ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle")
    }
    .buttonStyle(.plain)
    .help(sortDescending ? "Descending" : "Ascending")
  }

  private var streamActions: some View {
    HStack(spacing: 6) {
      Button {
        store.setConnectionsPaused(!store.connectionsPaused)
      } label: {
        toolbarIcon(
          store.connectionsPaused ? "play.fill" : "pause.fill", warning: store.connectionsPaused)
      }
      .buttonStyle(.plain)
      .help(store.connectionsPaused ? "Resume stream" : "Pause stream")

      Button {
        Task { await closeVisibleConnections() }
      } label: {
        toolbarIcon("xmark", danger: true, active: closingConnections)
      }
      .buttonStyle(.plain)
      .disabled(scope != .active || filteredConnections.isEmpty || closingConnections)
      .help(hasConnectionFilters ? "Close filtered connections" : "Close all connections")

      settingsButton
    }
  }

  private var settingsButton: some View {
    Button {
      showingSettings.toggle()
    } label: {
      toolbarIcon("gearshape")
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingSettings, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Connections table")
          .font(.system(size: 14, weight: .semibold))
        Toggle("Compact rows", isOn: $compactRows)
        Picker("Rows per page", selection: $pageSize) {
          ForEach([20, 50, 100, 200], id: \.self) { size in
            Text("\(size) rows").tag(size)
          }
        }
        Divider()
        Button {
          showingSettings = false
          Task { await store.refresh(.connections) }
        } label: {
          Label("Refresh controller data", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(DashboardTheme.content)
      .padding(16)
      .frame(width: 240)
      .background(DashboardTheme.surface)
    }
  }

  private func toolbarIcon(
    _ symbol: String,
    warning: Bool = false,
    danger: Bool = false,
    active: Bool = false
  ) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(
        danger
          ? DashboardTheme.error
          : warning
            ? DashboardTheme.warning
            : active
              ? DashboardTheme.success
              : DashboardTheme.muted
      )
      .frame(width: 32, height: 32)
      .background(
        danger ? DashboardTheme.error.opacity(0.08) : DashboardTheme.surface,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            danger ? DashboardTheme.error.opacity(0.18) : DashboardTheme.divider, lineWidth: 1)
      }
  }

  @ViewBuilder
  private var loadedContent: some View {
    if filteredConnections.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: sourceConnections.isEmpty
            ? "There are no \(scope.rawValue.lowercased()) connections."
            : "No connection matches the current filters."
        ),
        emptyTitle: "No matching connections"
      ) {
        clearFilters()
      }
    } else {
      VStack(spacing: 10) {
        connectionTable
        paginationBar
      }
    }
  }

  private var connectionTable: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          Section {
            ForEach(pagedConnections) { connection in
              connectionRow(connection)
              Divider().overlay(DashboardTheme.divider)
            }
          } header: {
            connectionHeader
              .background(DashboardTheme.surface)
          }
        }
        .frame(
          minWidth: 980,
          minHeight: geometry.size.height,
          alignment: .topLeading
        )
      }
    }
    .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private var connectionHeader: some View {
    HStack(spacing: 10) {
      Text("CLOSE").frame(width: 42, alignment: .leading)
      sortableHeader("TIME", column: .time).frame(width: 110, alignment: .leading)
      sortableHeader("HOST / PROCESS", column: .host).frame(width: 220, alignment: .leading)
      Text("RULE / CHAINS").frame(width: 230, alignment: .leading)
      sortableHeader("TRAFFIC", column: .downloadSpeed).frame(width: 190, alignment: .leading)
      Text("FLOW").frame(width: 170, alignment: .leading)
    }
    .font(.system(size: 10, weight: .bold))
    .foregroundStyle(DashboardTheme.muted)
    .padding(.horizontal, 10)
    .frame(height: 35)
    .accessibilityHidden(true)
  }

  private func sortableHeader(_ title: String, column: SortColumn) -> some View {
    Button {
      if sortColumn == column {
        sortDescending.toggle()
      } else {
        sortColumn = column
        sortDescending = true
      }
    } label: {
      HStack(spacing: 5) {
        Text(title)
        if sortColumn == column {
          Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
            .foregroundStyle(DashboardTheme.primary)
        }
      }
    }
    .buttonStyle(.plain)
  }

  private func connectionRow(_ connection: DashboardConnection) -> some View {
    HStack(spacing: 10) {
      Group {
        if scope == .active {
          Button {
            Task { await store.closeConnection(connection.id) }
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(DashboardTheme.error)
              .frame(width: 24, height: 24)
              .background(DashboardTheme.error.opacity(0.1), in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close connection to \(hostLabel(connection))")
        } else {
          Color.clear.frame(width: 24, height: 24)
        }
      }
      .frame(width: 42, alignment: .leading)

      Text(relativeTime(connection.startedAt))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(DashboardTheme.content)
        .lineLimit(1)
        .frame(width: 110, alignment: .leading)

      twoLineCell(
        primary: hostLabel(connection),
        secondary: processLabel(connection)
      )
      .frame(width: 220, alignment: .leading)

      twoLineCell(
        primary: connection.rule.isEmpty ? "—" : connection.rule,
        secondary: chainLabel(connection)
      )
      .frame(width: 230, alignment: .leading)

      twoLineCell(
        primary:
          "↓ \(DashboardFormat.speed(connection.downloadSpeed)) · ↑ \(DashboardFormat.speed(connection.uploadSpeed))",
        secondary:
          "∑ ↓\(DashboardFormat.bytes(connection.downloadBytes)) · ↑\(DashboardFormat.bytes(connection.uploadBytes))"
      )
      .frame(width: 190, alignment: .leading)
      .monospacedDigit()

      twoLineCell(
        primary: flowSource(connection),
        secondary: "→ \(destinationLabel(connection))"
      )
      .frame(width: 170, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .frame(height: compactRows ? 52 : 64)
    .contentShape(Rectangle())
    .onTapGesture { selectedConnection = connection }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Connection to \(hostLabel(connection))")
    .accessibilityHint("Show connection details")
  }

  private func twoLineCell(primary: String, secondary: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(primary)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DashboardTheme.content)
        .lineLimit(1)
      Text(secondary.isEmpty ? "—" : secondary)
        .font(.system(size: 9))
        .foregroundStyle(DashboardTheme.muted)
        .lineLimit(1)
    }
  }

  private var paginationBar: some View {
    HStack(spacing: 12) {
      Picker("Rows per page", selection: $pageSize) {
        ForEach([20, 50, 100, 200], id: \.self) { size in
          Text(size.formatted()).tag(size)
        }
      }
      .labelsHidden()
      .frame(width: 72)

      Text(paginationInfo)
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(DashboardTheme.muted)

      Spacer(minLength: 8)
      paginationControls
    }
  }

  private var paginationControls: some View {
    HStack(spacing: 0) {
      pageButton("chevron.left.2", disabled: currentPage == 0) { currentPage = 0 }
      pageButton("chevron.left", disabled: currentPage == 0) { currentPage -= 1 }
      ForEach(visiblePages, id: \.self) { page in
        Button {
          currentPage = page
        } label: {
          Text((page + 1).formatted())
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(
              currentPage == page ? DashboardTheme.primaryContent : DashboardTheme.muted
            )
            .frame(minWidth: 29, minHeight: 28)
            .background(currentPage == page ? DashboardTheme.primary : DashboardTheme.surface)
        }
        .buttonStyle(.plain)
      }
      pageButton("chevron.right", disabled: currentPage >= totalPages - 1) { currentPage += 1 }
      pageButton("chevron.right.2", disabled: currentPage >= totalPages - 1) {
        currentPage = totalPages - 1
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private func pageButton(
    _ symbol: String,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(DashboardTheme.muted)
        .frame(width: 28, height: 28)
        .background(DashboardTheme.surface)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.38 : 1)
  }

  private func connectionDetail(_ selection: DashboardConnection) -> some View {
    TimelineView(.periodic(from: Date(), by: 1)) { _ in
      connectionDetailContent(liveConnection(for: selection))
    }
  }

  private func connectionDetailContent(_ connection: DashboardConnection) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(hostLabel(connection))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(DashboardTheme.content)
          Text(destinationLabel(connection))
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.muted)
        }
        Spacer()
        let transport =
          [connection.connectionType, connection.network]
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
          .uppercased()
        if !transport.isEmpty {
          StatusPill(transport, color: DashboardTheme.info)
        }
      }
      .padding(24)

      Divider().overlay(DashboardTheme.divider)

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          detailSection(
            "Endpoint",
            rows: [
              ("Source", flowSource(connection)),
              ("Destination", destinationLabel(connection)),
              ("Sniff host", connection.sniffHost ?? ""),
              ("Inbound", inboundLabel(connection)),
              ("DNS mode", connection.dnsMode),
            ]
          )

          detailSection(
            "Process",
            rows: [
              ("Process", connection.process ?? ""),
              ("Process path", connection.processPath ?? ""),
              ("User", connection.user),
              ("UID", connection.uid.map { String($0) } ?? ""),
            ]
          )

          detailSection(
            "Routing",
            rows: [
              ("Rule", connection.rule),
              ("Rule payload", connection.rulePayload),
              ("Chain", chainLabel(connection)),
              ("Special proxy", connection.specialProxy),
              ("Special rules", connection.specialRules),
            ]
          )

          detailSection(
            "Session",
            rows: [
              ("Original ID", connection.id),
              ("Start", exactStart(connection.startedAt)),
              ("Duration", DashboardFormat.duration(since: connection.startedAt)),
              (
                "Live speed",
                "↓ \(DashboardFormat.speed(connection.downloadSpeed)) · ↑ \(DashboardFormat.speed(connection.uploadSpeed))"
              ),
              (
                "Traffic",
                "↓ \(DashboardFormat.bytes(connection.downloadBytes)) · ↑ \(DashboardFormat.bytes(connection.uploadBytes))"
              ),
            ]
          )
        }
        .padding(24)
      }

      Divider().overlay(DashboardTheme.divider)

      HStack {
        Spacer()
        if isConnectionActive(connection.id) {
          Button("Close Connection") {
            Task {
              if await store.closeConnection(connection.id) {
                selectedConnection = nil
              }
            }
          }
          .buttonStyle(DashboardPrimaryButtonStyle())
        }
        Button("Done") { selectedConnection = nil }
          .buttonStyle(DashboardSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
    }
    .frame(width: 620)
    .frame(minHeight: 560, idealHeight: 680, maxHeight: 720)
    .background(DashboardTheme.background)
  }

  @ViewBuilder
  private func detailSection(_ title: String, rows: [(String, String)]) -> some View {
    let visibleRows = rows.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !visibleRows.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(title.uppercased())
          .font(.system(size: 10, weight: .black))
          .tracking(0.9)
          .foregroundStyle(DashboardTheme.primary)
        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
            detailRow(row.0, row.1)
          }
        }
        .padding(14)
        .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(DashboardTheme.divider, lineWidth: 1)
        }
      }
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DashboardTheme.muted)
        .frame(width: 92, alignment: .leading)
      Text(value.isEmpty ? "—" : value)
        .font(.system(size: 11))
        .foregroundStyle(DashboardTheme.content)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private var sourceConnections: [DashboardConnection] {
    scope == .active ? store.presentedActiveConnections : store.presentedClosedConnections
  }

  private var filteredConnections: [DashboardConnection] {
    var result = sourceConnections.filter { connection in
      let sourceMatches =
        sourceFilter == "All"
        || connection.source.caseInsensitiveCompare(sourceFilter) == .orderedSame
      let quickMatches =
        !quickFilterEnabled
        || connection.downloadSpeed > 0
        || connection.uploadSpeed > 0
      let searchMatches =
        search.isEmpty
        || searchableText(connection)
          .localizedCaseInsensitiveContains(search)
      return sourceMatches && quickMatches && searchMatches
    }

    result.sort { lhs, rhs in
      let comparison: ComparisonResult
      switch sortColumn {
      case .time:
        comparison = lhs.startedAt.compare(rhs.startedAt)
      case .host:
        comparison = hostLabel(lhs).localizedStandardCompare(hostLabel(rhs))
      case .downloadSpeed:
        comparison = compare(lhs.downloadSpeed, rhs.downloadSpeed)
      case .uploadSpeed:
        comparison = compare(lhs.uploadSpeed, rhs.uploadSpeed)
      case .traffic:
        comparison = compare(
          lhs.downloadBytes + lhs.uploadBytes,
          rhs.downloadBytes + rhs.uploadBytes
        )
      }
      if comparison == .orderedSame {
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
      }
      return sortDescending
        ? comparison == .orderedDescending
        : comparison == .orderedAscending
    }
    return result
  }

  private var pagedConnections: [DashboardConnection] {
    let start = min(currentPage * pageSize, filteredConnections.count)
    let end = min(start + pageSize, filteredConnections.count)
    return Array(filteredConnections[start..<end])
  }

  private var totalPages: Int {
    max(1, Int(ceil(Double(filteredConnections.count) / Double(pageSize))))
  }

  private var visiblePages: [Int] {
    let lower = max(0, currentPage - 1)
    let upper = min(totalPages - 1, currentPage + 1)
    return Array(lower...upper)
  }

  private var paginationInfo: String {
    guard !filteredConnections.isEmpty else { return "0 / 0" }
    let start = currentPage * pageSize + 1
    let end = min((currentPage + 1) * pageSize, filteredConnections.count)
    return "\(start)–\(end) / \(filteredConnections.count)"
  }

  private var sourceOptions: [String] {
    Array(Set(sourceConnections.map(\.source).filter { !$0.isEmpty })).sorted()
  }

  private var hasConnectionFilters: Bool {
    !search.isEmpty || quickFilterEnabled || sourceFilter != "All"
  }

  private func scopeCount(_ item: Scope) -> Int {
    switch item {
    case .active: store.presentedActiveConnections.count
    case .closed: store.presentedClosedConnections.count
    }
  }

  private func searchableText(_ connection: DashboardConnection) -> String {
    [
      connection.host,
      connection.destination,
      connection.destinationIP,
      connection.process ?? "",
      connection.processPath ?? "",
      connection.rule,
      connection.rulePayload,
      connection.connectionType,
      connection.network,
      connection.source,
      connection.user,
      connection.dnsMode,
      connection.inboundIP,
      connection.inboundPort,
      connection.specialProxy,
      connection.specialRules,
      connection.sniffHost ?? "",
      connection.inboundName ?? "",
      connection.chains.joined(separator: " "),
    ].joined(separator: " ")
  }

  private func hostLabel(_ connection: DashboardConnection) -> String {
    let base = connection.host.isEmpty ? destinationLabel(connection) : connection.host
    guard !connection.destinationPort.isEmpty,
      !base.hasSuffix(":\(connection.destinationPort)")
    else { return base }
    return "\(base):\(connection.destinationPort)"
  }

  private func processLabel(_ connection: DashboardConnection) -> String {
    if let process = connection.process, !process.isEmpty { return process }
    if let path = connection.processPath, !path.isEmpty {
      return (path as NSString).lastPathComponent
    }
    return "—"
  }

  private func destinationLabel(_ connection: DashboardConnection) -> String {
    if !connection.destination.isEmpty { return connection.destination }
    guard !connection.destinationIP.isEmpty else { return "Unknown" }
    return connection.destinationPort.isEmpty
      ? connection.destinationIP
      : "\(connection.destinationIP):\(connection.destinationPort)"
  }

  private func flowSource(_ connection: DashboardConnection) -> String {
    let source = connection.source.isEmpty ? "Local device" : connection.source
    return connection.sourcePort.isEmpty ? source : "\(source):\(connection.sourcePort)"
  }

  private func chainLabel(_ connection: DashboardConnection) -> String {
    connection.chains.isEmpty ? "DIRECT" : connection.chains.reversed().joined(separator: " → ")
  }

  private func inboundLabel(_ connection: DashboardConnection) -> String {
    let name = connection.inboundName ?? ""
    let address = addressLabel(connection.inboundIP, port: connection.inboundPort)
    return [name, address].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func addressLabel(_ address: String, port: String) -> String {
    guard !address.isEmpty else { return "" }
    return port.isEmpty ? address : "\(address):\(port)"
  }

  private func exactStart(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
    return formatter.string(from: date)
  }

  private func liveConnection(for selection: DashboardConnection) -> DashboardConnection {
    store.presentedActiveConnections.first(where: { $0.id == selection.id })
      ?? store.presentedClosedConnections.first(where: { $0.id == selection.id })
      ?? selection
  }

  private func isConnectionActive(_ id: String) -> Bool {
    store.presentedActiveConnections.contains(where: { $0.id == id })
  }

  private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private func clearFilters() {
    search = ""
    quickFilterEnabled = false
    sourceFilter = "All"
  }

  private func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
  }

  private func clampCurrentPage() {
    currentPage = min(currentPage, totalPages - 1)
  }

  private func closeVisibleConnections() async {
    guard scope == .active, !closingConnections else { return }
    closingConnections = true
    defer { closingConnections = false }
    if hasConnectionFilters {
      for connection in filteredConnections {
        await store.closeConnection(connection.id)
      }
    } else {
      await store.closeAllConnections()
    }
  }
}

extension View {
  fileprivate func toolbarControl() -> some View {
    font(.system(size: 11, weight: .semibold))
      .foregroundStyle(DashboardTheme.content)
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
  }
}
