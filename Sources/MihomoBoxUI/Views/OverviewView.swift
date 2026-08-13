import SwiftUI

@MainActor
public struct OverviewView: View {
  @ObservedObject private var store: DashboardStore

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DashboardTheme.sectionSpacing) {
        DashboardPageHeader(title: "Overview", subtitle: "Live Mihomo runtime at a glance") {
          Button {
            Task { await store.refresh(.overview) }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .buttonStyle(DashboardSecondaryButtonStyle())
          .keyboardShortcut("r", modifiers: .command)
          .help("Refresh overview (⌘R)")
        }

        switch store.overviewState {
        case .loaded:
          loadedContent
        case .loading, .empty, .failed:
          DashboardPageStateView(state: store.overviewState, emptyTitle: "No runtime metrics") {
            Task { await store.refresh(.overview) }
          }
          .frame(minHeight: 460)
        }
      }
      .padding(DashboardTheme.sectionSpacing)
    }
    .background(DashboardTheme.background)
    .accessibilityElement(children: .contain)
  }

  private var loadedContent: some View {
    VStack(alignment: .leading, spacing: DashboardTheme.spacing) {
      DashboardCard {
        HStack(spacing: 12) {
          Image(systemName: store.runtimeStatus.symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(store.runtimeStatus.color)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(store.runtimeStatus.title)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(DashboardTheme.content)
            Text(store.runtimeMessage)
              .font(.system(size: 12))
              .foregroundStyle(DashboardTheme.muted)
          }
          Spacer()
          StatusPill(store.runtimeStatus.title, color: store.runtimeStatus.color)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Runtime \(store.runtimeStatus.title). \(store.runtimeMessage)")

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: DashboardTheme.spacing)],
        spacing: DashboardTheme.spacing
      ) {
        MetricCard(
          title: "Upload speed",
          value: DashboardFormat.speed(store.traffic.uploadSpeed),
          symbol: "arrow.up",
          tint: DashboardTheme.secondary
        )
        MetricCard(
          title: "Download speed",
          value: DashboardFormat.speed(store.traffic.downloadSpeed),
          symbol: "arrow.down",
          tint: DashboardTheme.info
        )
        MetricCard(
          title: "Upload total",
          value: DashboardFormat.bytes(store.traffic.uploadTotal),
          symbol: "icloud.and.arrow.up",
          tint: DashboardTheme.secondary
        )
        MetricCard(
          title: "Download total",
          value: DashboardFormat.bytes(store.traffic.downloadTotal),
          symbol: "icloud.and.arrow.down",
          tint: DashboardTheme.info
        )
        MetricCard(
          title: "Connections",
          value: store.traffic.activeConnections.formatted(),
          symbol: "network",
          tint: DashboardTheme.accent
        )
        MetricCard(
          title: "Memory",
          value: DashboardFormat.bytes(store.traffic.memoryBytes),
          symbol: "memorychip",
          tint: DashboardTheme.warning
        )
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 250), spacing: DashboardTheme.spacing)],
        spacing: DashboardTheme.spacing
      ) {
        trendCard(
          title: "Download traffic",
          value: DashboardFormat.speed(store.traffic.downloadSpeed),
          values: store.trafficHistory.map(\.download),
          color: DashboardTheme.info
        )
        trendCard(
          title: "Upload traffic",
          value: DashboardFormat.speed(store.traffic.uploadSpeed),
          values: store.trafficHistory.map(\.upload),
          color: DashboardTheme.secondary
        )
        trendCard(
          title: "Memory usage",
          value: DashboardFormat.bytes(store.traffic.memoryBytes),
          values: store.memoryHistory.map(\.value),
          color: DashboardTheme.warning
        )
      }
    }
  }

  private func trendCard(title: String, value: String, values: [Double], color: Color) -> some View
  {
    DashboardCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DashboardTheme.muted)
          Spacer()
          Text(value)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardTheme.content)
        }
        if values.count > 1 {
          DashboardSparkline(values: values, color: color)
            .frame(height: 72)
        } else {
          Text("Waiting for samples")
            .font(.system(size: 12))
            .foregroundStyle(DashboardTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 72)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(value)")
  }
}
