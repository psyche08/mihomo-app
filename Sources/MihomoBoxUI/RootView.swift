import SwiftUI

@MainActor
public struct RootView: View {
  @StateObject private var store: DashboardStore
  @State private var selection: DashboardPage = .overview
  @State private var sidebarExpanded = false

  public init() {
    _store = StateObject(wrappedValue: DashboardStore.shared)
  }

  public init(store: DashboardStore) {
    _store = StateObject(wrappedValue: store)
  }

  public var body: some View {
    GeometryReader { geometry in
      let canExpandSidebar = geometry.size.width >= 1_040
      let compactSidebar = !canExpandSidebar || !sidebarExpanded
      HStack(spacing: 0) {
        sidebar(compact: compactSidebar, canExpand: canExpandSidebar)
          .frame(width: compactSidebar ? 64 : 208)

        Divider()
          .overlay(DashboardTheme.divider)

        page
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DashboardTheme.background)
      }
      .animation(.easeInOut(duration: 0.18), value: compactSidebar)
    }
    .frame(minWidth: 900, minHeight: 600)
    .background(DashboardTheme.background)
    .preferredColorScheme(.dark)
    .onChange(of: selection) { _, page in
      Task { await store.refresh(page) }
    }
    .alert("Action Failed", isPresented: actionErrorPresented) {
      Button("OK") { store.dismissActionError() }
    } message: {
      Text(store.actionError ?? "The controller action failed.")
    }
  }

  private var actionErrorPresented: Binding<Bool> {
    Binding(
      get: { store.actionError != nil },
      set: { presented in
        if !presented { store.dismissActionError() }
      }
    )
  }

  private func sidebar(compact: Bool, canExpand: Bool) -> some View {
    VStack(alignment: compact ? .center : .leading, spacing: 10) {
      HStack(spacing: 9) {
        if compact {
          Button {
            if canExpand { sidebarExpanded = true }
          } label: {
            Image(systemName: "chevron.right.2")
              .font(.system(size: 13, weight: .bold))
              .frame(width: 38, height: 38)
          }
          .buttonStyle(.plain)
          .foregroundStyle(DashboardTheme.muted)
          .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
          .overlay {
            RoundedRectangle(cornerRadius: 9)
              .stroke(DashboardTheme.divider, lineWidth: 1)
          }
          .disabled(!canExpand)
          .accessibilityLabel(canExpand ? "Expand sidebar" : "Sidebar compact")
          .help(canExpand ? "Expand sidebar" : "Enlarge the window to expand the sidebar")
        } else {
          Image(systemName: "wave.3.right.circle.fill")
            .font(.system(size: 27, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(DashboardTheme.primary, DashboardTheme.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text("MihomoBox")
              .font(.system(size: 16, weight: .bold))
              .foregroundStyle(DashboardTheme.content)
            Text("Native Dashboard")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardTheme.muted)
          }
          Spacer(minLength: 0)
          Button {
            sidebarExpanded = false
          } label: {
            Image(systemName: "chevron.left.2")
              .font(.system(size: 11, weight: .bold))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
          .foregroundStyle(DashboardTheme.muted)
          .accessibilityLabel("Collapse sidebar")
          .help("Collapse sidebar")
        }
      }
      .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
      .padding(.horizontal, compact ? 8 : 12)
      .padding(.bottom, 8)
      .accessibilityElement(children: .combine)

      ForEach(DashboardPage.allCases) { page in
        Button {
          selection = page
        } label: {
          HStack(spacing: 11) {
            Image(systemName: page.symbol)
              .font(.system(size: 15, weight: .semibold))
              .frame(width: 22)
            if !compact {
              Text(page.title)
                .font(.system(size: 13, weight: .semibold))
              Spacer(minLength: 0)
            }
          }
          .foregroundStyle(selection == page ? DashboardTheme.primary : DashboardTheme.muted)
          .padding(.horizontal, compact ? 12 : 13)
          .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
          .background(
            selection == page ? DashboardTheme.primary.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
          )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(page.shortcut, modifiers: .command)
        .accessibilityLabel(page.title)
        .accessibilityHint("Open \(page.title), Command \(page.shortcutLabel)")
        .help("\(page.title) (⌘\(page.shortcutLabel))")
      }

      Spacer(minLength: 12)

      if !compact {
        HStack(spacing: 8) {
          Circle()
            .fill(store.runtimeStatus.color)
            .frame(width: 7, height: 7)
          Text(store.runtimeStatus.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DashboardTheme.muted)
        }
        .padding(.horizontal, 13)
        .accessibilityElement(children: .combine)
        .help(store.runtimeMessage)
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 8)
    .background(Color(hex: 0x0E171E))
  }

  @ViewBuilder
  private var page: some View {
    switch selection {
    case .overview:
      OverviewView(store: store)
    case .proxies:
      ProxiesView(store: store)
    case .rules:
      RulesView(store: store)
    case .connections:
      ConnectionsView(store: store)
    case .usage:
      UsageView(store: store)
    case .logs:
      LogsView(store: store)
    case .config:
      ConfigView(store: store)
    }
  }
}
