import Foundation
import SwiftUI

@MainActor
public struct ConnectionsView: View {
  private enum Scope: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case active = "Active"
    case closed = "Closed"

    var id: String { rawValue }
  }

  @ObservedObject private var store: DashboardStore
  @State private var scope: Scope = .recent
  @State private var selectedClientID: String?
  @State private var search = ""
  @State private var quickFilterEnabled = false
  @State private var selectedConnection: DashboardConnection?
  @State private var showingSettings = false
  @State private var compactRows = true
  @State private var closingConnections = false

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    Group {
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
    .padding(DashboardTheme.sectionSpacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DashboardTheme.background)
    .sheet(item: $selectedConnection) { connection in
      connectionDetail(connection)
    }
    .onChange(of: clientGroups.map(\.id)) { _, ids in
      if let selectedClientID, !ids.contains(selectedClientID) {
        self.selectedClientID = nil
      }
    }
  }

  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        scopeTabs
        quickFilterControl
        DashboardSearchField("Search", text: $search)
          .frame(maxWidth: .infinity)
        streamActions
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          scopeTabs
          quickFilterControl
          Spacer(minLength: 2)
          streamActions
        }
        DashboardSearchField("Search", text: $search)
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
    Toggle("Transferring", isOn: $quickFilterEnabled)
      .toggleStyle(.switch)
      .controlSize(.mini)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(DashboardTheme.muted)
      .fixedSize()
      .help("Show connections currently transferring data")
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
      .disabled(activeVisibleConnections.isEmpty || closingConnections)
      .help(hasConnectionFilters ? "Close filtered active connections" : "Close all connections")

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
        Text("Recent connections")
          .font(.system(size: 14, weight: .semibold))
        Toggle("Compact rows", isOn: $compactRows)
        Text("Up to 500 recently closed connections are kept for this UI session.")
          .font(.system(size: 10))
          .foregroundStyle(DashboardTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
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
    if recentConnections.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: "Recent active and closed connections will appear here."
        ),
        emptyTitle: "No recent connections"
      ) {
        Task { await store.refresh(.connections) }
      }
    } else {
      HStack(spacing: 0) {
        clientsPane
          .frame(minWidth: 205, idealWidth: 230, maxWidth: 260)
        Divider().overlay(DashboardTheme.divider)
        recentPane
      }
      .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  private var clientsPane: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("CLIENTS")
            .font(.system(size: 10, weight: .black))
            .tracking(0.9)
            .foregroundStyle(DashboardTheme.primary)
          Text("Grouped by process")
            .font(.system(size: 10))
            .foregroundStyle(DashboardTheme.muted)
        }
        Spacer(minLength: 8)
        Text(clientGroups.count.formatted())
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(DashboardTheme.muted)
      }
      .padding(.horizontal, 14)
      .frame(height: 58)

      Divider().overlay(DashboardTheme.divider)

      ScrollView {
        LazyVStack(spacing: 5) {
          clientButton(
            id: nil,
            name: "All Clients",
            symbol: "square.grid.2x2.fill",
            activeCount: store.presentedActiveConnections.count,
            recentCount: recentConnections.count,
            uploadSpeed: totalActiveUploadSpeed,
            downloadSpeed: totalActiveDownloadSpeed
          )

          ForEach(clientGroups) { group in
            clientButton(
              id: group.id,
              name: group.name,
              symbol: clientSymbol(group.name),
              activeCount: group.activeCount,
              recentCount: group.recentCount,
              uploadSpeed: group.uploadSpeed,
              downloadSpeed: group.downloadSpeed
            )
          }
        }
        .padding(8)
      }

      Divider().overlay(DashboardTheme.divider)

      HStack(spacing: 7) {
        Circle()
          .fill(store.connectionsPaused ? DashboardTheme.warning : DashboardTheme.success)
          .frame(width: 7, height: 7)
        Text(store.connectionsPaused ? "Stream paused" : "Live stream")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DashboardTheme.muted)
        Spacer()
      }
      .padding(.horizontal, 14)
      .frame(height: 36)
    }
  }

  private func clientButton(
    id: String?,
    name: String,
    symbol: String,
    activeCount: Int,
    recentCount: Int,
    uploadSpeed: Int64,
    downloadSpeed: Int64
  ) -> some View {
    let selected = selectedClientID == id
    return Button {
      selectedClientID = id
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(selected ? DashboardTheme.primaryContent : DashboardTheme.primary)
          .frame(width: 30, height: 30)
          .background(
            selected ? Color.white.opacity(0.16) : DashboardTheme.primary.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 8)
          )

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(name)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
            Spacer(minLength: 4)
            Text(activeCount > 0 ? activeCount.formatted() : recentCount.formatted())
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(selected ? DashboardTheme.primaryContent : DashboardTheme.muted)
          }
          Text(
            activeCount > 0
              ? "↓ \(DashboardFormat.speed(downloadSpeed))  ↑ \(DashboardFormat.speed(uploadSpeed))"
              : "\(recentCount.formatted()) recent"
          )
          .font(.system(size: 9, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(
            selected ? DashboardTheme.primaryContent.opacity(0.74) : DashboardTheme.muted
          )
          .lineLimit(1)
        }
      }
      .foregroundStyle(selected ? DashboardTheme.primaryContent : DashboardTheme.content)
      .padding(.horizontal, 9)
      .frame(height: compactRows ? 48 : 56)
      .background(
        selected ? DashboardTheme.primary : Color.clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name), \(activeCount) active, \(recentCount) recent")
  }

  private var recentPane: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Recent Connections")
              .font(.system(size: 17, weight: .bold))
              .foregroundStyle(DashboardTheme.content)
            Text(selectedClientName)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardTheme.muted)
          }
          Spacer(minLength: 8)
          Text("\(filteredConnections.count.formatted()) shown")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardTheme.muted)
        }
        toolbar
      }
      .padding(14)

      Divider().overlay(DashboardTheme.divider)

      if filteredConnections.isEmpty {
        DashboardPageStateView(
          state: .empty(message: "No connection matches this client and the current filters."),
          emptyTitle: "No matching connections"
        ) {
          clearFilters()
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filteredConnections) { connection in
              connectionRow(connection)
              Divider().overlay(DashboardTheme.divider)
            }
          }
        }
      }
    }
  }

  private func connectionRow(_ connection: DashboardConnection) -> some View {
    HStack(spacing: 12) {
      Image(systemName: clientSymbol(processLabel(connection)))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(
          isConnectionActive(connection.id) ? DashboardTheme.success : DashboardTheme.muted
        )
        .frame(width: 30, height: 30)
        .background(
          (isConnectionActive(connection.id) ? DashboardTheme.success : DashboardTheme.muted)
            .opacity(0.09),
          in: RoundedRectangle(cornerRadius: 8)
        )

      VStack(alignment: .leading, spacing: 4) {
        Text(hostLabel(connection))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
          .lineLimit(1)
        Text("\(processLabel(connection)) · \(connection.network.uppercased())")
          .font(.system(size: 9))
          .foregroundStyle(DashboardTheme.muted)
          .lineLimit(1)
      }
      .frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(chainLabel(connection))
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
          .lineLimit(1)
        Text(connection.rule.isEmpty ? "No rule" : connection.rule)
          .font(.system(size: 9))
          .foregroundStyle(DashboardTheme.muted)
          .lineLimit(1)
      }
      .frame(width: 115, alignment: .leading)

      VStack(alignment: .trailing, spacing: 4) {
        Text(
          "↓ \(DashboardFormat.speed(connection.downloadSpeed))  ↑ \(DashboardFormat.speed(connection.uploadSpeed))"
        )
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(DashboardTheme.content)
        .lineLimit(1)
        Text(
          "\(DashboardFormat.bytes(connection.downloadBytes + connection.uploadBytes)) · \(relativeTime(connection.startedAt))"
        )
        .font(.system(size: 9, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(DashboardTheme.muted)
        .lineLimit(1)
      }
      .frame(width: 155, alignment: .trailing)

      if isConnectionActive(connection.id) {
        Button {
          Task { await store.closeConnection(connection.id) }
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DashboardTheme.error)
            .frame(width: 26, height: 26)
            .background(DashboardTheme.error.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close connection to \(hostLabel(connection))")
      } else {
        Text("CLOSED")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardTheme.muted)
          .frame(width: 42)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: compactRows ? 56 : 68)
    .contentShape(Rectangle())
    .onTapGesture { selectedConnection = connection }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Connection to \(hostLabel(connection))")
    .accessibilityHint("Show connection details")
  }

  private func clientSymbol(_ name: String) -> String {
    let normalized = name.lowercased()
    if normalized.contains("safari") || normalized.contains("chrome")
      || normalized.contains("firefox")
    {
      return "safari.fill"
    }
    if normalized.contains("terminal") || normalized.contains("iterm")
      || normalized.contains("ssh")
    {
      return "terminal.fill"
    }
    if normalized.contains("code") || normalized.contains("xcode") {
      return "chevron.left.forwardslash.chevron.right"
    }
    return "app.fill"
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

  private var recentConnections: [DashboardConnection] {
    ConnectionsPresentation.recent(
      active: store.presentedActiveConnections,
      closed: store.presentedClosedConnections
    )
  }

  private var clientGroups: [ConnectionClientGroup] {
    ConnectionsPresentation.clientGroups(
      active: store.presentedActiveConnections,
      closed: store.presentedClosedConnections
    )
  }

  private var scopeConnections: [DashboardConnection] {
    switch scope {
    case .recent: recentConnections
    case .active: store.presentedActiveConnections
    case .closed: store.presentedClosedConnections
    }
  }

  private var filteredConnections: [DashboardConnection] {
    scopeConnections.filter { connection in
      let clientMatches =
        selectedClientID == nil
        || ConnectionsPresentation.clientID(for: connection) == selectedClientID
      let quickMatches =
        !quickFilterEnabled
        || connection.downloadSpeed > 0
        || connection.uploadSpeed > 0
      let searchMatches =
        search.isEmpty
        || searchableText(connection).localizedCaseInsensitiveContains(search)
      return clientMatches && quickMatches && searchMatches
    }
    .sorted { lhs, rhs in
      if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
      return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
  }

  private var activeVisibleConnections: [DashboardConnection] {
    let activeIDs = Set(store.presentedActiveConnections.map(\.id))
    return filteredConnections.filter { activeIDs.contains($0.id) }
  }

  private var totalActiveUploadSpeed: Int64 {
    store.presentedActiveConnections.reduce(0) { $0 + max($1.uploadSpeed, 0) }
  }

  private var totalActiveDownloadSpeed: Int64 {
    store.presentedActiveConnections.reduce(0) { $0 + max($1.downloadSpeed, 0) }
  }

  private var selectedClientName: String {
    guard let selectedClientID else { return "All Clients" }
    return clientGroups.first(where: { $0.id == selectedClientID })?.name ?? "All Clients"
  }

  private var hasConnectionFilters: Bool {
    !search.isEmpty || quickFilterEnabled || selectedClientID != nil || scope != .recent
  }

  private func scopeCount(_ item: Scope) -> Int {
    switch item {
    case .recent: recentConnections.count
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
    ConnectionsPresentation.clientName(for: connection)
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
    selectedClientID = nil
    scope = .recent
  }

  private func closeVisibleConnections() async {
    guard !activeVisibleConnections.isEmpty, !closingConnections else { return }
    closingConnections = true
    defer { closingConnections = false }
    if hasConnectionFilters {
      for connection in activeVisibleConnections {
        await store.closeConnection(connection.id)
      }
    } else {
      await store.closeAllConnections()
    }
  }
}
