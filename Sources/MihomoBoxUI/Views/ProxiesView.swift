import SwiftUI

@MainActor
public struct ProxiesView: View {
  private enum Section: String, CaseIterable, Identifiable {
    case proxies = "Proxies"
    case providers = "Proxy Providers"

    var id: String { rawValue }
  }

  private enum DisplayMode: String, CaseIterable, Identifiable {
    case card, list, table, chips, master

    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .card: "square.grid.2x2"
      case .list: "list.bullet"
      case .table: "tablecells"
      case .chips: "tag"
      case .master: "sidebar.left"
      }
    }

    var title: String { rawValue.capitalized }
  }

  private enum SortOrder: String, CaseIterable, Identifiable {
    case profile = "Profile order"
    case latencyAscending = "Latency: low to high"
    case latencyDescending = "Latency: high to low"
    case nameAscending = "Name: A–Z"
    case nameDescending = "Name: Z–A"

    var id: String { rawValue }
  }

  @ObservedObject private var store: DashboardStore
  @State private var section: Section = .proxies
  @State private var displayMode: DisplayMode = .card
  @State private var sortOrder: SortOrder = .profile
  @State private var search = ""
  @State private var collapsedGroups: Set<String> = []
  @State private var collapsedProviders: Set<String> = []
  @State private var selectedMasterGroup: String?
  @State private var showingSettings = false
  @State private var hideUnavailable = false
  @State private var testingAll = false
  @State private var updatingAll = false

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar

      switch store.proxiesState {
      case .loaded:
        loadedContent
      case .loading, .empty, .failed:
        DashboardPageStateView(
          state: store.proxiesState,
          emptyTitle: "No proxies available"
        ) {
          Task { await store.refresh(.proxies) }
        }
      }
    }
    .padding(DashboardTheme.spacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DashboardTheme.background)
  }

  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        sectionTabs
        actionStrip
        Spacer(minLength: 4)
        DashboardSearchField(searchPlaceholder, text: $search)
          .frame(width: 250)
        settingsButton
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          sectionTabs
          Spacer(minLength: 4)
          sectionActions
          settingsButton
        }
        HStack(spacing: 8) {
          displayModeControl
          sortMenu
          collapseButton
          Spacer(minLength: 4)
          DashboardSearchField(searchPlaceholder, text: $search)
            .frame(maxWidth: 280)
        }
      }
    }
  }

  private var sectionTabs: some View {
    HStack(spacing: 4) {
      ForEach(Section.allCases) { item in
        Button {
          section = item
        } label: {
          HStack(spacing: 7) {
            Text(item.rawValue)
              .font(.system(size: 13, weight: .semibold))
            Text(sectionCount(item).formatted())
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .monospacedDigit()
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                (section == item
                  ? Color.black.opacity(0.16) : DashboardTheme.content.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 5)
              )
          }
          .foregroundStyle(section == item ? DashboardTheme.primaryContent : DashboardTheme.muted)
          .padding(.horizontal, 11)
          .frame(height: 34)
          .background(
            section == item ? DashboardTheme.primary : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private var actionStrip: some View {
    HStack(spacing: 7) {
      displayModeControl
      sortMenu
      collapseButton
      sectionActions
    }
  }

  private var displayModeControl: some View {
    HStack(spacing: 2) {
      ForEach(DisplayMode.allCases) { mode in
        Button {
          displayMode = mode
        } label: {
          Image(systemName: mode.symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 27, height: 27)
            .foregroundStyle(
              displayMode == mode ? DashboardTheme.primaryContent : DashboardTheme.muted
            )
            .background(
              displayMode == mode ? DashboardTheme.primary : Color.clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help("\(mode.title) mode")
        .accessibilityLabel("\(mode.title) proxy display")
      }
    }
    .padding(3)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort proxies", selection: $sortOrder) {
        ForEach(SortOrder.allCases) { order in
          Text(order.rawValue).tag(order)
        }
      }
    } label: {
      toolbarIcon("arrow.up.arrow.down")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort proxies")
  }

  private var collapseButton: some View {
    Button {
      switch section {
      case .proxies:
        if allGroupsCollapsed {
          collapsedGroups.removeAll()
        } else {
          collapsedGroups.formUnion(store.proxyGroups.map(\.name))
        }
      case .providers:
        if allProvidersCollapsed {
          collapsedProviders.removeAll()
        } else {
          collapsedProviders.formUnion(store.proxyProviders.map(\.name))
        }
      }
    } label: {
      toolbarIcon(allSectionsCollapsed ? "chevron.down.2" : "chevron.up.2")
    }
    .buttonStyle(.plain)
    .help(allSectionsCollapsed ? "Expand all" : "Collapse all")
  }

  @ViewBuilder
  private var sectionActions: some View {
    if section == .proxies {
      Button {
        Task { await testAllGroups() }
      } label: {
        toolbarIcon("speedometer", active: testingAll)
      }
      .buttonStyle(.plain)
      .disabled(testingAll || store.proxyGroups.isEmpty)
      .help("Test all groups")
    } else {
      HStack(spacing: 7) {
        Button {
          Task { await testAllProviders() }
        } label: {
          toolbarIcon("speedometer", active: testingAll)
        }
        .buttonStyle(.plain)
        .disabled(testingAll || store.proxyProviders.isEmpty)
        .help("Test all providers")

        Button {
          Task { await updateAllProviders() }
        } label: {
          toolbarIcon("arrow.clockwise", active: updatingAll)
        }
        .buttonStyle(.plain)
        .disabled(updatingAll || store.proxyProviders.isEmpty)
        .help("Update all providers")
      }
    }
  }

  private var settingsButton: some View {
    Button {
      showingSettings.toggle()
    } label: {
      toolbarIcon("gearshape", emphasized: true)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingSettings, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Proxy display")
          .font(.system(size: 14, weight: .semibold))
        Toggle("Hide unavailable nodes", isOn: $hideUnavailable)
        Divider()
        Button {
          showingSettings = false
          Task { await store.refresh(.proxies) }
        } label: {
          Label("Refresh controller data", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(DashboardTheme.content)
      .padding(16)
      .frame(width: 250)
      .background(DashboardTheme.surface)
    }
    .help("Proxy display settings")
  }

  private func toolbarIcon(
    _ symbol: String,
    active: Bool = false,
    emphasized: Bool = false
  ) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(
        active ? DashboardTheme.success : emphasized ? DashboardTheme.primary : DashboardTheme.muted
      )
      .frame(width: 34, height: 34)
      .background(
        emphasized ? DashboardTheme.primary.opacity(0.11) : DashboardTheme.surface,
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(
            emphasized ? DashboardTheme.primary.opacity(0.22) : DashboardTheme.divider, lineWidth: 1
          )
      }
  }

  @ViewBuilder
  private var loadedContent: some View {
    switch section {
    case .proxies:
      proxyGroupsContent
    case .providers:
      providersContent
    }
  }

  @ViewBuilder
  private var proxyGroupsContent: some View {
    if filteredGroups.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: search.isEmpty
            ? "No proxy groups were returned." : "No proxy group matches the filter."),
        emptyTitle: "No matching proxies"
      ) {
        search = ""
      }
    } else if displayMode == .master {
      masterDetailContent
    } else {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 390), spacing: 10, alignment: .top)],
          alignment: .leading,
          spacing: 10
        ) {
          ForEach(filteredGroups) { group in
            proxyGroupPanel(group)
          }
        }
        .padding(.bottom, 2)
      }
    }
  }

  private var masterDetailContent: some View {
    let selected = selectedMasterGroup.flatMap(group(named:)) ?? filteredGroups.first
    return HStack(alignment: .top, spacing: 10) {
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(filteredGroups) { group in
            Button {
              selectedMasterGroup = group.name
            } label: {
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                  Text(group.selectedNode ?? group.type)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.muted)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(group.nodes.count.formatted())
                  .font(.system(size: 10, weight: .bold))
                  .monospacedDigit()
              }
              .foregroundStyle(DashboardTheme.content)
              .padding(10)
              .background(
                selected?.name == group.name
                  ? DashboardTheme.primary.opacity(0.14)
                  : DashboardTheme.surface,
                in: RoundedRectangle(cornerRadius: 9)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 9)
                  .stroke(
                    selected?.name == group.name
                      ? DashboardTheme.primary.opacity(0.45)
                      : DashboardTheme.divider,
                    lineWidth: 1
                  )
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(width: 220)

      if let selected {
        proxyGroupPanel(selected, forceExpanded: true)
      }
    }
  }

  private func proxyGroupPanel(_ group: ProxyGroup, forceExpanded: Bool = false) -> some View {
    let nodes = displayedNodes(in: group)
    let expanded = forceExpanded || !collapsedGroups.contains(group.name)

    return VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 10) {
        Button {
          guard !forceExpanded else { return }
          if expanded {
            collapsedGroups.insert(group.name)
          } else {
            collapsedGroups.remove(group.name)
          }
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Text(group.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DashboardTheme.content)
                .lineLimit(1)
              StatusPill(
                "\(availableCount(in: group)) / \(group.nodes.count)",
                color: DashboardTheme.primary
              )
            }
            HStack(spacing: 6) {
              StatusPill(group.type.uppercased(), color: DashboardTheme.primary)
              if let selected = group.selectedNode, !selected.isEmpty {
                Image(systemName: "chevron.right")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(DashboardTheme.muted)
                Text(selected)
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(DashboardTheme.primary)
                  .lineLimit(1)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Button {
          Task { await store.testProxyGroup(group.name) }
        } label: {
          toolbarIcon("speedometer")
        }
        .buttonStyle(.plain)
        .help("Test \(group.name)")

        if !forceExpanded {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardTheme.muted)
            .padding(.top, 13)
        }
      }

      if expanded {
        Divider().overlay(DashboardTheme.divider)
        nodesContent(nodes, group: group)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(DashboardTheme.primary.opacity(0.24), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func nodesContent(_ nodes: [ProxyNode], group: ProxyGroup) -> some View {
    if nodes.isEmpty {
      Text(search.isEmpty ? "No nodes" : "No node matches the filter")
        .font(.system(size: 12))
        .foregroundStyle(DashboardTheme.muted)
        .frame(maxWidth: .infinity, minHeight: 46)
    } else {
      switch displayMode {
      case .card, .master:
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150), spacing: 7)],
          spacing: 7
        ) {
          ForEach(nodes) { node in nodeCard(node, group: group) }
        }
      case .list:
        LazyVStack(spacing: 5) {
          ForEach(nodes) { node in nodeListRow(node, group: group, table: false) }
        }
      case .table:
        VStack(spacing: 4) {
          HStack(spacing: 8) {
            Text("Node").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: 68, alignment: .leading)
            Text("UDP").frame(width: 34)
            Text("Latency").frame(width: 64, alignment: .trailing)
          }
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted)
          ForEach(nodes) { node in nodeListRow(node, group: group, table: true) }
        }
      case .chips:
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 128), spacing: 6)],
          alignment: .leading,
          spacing: 6
        ) {
          ForEach(nodes) { node in nodeChip(node, group: group) }
        }
      }
    }
  }

  private func nodeCard(_ node: ProxyNode, group: ProxyGroup) -> some View {
    Button {
      Task { await store.selectProxy(group: group.name, node: node.name) }
    } label: {
      VStack(alignment: .leading, spacing: 9) {
        HStack(alignment: .top, spacing: 6) {
          Text(node.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DashboardTheme.content)
            .lineLimit(1)
          Spacer(minLength: 2)
          if node.supportsUDP {
            Text("U")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(DashboardTheme.primaryContent)
              .frame(width: 15, height: 15)
              .background(DashboardTheme.info, in: Circle())
          }
        }
        HStack(spacing: 6) {
          Text(node.type.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DashboardTheme.muted)
            .lineLimit(1)
          Spacer(minLength: 2)
          Text(DashboardFormat.latency(node.latencyMilliseconds))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(latencyColor(node.latencyMilliseconds))
        }
        Capsule()
          .fill(latencyColor(node.latencyMilliseconds))
          .frame(height: 4)
      }
      .padding(10)
      .background(
        node.isSelected ? DashboardTheme.primary.opacity(0.16) : DashboardTheme.surfaceRaised,
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(node.isSelected ? DashboardTheme.primary : Color.clear, lineWidth: 1)
      }
      .shadow(
        color: node.isSelected ? DashboardTheme.primary.opacity(0.22) : .clear,
        radius: 9,
        y: 3
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(node.name), \(DashboardFormat.latency(node.latencyMilliseconds))")
    .accessibilityValue(node.isSelected ? "Selected" : "Not selected")
  }

  private func nodeListRow(_ node: ProxyNode, group: ProxyGroup, table: Bool) -> some View {
    Button {
      Task { await store.selectProxy(group: group.name, node: node.name) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: node.isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 12))
          .foregroundStyle(node.isSelected ? DashboardTheme.primary : DashboardTheme.muted)
          .frame(width: 16)
        Text(node.name)
          .font(.system(size: 11, weight: node.isSelected ? .semibold : .regular))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(node.type.uppercased())
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted)
          .frame(width: table ? 68 : 58, alignment: .leading)
        if table {
          Text(node.supportsUDP ? "U" : "—")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(node.supportsUDP ? DashboardTheme.info : DashboardTheme.muted)
            .frame(width: 34)
        }
        Text(DashboardFormat.latency(node.latencyMilliseconds))
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(latencyColor(node.latencyMilliseconds))
          .frame(width: 64, alignment: .trailing)
      }
      .foregroundStyle(DashboardTheme.content)
      .padding(.horizontal, 9)
      .frame(height: 31)
      .background(
        node.isSelected ? DashboardTheme.primary.opacity(0.12) : DashboardTheme.surfaceRaised,
        in: RoundedRectangle(cornerRadius: 7)
      )
    }
    .buttonStyle(.plain)
  }

  private func nodeChip(_ node: ProxyNode, group: ProxyGroup) -> some View {
    Button {
      Task { await store.selectProxy(group: group.name, node: node.name) }
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(node.isSelected ? DashboardTheme.primary : latencyColor(node.latencyMilliseconds))
          .frame(width: 7, height: 7)
        Text(node.name)
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 2)
        Text(DashboardFormat.latency(node.latencyMilliseconds))
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .monospacedDigit()
      }
      .foregroundStyle(DashboardTheme.content)
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background(
        node.isSelected ? DashboardTheme.primary.opacity(0.16) : DashboardTheme.surfaceRaised,
        in: Capsule()
      )
      .overlay {
        Capsule().stroke(
          node.isSelected ? DashboardTheme.primary : DashboardTheme.divider, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var providersContent: some View {
    if filteredProviders.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: search.isEmpty
            ? "No proxy providers were returned." : "No provider matches the filter."),
        emptyTitle: "No matching providers"
      ) {
        search = ""
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(filteredProviders) { provider in providerPanel(provider) }
        }
        .padding(.bottom, 2)
      }
    }
  }

  private func providerPanel(_ provider: ProxyProvider) -> some View {
    let nodes = displayedNodes(in: provider)
    let expanded = !collapsedProviders.contains(provider.name)

    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Button {
          if expanded {
            collapsedProviders.insert(provider.name)
          } else {
            collapsedProviders.remove(provider.name)
          }
        } label: {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
              Text(provider.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DashboardTheme.content)
                .lineLimit(1)
              StatusPill(
                "\(availableCount(in: provider)) / \(providerNodeCount(provider))",
                color: DashboardTheme.primary
              )
              if !provider.vehicleType.isEmpty {
                StatusPill(provider.vehicleType, color: DashboardTheme.info)
              }
            }
            HStack(spacing: 12) {
              Label(
                provider.updatedAt?.formatted(date: .abbreviated, time: .shortened)
                  ?? "Never updated",
                systemImage: "clock.arrow.circlepath"
              )
              if let expiresAt = provider.expiresAt {
                Label(
                  "Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))",
                  systemImage: "calendar"
                )
              }
            }
            .font(.system(size: 10))
            .foregroundStyle(DashboardTheme.muted)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Spacer(minLength: 2)
        Button {
          Task { await store.refreshProxyProvider(provider.name) }
        } label: {
          toolbarIcon("arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help("Update \(provider.name)")
        Button {
          Task { await store.testProxyProvider(provider.name) }
        } label: {
          toolbarIcon("speedometer")
        }
        .buttonStyle(.plain)
        .help("Test \(provider.name)")

        Image(systemName: expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted)
          .padding(.top, 13)
      }

      if let used = provider.usedBytes, let total = provider.totalBytes, total > 0 {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: Double(used), total: Double(total))
            .tint(DashboardTheme.primary)
          Text("\(DashboardFormat.bytes(used)) of \(DashboardFormat.bytes(total))")
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(DashboardTheme.muted)
        }
      }

      if expanded {
        Divider().overlay(DashboardTheme.divider)
        providerNodesContent(nodes, provider: provider)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(DashboardTheme.primary.opacity(0.2), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func providerNodesContent(_ nodes: [ProxyNode], provider: ProxyProvider) -> some View {
    if nodes.isEmpty {
      Text(providerNodesEmptyMessage(provider))
        .font(.system(size: 12))
        .foregroundStyle(DashboardTheme.muted)
        .frame(maxWidth: .infinity, minHeight: 46)
    } else {
      switch displayMode {
      case .card, .master:
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150), spacing: 7)],
          spacing: 7
        ) {
          ForEach(nodes) { node in providerNodeCard(node) }
        }
      case .list:
        LazyVStack(spacing: 5) {
          ForEach(nodes) { node in providerNodeListRow(node, table: false) }
        }
      case .table:
        VStack(spacing: 4) {
          HStack(spacing: 8) {
            Text("Node").frame(maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: 58, alignment: .leading)
            Text("Type").frame(width: 76, alignment: .leading)
            Text("UDP").frame(width: 34)
            Text("Latency").frame(width: 64, alignment: .trailing)
          }
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted)
          ForEach(nodes) { node in providerNodeListRow(node, table: true) }
        }
      case .chips:
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
          alignment: .leading,
          spacing: 6
        ) {
          ForEach(nodes) { node in providerNodeChip(node) }
        }
      }
    }
  }

  private func providerNodeCard(_ node: ProxyNode) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 6) {
        Text(node.name)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
          .lineLimit(1)
        Spacer(minLength: 2)
        if node.supportsUDP {
          Text("U")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(DashboardTheme.primaryContent)
            .frame(width: 15, height: 15)
            .background(DashboardTheme.info, in: Circle())
        }
      }
      HStack(spacing: 6) {
        Text(node.type.uppercased())
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(DashboardTheme.muted)
          .lineLimit(1)
        Spacer(minLength: 2)
        Text(nodeAvailabilityLabel(node.isAlive))
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(nodeAvailabilityColor(node.isAlive))
        Text(DashboardFormat.latency(node.latencyMilliseconds))
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(providerNodeLatencyColor(node))
      }
      Capsule()
        .fill(providerNodeLatencyColor(node))
        .frame(height: 4)
    }
    .padding(10)
    .background(DashboardTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(providerNodeAccessibilityLabel(node))
  }

  private func providerNodeListRow(_ node: ProxyNode, table: Bool) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(nodeAvailabilityColor(node.isAlive))
        .frame(width: 7, height: 7)
      Text(node.name)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      if table {
        Text(nodeAvailabilityLabel(node.isAlive))
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(nodeAvailabilityColor(node.isAlive))
          .frame(width: 58, alignment: .leading)
      }
      Text(node.type.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(DashboardTheme.muted)
        .frame(width: table ? 76 : 62, alignment: .leading)
      if table {
        Text(node.supportsUDP ? "U" : "—")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(node.supportsUDP ? DashboardTheme.info : DashboardTheme.muted)
          .frame(width: 34)
      } else if node.supportsUDP {
        Text("UDP")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardTheme.info)
      }
      Text(DashboardFormat.latency(node.latencyMilliseconds))
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(providerNodeLatencyColor(node))
        .frame(width: 64, alignment: .trailing)
    }
    .foregroundStyle(DashboardTheme.content)
    .padding(.horizontal, 9)
    .frame(height: 31)
    .background(DashboardTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(providerNodeAccessibilityLabel(node))
  }

  private func providerNodeChip(_ node: ProxyNode) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(nodeAvailabilityColor(node.isAlive))
        .frame(width: 7, height: 7)
      Text(node.name)
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 2)
      if node.supportsUDP {
        Text("U")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardTheme.info)
      }
      Text(DashboardFormat.latency(node.latencyMilliseconds))
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(providerNodeLatencyColor(node))
    }
    .foregroundStyle(DashboardTheme.content)
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background(DashboardTheme.surfaceRaised, in: Capsule())
    .overlay {
      Capsule().stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(providerNodeAccessibilityLabel(node))
  }

  private var filteredGroups: [ProxyGroup] {
    guard !search.isEmpty else { return store.proxyGroups }
    return store.proxyGroups.filter { group in
      group.name.localizedCaseInsensitiveContains(search)
        || group.nodes.contains { $0.name.localizedCaseInsensitiveContains(search) }
    }
  }

  private var filteredProviders: [ProxyProvider] {
    guard !searchQuery.isEmpty else { return store.proxyProviders }
    return store.proxyProviders.filter { provider in
      provider.name.localizedCaseInsensitiveContains(searchQuery)
        || provider.vehicleType.localizedCaseInsensitiveContains(searchQuery)
        || provider.nodes.contains {
          $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }
  }

  private var searchPlaceholder: String {
    switch section {
    case .proxies: "Filter groups or nodes"
    case .providers: "Filter providers or nodes"
    }
  }

  private var searchQuery: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var allSectionsCollapsed: Bool {
    switch section {
    case .proxies: allGroupsCollapsed
    case .providers: allProvidersCollapsed
    }
  }

  private var allGroupsCollapsed: Bool {
    !store.proxyGroups.isEmpty && store.proxyGroups.allSatisfy { collapsedGroups.contains($0.name) }
  }

  private var allProvidersCollapsed: Bool {
    !store.proxyProviders.isEmpty
      && store.proxyProviders.allSatisfy { collapsedProviders.contains($0.name) }
  }

  private func displayedNodes(in group: ProxyGroup) -> [ProxyNode] {
    var nodes = group.nodes
    if !search.isEmpty, !group.name.localizedCaseInsensitiveContains(search) {
      nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    if hideUnavailable {
      nodes = nodes.filter { $0.isAlive != false }
    }
    return sortedNodes(nodes)
  }

  private func displayedNodes(in provider: ProxyProvider) -> [ProxyNode] {
    var nodes = provider.nodes
    if !searchQuery.isEmpty {
      let providerMatches =
        provider.name.localizedCaseInsensitiveContains(searchQuery)
        || provider.vehicleType.localizedCaseInsensitiveContains(searchQuery)
      if !providerMatches {
        nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
      }
    }
    if hideUnavailable {
      nodes = nodes.filter { $0.isAlive != false }
    }
    return sortedNodes(nodes)
  }

  private func sortedNodes(_ input: [ProxyNode]) -> [ProxyNode] {
    var nodes = input
    switch sortOrder {
    case .profile:
      break
    case .latencyAscending:
      nodes.sort { ($0.latencyMilliseconds ?? Int.max) < ($1.latencyMilliseconds ?? Int.max) }
    case .latencyDescending:
      nodes.sort { ($0.latencyMilliseconds ?? -1) > ($1.latencyMilliseconds ?? -1) }
    case .nameAscending:
      nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    case .nameDescending:
      nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
    return nodes
  }

  private func group(named name: String) -> ProxyGroup? {
    filteredGroups.first { $0.name == name }
  }

  private func sectionCount(_ item: Section) -> Int {
    switch item {
    case .proxies: store.proxyGroups.count
    case .providers: store.proxyProviders.count
    }
  }

  private func availableCount(in group: ProxyGroup) -> Int {
    group.nodes.filter { $0.isAlive == true }.count
  }

  private func availableCount(in provider: ProxyProvider) -> Int {
    provider.nodes.filter { $0.isAlive == true }.count
  }

  private func providerNodeCount(_ provider: ProxyProvider) -> Int {
    max(provider.nodeCount, provider.nodes.count)
  }

  private func providerNodesEmptyMessage(_ provider: ProxyProvider) -> String {
    if provider.nodes.isEmpty {
      return "This provider returned no nodes."
    }
    if hideUnavailable && provider.nodes.allSatisfy({ $0.isAlive == false }) {
      return "All provider nodes are unavailable and hidden."
    }
    if !searchQuery.isEmpty {
      return "No provider node matches the current filter."
    }
    return "No provider nodes are visible."
  }

  private func nodeAvailabilityLabel(_ isAlive: Bool?) -> String {
    switch isAlive {
    case true: "Alive"
    case false: "Down"
    case nil: "Unknown"
    }
  }

  private func nodeAvailabilityColor(_ isAlive: Bool?) -> Color {
    switch isAlive {
    case true: DashboardTheme.success
    case false: DashboardTheme.error
    case nil: DashboardTheme.muted
    }
  }

  private func providerNodeLatencyColor(_ node: ProxyNode) -> Color {
    if node.isAlive == false { return DashboardTheme.error }
    return latencyColor(node.latencyMilliseconds)
  }

  private func providerNodeAccessibilityLabel(_ node: ProxyNode) -> String {
    let udp = node.supportsUDP ? "UDP supported" : "UDP not reported"
    return
      "\(node.name), \(node.type), \(nodeAvailabilityLabel(node.isAlive)), \(udp), \(DashboardFormat.latency(node.latencyMilliseconds))"
  }

  private func latencyColor(_ latency: Int?) -> Color {
    guard let latency, latency > 0 else { return DashboardTheme.muted }
    if latency < 150 { return DashboardTheme.success }
    if latency < 500 { return DashboardTheme.warning }
    return DashboardTheme.error
  }

  private func testAllGroups() async {
    guard !testingAll else { return }
    testingAll = true
    defer { testingAll = false }
    for group in filteredGroups {
      await store.testProxyGroup(group.name)
    }
  }

  private func testAllProviders() async {
    guard !testingAll else { return }
    testingAll = true
    defer { testingAll = false }
    for provider in filteredProviders {
      await store.testProxyProvider(provider.name)
    }
  }

  private func updateAllProviders() async {
    guard !updatingAll else { return }
    updatingAll = true
    defer { updatingAll = false }
    for provider in filteredProviders {
      await store.refreshProxyProvider(provider.name)
    }
  }
}
