import SwiftUI

@MainActor
public struct RulesView: View {
  private enum Section: String, CaseIterable, Identifiable {
    case rules = "Rules"
    case providers = "Rule Providers"

    var id: String { rawValue }
  }

  private enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case enabled = "Enabled"
    case disabled = "Disabled"

    var id: String { rawValue }
  }

  private enum SortOrder: String, CaseIterable, Identifiable {
    case profile = "Original order in config file"
    case hits = "Most matches"
    case type = "Rule type"
    case payload = "Payload"

    var id: String { rawValue }
  }

  @ObservedObject private var store: DashboardStore
  @State private var section: Section = .rules
  @State private var statusFilter: StatusFilter = .all
  @State private var selectedTypes: Set<String> = []
  @State private var selectedPolicies: Set<String> = []
  @State private var sortOrder: SortOrder = .profile
  @State private var search = ""
  @State private var updatingProviders = false

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar

      if section == .rules, store.rulesState == .loaded {
        filterBar
      }

      switch store.rulesState {
      case .loaded:
        loadedContent
      case .loading, .empty, .failed:
        DashboardPageStateView(state: store.rulesState, emptyTitle: "No rules available") {
          Task { await store.refresh(.rules) }
        }
      }
    }
    .padding(DashboardTheme.spacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DashboardTheme.background)
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      sectionTabs
      DashboardSearchField("Search", text: $search)
        .frame(maxWidth: .infinity)

      if section == .providers {
        Button {
          Task { await updateAllProviders() }
        } label: {
          toolbarIcon("arrow.clockwise", active: updatingProviders)
        }
        .buttonStyle(.plain)
        .disabled(updatingProviders || store.ruleProviders.isEmpty)
        .help("Update all rule providers")
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

  private var filterBar: some View {
    HStack(spacing: 8) {
      statusControl

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(typeFacets, id: \.name) { facet in
            facetButton(
              facet.name,
              count: facet.count,
              selected: selectedTypes.contains(facet.name),
              tint: DashboardTheme.primary
            ) {
              toggle(facet.name, in: &selectedTypes)
            }
          }

          if !typeFacets.isEmpty, !policyFacets.isEmpty {
            Divider()
              .frame(height: 18)
              .overlay(DashboardTheme.divider)
              .padding(.horizontal, 2)
          }

          ForEach(policyFacets, id: \.name) { facet in
            facetButton(
              facet.name,
              count: facet.count,
              selected: selectedPolicies.contains(facet.name),
              tint: DashboardTheme.secondary
            ) {
              toggle(facet.name, in: &selectedPolicies)
            }
          }
        }
      }

      if hasActiveFilters {
        Button {
          clearFilters()
        } label: {
          toolbarIcon("xmark")
        }
        .buttonStyle(.plain)
        .help("Clear rule filters")
      }

      Menu {
        Picker("Sort rules", selection: $sortOrder) {
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
    }
  }

  private var statusControl: some View {
    HStack(spacing: 3) {
      ForEach(StatusFilter.allCases) { status in
        Button {
          statusFilter = status
        } label: {
          Text(status.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
              statusFilter == status ? DashboardTheme.primaryContent : DashboardTheme.muted
            )
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
              statusFilter == status ? DashboardTheme.primary : Color.clear,
              in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private func facetButton(
    _ title: String,
    count: Int,
    selected: Bool,
    tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
        Text(count.formatted())
          .opacity(0.58)
          .monospacedDigit()
      }
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(selected ? tint : DashboardTheme.muted)
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background(
        selected ? tint.opacity(0.14) : DashboardTheme.surface,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? tint.opacity(0.36) : DashboardTheme.divider, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  private func toolbarIcon(_ symbol: String, active: Bool = false) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(active ? DashboardTheme.success : DashboardTheme.muted)
      .frame(width: 34, height: 34)
      .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
  }

  @ViewBuilder
  private var loadedContent: some View {
    switch section {
    case .rules:
      rulesContent
    case .providers:
      providersContent
    }
  }

  @ViewBuilder
  private var rulesContent: some View {
    if filteredRules.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: store.rules.isEmpty
            ? "The active profile has no rules." : "No rule matches the current filters."),
        emptyTitle: "No matching rules"
      ) {
        clearFilters()
      }
    } else {
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(filteredRules) { rule in
            ruleCard(rule)
          }
        }
        .padding(.bottom, 2)
      }
    }
  }

  private func ruleCard(_ rule: DashboardRule) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Toggle(
        "Enable rule \(rule.index)",
        isOn: Binding(
          get: { rule.isEnabled },
          set: { enabled in
            Task { await store.setRuleEnabled(rule.id, enabled: enabled) }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 9) {
        Text(rule.payload.isEmpty ? rule.type : rule.payload)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(rule.isEnabled ? DashboardTheme.content : DashboardTheme.muted)
          .lineLimit(1)

        ViewThatFits(in: .horizontal) {
          ruleMetadata(rule, showMatched: true, showUnmatched: true)
          ruleMetadata(rule, showMatched: true, showUnmatched: false)
          ruleMetadata(rule, showMatched: false, showUnmatched: false)
        }
      }

      Spacer(minLength: 8)

      Text(rule.size.formatted())
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(DashboardTheme.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(DashboardTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .opacity(rule.isEnabled ? 1 : 0.68)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var providersContent: some View {
    if filteredProviders.isEmpty {
      DashboardPageStateView(
        state: .empty(
          message: store.ruleProviders.isEmpty
            ? "The active profile has no rule providers." : "No provider matches the search."),
        emptyTitle: "No matching providers"
      ) {
        search = ""
      }
    } else {
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(filteredProviders) { provider in
            providerCard(provider)
          }
        }
        .padding(.bottom, 2)
      }
    }
  }

  private func providerCard(_ provider: RuleProvider) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text(provider.name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
          .lineLimit(1)
        HStack(spacing: 7) {
          if !provider.vehicleType.isEmpty {
            StatusPill(provider.vehicleType, color: DashboardTheme.primary)
          }
          StatusPill(provider.behavior, color: DashboardTheme.primary)
          if !provider.format.isEmpty {
            StatusPill(provider.format, color: DashboardTheme.info)
          }
          if !provider.type.isEmpty {
            Text(provider.type)
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(DashboardTheme.muted)
          }
          Text(
            provider.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never updated"
          )
          .font(.system(size: 10))
          .foregroundStyle(DashboardTheme.muted)
        }
      }
      Spacer(minLength: 8)
      StatusPill("\(provider.ruleCount.formatted()) rules", color: DashboardTheme.accent)
      Button {
        Task { await store.refreshRuleProvider(provider.name) }
      } label: {
        toolbarIcon("arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help("Update \(provider.name)")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private func ruleMetadata(
    _ rule: DashboardRule,
    showMatched: Bool,
    showUnmatched: Bool
  ) -> some View {
    HStack(spacing: 7) {
      StatusPill(rule.type, color: DashboardTheme.primary)
      Image(systemName: "arrow.right")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(DashboardTheme.muted)
      StatusPill(rule.target, color: DashboardTheme.secondary)
      StatusPill(rule.hitCount.formatted(), color: DashboardTheme.success)
      StatusPill(rule.missCount.formatted(), color: DashboardTheme.warning)
      if showMatched, let matched = rule.lastMatchedAt {
        Text("Matched \(relativeTime(matched))")
          .font(.system(size: 9))
          .foregroundStyle(DashboardTheme.muted)
          .lineLimit(1)
      }
      if showUnmatched, let unmatched = rule.lastUnmatchedAt {
        Text("Unmatched \(relativeTime(unmatched))")
          .font(.system(size: 9))
          .foregroundStyle(DashboardTheme.muted.opacity(0.85))
          .lineLimit(1)
      }
    }
  }

  private var filteredRules: [DashboardRule] {
    var result = store.rules.filter { rule in
      let statusMatches: Bool =
        switch statusFilter {
        case .all: true
        case .enabled: rule.isEnabled
        case .disabled: !rule.isEnabled
        }
      let typeMatches = selectedTypes.isEmpty || selectedTypes.contains(rule.type)
      let policyMatches = selectedPolicies.isEmpty || selectedPolicies.contains(rule.target)
      let searchMatches =
        search.isEmpty
        || rule.type.localizedCaseInsensitiveContains(search)
        || rule.payload.localizedCaseInsensitiveContains(search)
        || rule.target.localizedCaseInsensitiveContains(search)
      return statusMatches && typeMatches && policyMatches && searchMatches
    }

    switch sortOrder {
    case .profile:
      result.sort { $0.index < $1.index }
    case .hits:
      result.sort { $0.hitCount > $1.hitCount }
    case .type:
      result.sort { $0.type.localizedStandardCompare($1.type) == .orderedAscending }
    case .payload:
      result.sort { $0.payload.localizedStandardCompare($1.payload) == .orderedAscending }
    }
    return result
  }

  private var filteredProviders: [RuleProvider] {
    guard !search.isEmpty else { return store.ruleProviders }
    return store.ruleProviders.filter {
      $0.name.localizedCaseInsensitiveContains(search)
        || $0.behavior.localizedCaseInsensitiveContains(search)
    }
  }

  private var typeFacets: [(name: String, count: Int)] {
    Dictionary(grouping: store.rules, by: \.type)
      .map { (name: $0.key, count: $0.value.count) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var policyFacets: [(name: String, count: Int)] {
    Dictionary(grouping: store.rules, by: \.target)
      .map { (name: $0.key, count: $0.value.count) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var hasActiveFilters: Bool {
    statusFilter != .all || !selectedTypes.isEmpty || !selectedPolicies.isEmpty || !search.isEmpty
  }

  private func sectionCount(_ item: Section) -> Int {
    switch item {
    case .rules: store.rules.count
    case .providers: store.ruleProviders.count
    }
  }

  private func toggle(_ value: String, in selection: inout Set<String>) {
    if selection.contains(value) { selection.remove(value) } else { selection.insert(value) }
  }

  private func clearFilters() {
    statusFilter = .all
    selectedTypes.removeAll()
    selectedPolicies.removeAll()
    search = ""
  }

  private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private func updateAllProviders() async {
    guard !updatingProviders else { return }
    updatingProviders = true
    defer { updatingProviders = false }
    for provider in filteredProviders {
      await store.refreshRuleProvider(provider.name)
    }
  }
}
