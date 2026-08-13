import SwiftUI

@MainActor
public struct ConfigView: View {
  @ObservedObject private var store: DashboardStore

  public init(store: DashboardStore) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DashboardTheme.sectionSpacing) {
        configHeader

        switch store.configState {
        case .loaded:
          loadedContent
        case .loading, .empty, .failed:
          DashboardPageStateView(state: store.configState, emptyTitle: "No configuration available")
          {
            Task { await store.refresh(.config) }
          }
          .frame(minHeight: 470)
        }
      }
      .padding(DashboardTheme.sectionSpacing)
    }
    .background(DashboardTheme.background)
  }

  private var configHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "gearshape.2")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(DashboardTheme.primary)
        .frame(width: 48, height: 48)
        .background(DashboardTheme.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Config")
          .font(.system(size: 21, weight: .bold))
          .foregroundStyle(DashboardTheme.content)
        Label("Signed XPC · daemon-owned runtime", systemImage: "lock.shield")
          .font(.system(size: 11))
          .foregroundStyle(DashboardTheme.muted.opacity(0.72))
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 6) {
        headerBadge("Native SwiftUI")
        headerBadge(coreVersionLabel)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var loadedContent: some View {
    VStack(alignment: .leading, spacing: DashboardTheme.spacing) {
      HStack(alignment: .top, spacing: DashboardTheme.spacing) {
        coreConfigPanel
          .frame(minWidth: 360, maxWidth: .infinity)
        capabilitiesPanel
          .frame(minWidth: 360, maxWidth: .infinity)
      }

      actionsPanel
    }
  }

  private var coreConfigPanel: some View {
    configPanel("Core Config", symbol: "square.3.layers.3d") {
      VStack(spacing: 8) {
        settingRow("Allow LAN", symbol: "globe") {
          Toggle(
            "Allow LAN",
            isOn: Binding(
              get: { store.configuration.allowLAN },
              set: { value in Task { await store.setAllowLANEnabled(value) } }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        settingRow("Running Mode", symbol: "bolt") {
          Picker(
            "Running Mode",
            selection: Binding(
              get: { store.configuration.mode },
              set: { mode in Task { await store.setMode(mode) } }
            )
          ) {
            ForEach(DashboardProxyMode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 122)
        }

        settingRow("Unified Delay", symbol: "clock") {
          Toggle(
            "Unified Delay",
            isOn: Binding(
              get: { store.configuration.unifiedDelay },
              set: { value in Task { await store.setUnifiedDelayEnabled(value) } }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        settingRow("Log Level", symbol: "text.alignleft") {
          Picker(
            "Log Level",
            selection: Binding(
              get: { store.configuration.logLevel },
              set: { level in Task { await store.setCoreLogLevel(level) } }
            )
          ) {
            ForEach(ControllerLogLevel.allCases, id: \.self) { level in
              Text(level.rawValue.capitalized).tag(level)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 122)
        }

        settingRow("TCP Concurrent", symbol: "arrow.triangle.branch") {
          Toggle(
            "TCP Concurrent",
            isOn: Binding(
              get: { store.configuration.tcpConcurrent },
              set: { value in Task { await store.setTCPConcurrentEnabled(value) } }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        settingRow("Find Process Mode", symbol: "app.badge.checkmark") {
          Picker(
            "Find Process Mode",
            selection: Binding(
              get: { store.configuration.findProcessMode },
              set: { mode in Task { await store.setFindProcessMode(mode) } }
            )
          ) {
            ForEach(ControllerFindProcessMode.allCases, id: \.self) { mode in
              Text(mode.rawValue.capitalized).tag(mode)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 122)
        }

        settingRow("IPv6", symbol: "network") {
          Toggle(
            "IPv6",
            isOn: Binding(
              get: { store.configuration.ipv6Enabled },
              set: { value in Task { await store.setIPv6Enabled(value) } }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        sectionDivider("TUN")

        settingRow("Enhanced TUN", symbol: "wifi") {
          HStack(spacing: 7) {
            Image(systemName: "lock.fill")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(DashboardTheme.muted)
            StatusPill(
              store.configuration.enhancedTUNEnabled ? "On" : "Off",
              color: store.configuration.enhancedTUNEnabled
                ? DashboardTheme.success : DashboardTheme.muted
            )
          }
        }

        settingRow("TUN Mode Stack") {
          managedValue(store.configuration.tunStack.rawValue)
        }

        settingRow("Outbound Interface") {
          managedValue(store.configuration.networkInterface)
        }

        Text(
          "Enhanced TUN remains read-only here. Its lifecycle, DNS restore and startup transaction stay in the signed daemon and menu bar."
        )
        .font(.system(size: 10))
        .foregroundStyle(DashboardTheme.muted.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)

        sectionDivider("PORTS")

        HStack(spacing: 10) {
          portField("Mixed Port", value: store.configuration.mixedPort)
          portField("HTTP Port", value: store.configuration.httpPort)
          portField("SOCKS Port", value: store.configuration.socksPort)
        }
      }
    }
  }

  private var capabilitiesPanel: some View {
    configPanel("Capabilities & Privacy", symbol: "lock.shield") {
      VStack(spacing: 8) {
        Text(
          "Read-only application guarantees. Runtime values and controls remain in the signed XPC-backed Core Config panel."
        )
        .font(.system(size: 10))
        .foregroundStyle(DashboardTheme.muted.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)

        settingRow("Controller Transport", symbol: "lock.shield") {
          managedValue("Signed XPC")
        }

        settingRow("Data Usage", symbol: "chart.xyaxis.line") {
          managedValue("Session only")
        }

        settingRow("Runtime Details", symbol: "textformat.abc") {
          managedValue("Controller data")
        }

        sectionDivider("PRIVACY & BOUNDS")

        settingRow("Log Redaction", symbol: "eye.slash") {
          StatusPill("Enforced", color: DashboardTheme.success)
        }

        settingRow("Log Buffer", symbol: "doc.on.doc") {
          managedValue("500 in memory")
        }

        settingRow("Usage Retention", symbol: "clock.arrow.circlepath") {
          managedValue("Bounded memory")
        }

        Text(
          "Packets, controller credentials and subscription URLs are never collected by the native window."
        )
        .font(.system(size: 10))
        .foregroundStyle(DashboardTheme.muted.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
      }
    }
  }

  private var actionsPanel: some View {
    configPanel("Core Config – Actions", symbol: "wrench.and.screwdriver") {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 145), spacing: 10)],
        spacing: 10
      ) {
        actionButton("Reload Config", symbol: "arrow.clockwise", tint: DashboardTheme.primary) {
          await store.reloadConfiguration()
        }
        actionButton("Restart Core", symbol: "play.fill", tint: DashboardTheme.warning) {
          await store.restartRuntime()
        }
        actionButton("Flush Fake-IP", symbol: "cube", tint: DashboardTheme.accent) {
          await store.flushFakeIPCache()
        }
        actionButton("Flush DNS Cache", symbol: "externaldrive", tint: DashboardTheme.info) {
          await store.flushDNSCache()
        }
        actionButton(
          "Update GEO Data", symbol: "globe.asia.australia", tint: DashboardTheme.secondary
        ) {
          await store.updateGeoData()
        }
      }
    }
  }

  private func configPanel<Content: View>(
    _ title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted)
          .frame(width: 20)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
        Spacer()
      }
      .padding(.horizontal, 16)
      .frame(height: 48)
      .background(DashboardTheme.surfaceRaised.opacity(0.52))

      Divider().overlay(DashboardTheme.divider)

      content()
        .padding(16)
    }
    .background(DashboardTheme.surface.opacity(0.68))
    .clipShape(RoundedRectangle(cornerRadius: DashboardTheme.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DashboardTheme.cardRadius)
        .stroke(DashboardTheme.primary.opacity(0.22), lineWidth: 1)
    }
  }

  private func settingRow<Control: View>(
    _ title: String,
    symbol: String? = nil,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(DashboardTheme.muted.opacity(0.72))
            .frame(width: 16)
            .accessibilityHidden(true)
        } else {
          Color.clear.frame(width: 16, height: 1)
        }
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(DashboardTheme.content)
      }
      Spacer(minLength: 8)
      control()
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 36)
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
  }

  private func sectionDivider(_ title: String) -> some View {
    HStack(spacing: 12) {
      Divider().overlay(DashboardTheme.divider)
      Text(title)
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(DashboardTheme.muted.opacity(0.48))
        .fixedSize()
      Divider().overlay(DashboardTheme.divider)
    }
    .frame(height: 30)
    .accessibilityHidden(true)
  }

  private func portField(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(DashboardTheme.muted.opacity(0.68))
      HStack(spacing: 6) {
        Text(value.formatted(.number.grouping(.never)))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .monospacedDigit()
        Spacer(minLength: 0)
        Image(systemName: "lock.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(DashboardTheme.muted.opacity(0.62))
      }
      .foregroundStyle(DashboardTheme.content)
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, minHeight: 32)
      .background(DashboardTheme.background.opacity(0.34), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(value), managed by active profile")
  }

  private func managedValue(_ value: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "lock.fill")
        .font(.system(size: 8, weight: .semibold))
        .accessibilityHidden(true)
      Text(value.isEmpty ? "Automatic" : value)
        .lineLimit(1)
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(DashboardTheme.muted)
    .padding(.horizontal, 8)
    .frame(minWidth: 86, minHeight: 27)
    .background(DashboardTheme.background.opacity(0.30), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
    .accessibilityLabel("\(value), read only")
  }

  private func actionButton(
    _ title: String,
    symbol: String,
    tint: Color,
    action: @escaping @MainActor () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .semibold))
        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, minHeight: 36)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(tint.opacity(0.22), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private func headerBadge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .foregroundStyle(DashboardTheme.muted)
      .padding(.horizontal, 9)
      .frame(height: 25)
      .background(DashboardTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
  }

  private var coreVersionLabel: String {
    store.coreVersion
  }
}
