import SwiftUI

@MainActor
public struct UsageView: View {
  private enum SortField: String {
    case name
    case upload
    case download
    case total
  }

  @ObservedObject private var store: DashboardStore
  @State private var detailSearch = ""
  @State private var selectedRow: String?
  @State private var expandedDetailRow: String?
  @State private var selectionDimension: UsageDimension?
  @State private var sortField: SortField = .total
  @State private var sortAscending = false

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: DashboardTheme.spacing) {
      usageToolbar

      switch store.usageState {
      case .loaded:
        loadedContent
      case .loading, .empty, .failed:
        DashboardPageStateView(state: store.usageState, emptyTitle: "No usage samples") {
          Task { await store.refresh(.usage) }
        }
      }
    }
    .padding(DashboardTheme.sectionSpacing)
    .background(DashboardTheme.background)
    .onAppear(perform: repairSelection)
    .onChange(of: store.usageRows) { _, _ in repairSelection() }
    .onChange(of: store.usageDimension) { _, _ in repairSelection() }
  }

  private var usageToolbar: some View {
    HStack(spacing: 12) {
      HStack(spacing: 3) {
        ForEach(UsageDimension.allCases) { dimension in
          Button {
            Task { await store.setUsageDimension(dimension) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: symbol(for: dimension))
                .font(.system(size: 12, weight: .semibold))
              Text(dimension.rawValue)
                .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(
              store.usageDimension == dimension
                ? DashboardTheme.primaryContent : DashboardTheme.muted
            )
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
              store.usageDimension == dimension
                ? DashboardTheme.primary : Color.clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Group usage by \(dimension.rawValue)")
        }
      }
      .padding(3)
      .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }

      Spacer(minLength: 12)

      HStack(spacing: 6) {
        Image(systemName: "clock")
          .font(.system(size: 11, weight: .semibold))
        Text("Recent session")
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(DashboardTheme.muted)
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }

      HStack(spacing: 6) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 11, weight: .semibold))
        Text("Bounded memory")
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(DashboardTheme.muted)
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
      .help(
        "Usage covers active connections and the 500 most recent closed connections in this UI session"
      )

      toolbarButton("trash", help: "Clear session usage") {
        Task { await store.clearUsage() }
      }
      .disabled(store.usageRows.isEmpty)
    }
    .frame(minHeight: 36)
    .accessibilityElement(children: .contain)
  }

  private var loadedContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DashboardTheme.spacing) {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(minimum: 140), spacing: 12),
            count: 4
          ),
          spacing: 12
        ) {
          summaryCard(
            store.usageDimension.rawValue,
            value: store.usageRows.count.formatted(),
            symbol: symbol(for: store.usageDimension),
            tint: DashboardTheme.primary
          )
          summaryCard(
            "Upload",
            value: DashboardFormat.bytes(totalUpload),
            symbol: "arrow.up",
            tint: DashboardTheme.success
          )
          summaryCard(
            "Download",
            value: DashboardFormat.bytes(totalDownload),
            symbol: "arrow.down",
            tint: DashboardTheme.info
          )
          summaryCard(
            "Total",
            value: DashboardFormat.bytes(totalUpload + totalDownload),
            symbol: "sum",
            tint: DashboardTheme.secondary,
            note: "Recent"
          )
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: DashboardTheme.spacing) {
            rankingCard
              .frame(minWidth: 220, idealWidth: 260, maxWidth: 290)
            trendCard
              .frame(minWidth: 430, maxWidth: .infinity)
          }
          VStack(spacing: DashboardTheme.spacing) {
            rankingCard
            trendCard
          }
        }

        detailsCard
      }
      .padding(.trailing, 1)
    }
  }

  private var rankingCard: some View {
    DashboardCard {
      VStack(alignment: .leading, spacing: 12) {
        Label(
          "Top \(store.usageDimension.rawValue)", systemImage: symbol(for: store.usageDimension)
        )
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(DashboardTheme.content)

        ScrollView {
          LazyVStack(spacing: 5) {
            ForEach(rankingRows) { row in
              Button {
                selectedRow = row.name
                expandedDetailRow = nil
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  HStack(spacing: 8) {
                    Text(row.name)
                      .font(.system(size: 11, weight: .medium, design: .monospaced))
                      .foregroundStyle(
                        selectedRow == row.name
                          ? DashboardTheme.primary : DashboardTheme.content
                      )
                      .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DashboardFormat.bytes(rowTotal(row)))
                      .font(.system(size: 10, weight: .bold, design: .rounded))
                      .monospacedDigit()
                      .foregroundStyle(
                        selectedRow == row.name
                          ? DashboardTheme.primary : DashboardTheme.muted
                      )
                  }
                  HStack(spacing: 10) {
                    Text("↑ \(DashboardFormat.bytes(row.uploadBytes))")
                    Text("↓ \(DashboardFormat.bytes(row.downloadBytes))")
                  }
                  .font(.system(size: 9, weight: .semibold, design: .rounded))
                  .foregroundStyle(DashboardTheme.muted)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  selectedRow == row.name
                    ? DashboardTheme.primary.opacity(0.10) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                "\(row.name), total \(DashboardFormat.bytes(rowTotal(row)))"
              )
            }
          }
        }
        .frame(height: 218)
      }
    }
  }

  private var trendCard: some View {
    DashboardCard {
      VStack(spacing: 12) {
        Text("Recent Traffic")
          .font(.system(size: 15, weight: .bold))
          .tracking(1.2)
          .textCase(.uppercase)
          .foregroundStyle(DashboardTheme.content)

        HStack(spacing: 14) {
          legend("Upload", DashboardTheme.secondary)
          legend("Download", DashboardTheme.info)
        }

        ZStack {
          VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
              Divider().overlay(DashboardTheme.divider)
              if index < 3 { Spacer() }
            }
          }
          DashboardSparkline(
            values: store.usageHistory.map(\.upload),
            color: DashboardTheme.secondary,
            domain: trafficDomain
          )
          DashboardSparkline(
            values: store.usageHistory.map(\.download),
            color: DashboardTheme.info,
            domain: trafficDomain
          )
        }
        .frame(height: 190)
      }
    }
  }

  private var detailsCard: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "list.bullet.rectangle")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(DashboardTheme.primary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Recent Usage Details")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DashboardTheme.content)
          if let selectedRow {
            Text(
              "\(store.usageDimension.rawValue): \(selectedRow)  →  \(detailDimension.rawValue)"
            )
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DashboardTheme.muted)
            .lineLimit(1)
          }
        }
        Spacer()
        DashboardSearchField("Search", text: $detailSearch)
          .frame(width: 250)
      }
      .padding(.horizontal, 16)
      .frame(height: 48)
      .background(DashboardTheme.surfaceRaised.opacity(0.55))

      Divider().overlay(DashboardTheme.divider)

      usageHeader

      Divider().overlay(DashboardTheme.divider)

      if detailRows.isEmpty {
        Text(detailSearch.isEmpty ? "No usage data" : "No matching usage")
          .font(.system(size: 13))
          .foregroundStyle(DashboardTheme.muted)
          .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(detailRows) { row in
              usageRow(row)
              if expandedDetailRow == row.name {
                thirdLevelRows(for: row)
              }
              Divider().overlay(DashboardTheme.divider)
            }
          }
        }
        .frame(minHeight: 220, maxHeight: 420)
      }
    }
    .background(DashboardTheme.surface.opacity(0.74))
    .clipShape(RoundedRectangle(cornerRadius: DashboardTheme.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DashboardTheme.cardRadius)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }

  private var usageHeader: some View {
    HStack(spacing: 12) {
      sortHeader(detailDimension.rawValue, field: .name, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      sortHeader("Upload", field: .upload, alignment: .trailing)
        .frame(width: 130, alignment: .trailing)
      sortHeader("Download", field: .download, alignment: .trailing)
        .frame(width: 130, alignment: .trailing)
      sortHeader("Total", field: .total, alignment: .trailing)
        .frame(width: 130, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .frame(height: 38)
    .background(DashboardTheme.surface.opacity(0.94))
  }

  private func usageRow(_ row: UsageRow) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.16)) {
        expandedDetailRow = expandedDetailRow == row.name ? nil : row.name
      }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: expandedDetailRow == row.name ? "chevron.down" : "chevron.right")
          .font(.system(size: 8, weight: .black))
          .foregroundStyle(
            expandedDetailRow == row.name ? DashboardTheme.primary : DashboardTheme.muted
          )
          .frame(width: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.name)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(
              expandedDetailRow == row.name ? DashboardTheme.primary : DashboardTheme.content
            )
            .lineLimit(1)
          Text("\(row.connectionCount.formatted()) connections")
            .font(.system(size: 9))
            .foregroundStyle(DashboardTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(DashboardFormat.bytes(row.uploadBytes))
          .frame(width: 130, alignment: .trailing)
        Text(DashboardFormat.bytes(row.downloadBytes))
          .frame(width: 130, alignment: .trailing)
        Text(DashboardFormat.bytes(rowTotal(row)))
          .fontWeight(.bold)
          .foregroundStyle(DashboardTheme.primary)
          .frame(width: 130, alignment: .trailing)
      }
      .font(.system(size: 11, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(DashboardTheme.muted)
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .background(
        expandedDetailRow == row.name
          ? DashboardTheme.primary.opacity(0.08) : Color.clear
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.name), \(row.connectionCount) connections, total \(DashboardFormat.bytes(rowTotal(row)))"
    )
    .accessibilityHint(expandedDetailRow == row.name ? "Collapse breakdown" : "Expand breakdown")
  }

  @ViewBuilder
  private func thirdLevelRows(for parent: UsageRow) -> some View {
    let rootSelection = selectedRow
    let rows = sortedRows(
      store.usageBreakdown(
        parent: parent.name,
        parentDimension: detailDimension,
        childDimension: thirdDimension,
        ancestor: rootSelection,
        ancestorDimension: rootSelection == nil ? nil : store.usageDimension
      )
    )
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(DashboardTheme.primary)
        Text(thirdDimension.rawValue.uppercased())
          .font(.system(size: 9, weight: .black))
          .tracking(0.7)
          .foregroundStyle(DashboardTheme.muted)
        Spacer()
        Text("WITHIN \(detailDimension.rawValue.uppercased())")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardTheme.muted.opacity(0.62))
      }
      .padding(.horizontal, 16)
      .frame(height: 30)

      if rows.isEmpty {
        Text("No deeper breakdown for this row")
          .font(.system(size: 10))
          .foregroundStyle(DashboardTheme.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 34)
          .padding(.vertical, 10)
      } else {
        ForEach(rows) { row in
          HStack(spacing: 12) {
            Image(systemName: symbol(for: thirdDimension))
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(DashboardTheme.muted)
              .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
              Text(row.name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DashboardTheme.content)
                .lineLimit(1)
              Text("\(row.connectionCount.formatted()) connections")
                .font(.system(size: 8))
                .foregroundStyle(DashboardTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(DashboardFormat.bytes(row.uploadBytes))
              .frame(width: 130, alignment: .trailing)
            Text(DashboardFormat.bytes(row.downloadBytes))
              .frame(width: 130, alignment: .trailing)
            Text(DashboardFormat.bytes(rowTotal(row)))
              .fontWeight(.bold)
              .foregroundStyle(DashboardTheme.secondary)
              .frame(width: 130, alignment: .trailing)
          }
          .font(.system(size: 10, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(DashboardTheme.muted)
          .padding(.leading, 34)
          .padding(.trailing, 16)
          .padding(.vertical, 8)
          Divider()
            .overlay(DashboardTheme.divider.opacity(0.72))
            .padding(.leading, 34)
        }
      }
    }
    .background(DashboardTheme.surfaceRaised.opacity(0.4))
  }

  private func summaryCard(
    _ title: String,
    value: String,
    symbol: String,
    tint: Color,
    note: String? = nil
  ) -> some View {
    DashboardCard {
      HStack(spacing: 11) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 36, height: 36)
          .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(title.uppercased())
            .font(.system(size: 9, weight: .black))
            .tracking(1)
            .foregroundStyle(DashboardTheme.muted.opacity(0.72))
            .lineLimit(1)
          Text(value)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(title == "Total" ? DashboardTheme.secondary : DashboardTheme.content)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        Spacer(minLength: 0)
        if let note {
          Text(note)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DashboardTheme.muted.opacity(0.64))
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(value)")
  }

  private func sortHeader(_ title: String, field: SortField, alignment: Alignment) -> some View {
    Button {
      if sortField == field {
        sortAscending.toggle()
      } else {
        sortField = field
        sortAscending = field == .name
      }
    } label: {
      HStack(spacing: 4) {
        Text(title.uppercased())
        Image(
          systemName: sortField == field
            ? (sortAscending ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down"
        )
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(
          sortField == field ? DashboardTheme.primary : DashboardTheme.muted.opacity(0.45))
      }
      .frame(maxWidth: .infinity, alignment: alignment)
    }
    .buttonStyle(.plain)
    .font(.system(size: 9, weight: .bold))
    .tracking(0.7)
    .foregroundStyle(DashboardTheme.muted)
  }

  private func legend(_ title: String, _ color: Color) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(title)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(DashboardTheme.muted)
    }
    .accessibilityElement(children: .combine)
  }

  private func toolbarButton(
    _ symbol: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 32, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(DashboardTheme.content)
    .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .help(help)
    .accessibilityLabel(help)
  }

  private var rankingRows: [UsageRow] {
    store.usageRows.sorted { lhs, rhs in
      if rowTotal(lhs) == rowTotal(rhs) { return lhs.name < rhs.name }
      return rowTotal(lhs) > rowTotal(rhs)
    }
  }

  private var detailRows: [UsageRow] {
    let filtered =
      detailSearch.isEmpty
      ? breakdownRows
      : breakdownRows.filter { $0.name.localizedCaseInsensitiveContains(detailSearch) }
    return sortedRows(filtered)
  }

  private var breakdownRows: [UsageRow] {
    guard let selectedRow else { return [] }
    return store.usageBreakdown(
      parent: selectedRow,
      parentDimension: store.usageDimension,
      childDimension: detailDimension
    )
  }

  private var detailDimension: UsageDimension {
    store.usageDimension == .host ? .device : .host
  }

  private var thirdDimension: UsageDimension {
    store.usageDimension == .proxy ? .device : .proxy
  }

  private func sortedRows(_ rows: [UsageRow]) -> [UsageRow] {
    rows.sorted { lhs, rhs in
      let comparison: ComparisonResult
      switch sortField {
      case .name:
        comparison = lhs.name.localizedStandardCompare(rhs.name)
      case .upload:
        comparison = numericComparison(lhs.uploadBytes, rhs.uploadBytes)
      case .download:
        comparison = numericComparison(lhs.downloadBytes, rhs.downloadBytes)
      case .total:
        comparison = numericComparison(rowTotal(lhs), rowTotal(rhs))
      }
      if comparison == .orderedSame {
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
  }

  private var totalDownload: Int64 {
    store.usageRows.reduce(0) { $0 + $1.downloadBytes }
  }

  private var totalUpload: Int64 {
    store.usageRows.reduce(0) { $0 + $1.uploadBytes }
  }

  private var trafficDomain: ClosedRange<Double> {
    let maximum = store.usageHistory.reduce(1.0) { partial, point in
      max(partial, max(point.upload, point.download))
    }
    return 0...maximum
  }

  private func rowTotal(_ row: UsageRow) -> Int64 {
    row.uploadBytes + row.downloadBytes
  }

  private func repairSelection() {
    if selectionDimension != store.usageDimension {
      selectionDimension = store.usageDimension
      selectedRow = nil
      expandedDetailRow = nil
      detailSearch = ""
    }
    guard !store.usageRows.isEmpty else {
      selectedRow = nil
      expandedDetailRow = nil
      return
    }
    if selectedRow == nil || !store.usageRows.contains(where: { $0.name == selectedRow }) {
      selectedRow = rankingRows.first?.name
      expandedDetailRow = nil
    }
    if let expandedDetailRow,
      !breakdownRows.contains(where: { $0.name == expandedDetailRow })
    {
      self.expandedDetailRow = nil
    }
  }

  private func symbol(for dimension: UsageDimension) -> String {
    switch dimension {
    case .device: "desktopcomputer"
    case .user: "person"
    case .host: "globe"
    case .proxy: "arrow.left.arrow.right"
    case .process: "cpu"
    }
  }

  private func numericComparison(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
  }
}
