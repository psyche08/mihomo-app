import SwiftUI
import MihomoControl

struct AppProxyView: View {
    @ObservedObject var dashboard: DashboardStore
    @ObservedObject var model: AppProxyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("App Proxy", systemImage: "app.connected.to.app.below.fill").font(.headline)
                Spacer()
                Text(model.extensionStatus.connected ? "Connected" : (model.extensionStatus.enabled ? "Enabled · disconnected" : "Off"))
                    .foregroundStyle(model.extensionStatus.connected ? Color.green : .secondary)
                Button("Refresh") { Task { await model.refresh() } }
            }
            Text("Choose a node for each app, or a group to follow its current selection. Signed helpers use their parent app’s route. Terminal and editor rules cover only Codex and Claude tools.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(AppProxyApplication.allCases) { app in
                HStack {
                    VStack(alignment: .leading) {
                        Text(app.title)
                        Text("\(model.extensionStatus.targetCounts[app.rawValue, default: 0]) signed executables discovered")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Picker(app.title, selection: Binding(
                        get: { model.draft.routes[app.rawValue] ?? "" },
                        set: { model.draft.routes[app.rawValue] = $0 }
                    )) {
                        Text("Choose a node…").tag("")
                        if let current = model.draft.routes[app.rawValue], !model.nodes.contains(current), !model.groups.contains(current) {
                            Text("Unavailable: \(current)").tag(current)
                        }
                        Section("Nodes") { ForEach(model.nodes, id: \.self) { Text($0).tag($0) } }
                        Section("Groups") { ForEach(model.groups, id: \.self) { Text($0).tag($0) } }
                    }.labelsHidden().frame(maxWidth: 340)
                      .accessibilityLabel("\(app.title) proxy")
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if !model.extensionStatus.available {
                Text("App Proxy requires the signed system extension bundled with MihomoBox. Local development builds cannot activate it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("DNS outside selected app flows continues to follow macOS DNS settings.").font(.caption).foregroundStyle(.secondary)
            Text("Applying restarts the managed proxy runtime and may interrupt existing connections. Settings also apply after profile changes; each selected node must exist in the new profile. Disable the earlier standalone App Proxy experiment before enabling this extension.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.refreshing || dashboard.configAction == .updatingAppProxy { ProgressView().controlSize(.small) }
                Button("Apply Routes") { Task { await dashboard.applyAppProxyRoutes() } }
                    .disabled(model.routing == nil || !model.valid || !model.dirty)
                Button("Reset Routes") { Task { await dashboard.resetAppProxyRoutes() } }
                    .disabled(model.routing == nil || model.extensionStatus.enabled || model.routing?.settings.routes.isEmpty != false)
                Spacer()
                if model.extensionStatus.enabled {
                    Button("Disable App Proxy") { Task { await dashboard.setAppProxyEnabled(false) } }
                } else {
                    Button("Enable App Proxy…") { Task { await dashboard.setAppProxyEnabled(true) } }
                        .disabled(!model.extensionStatus.available || model.routing == nil || model.dirty || !model.valid)
                }
            }
        }
        .padding(18)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .disabled(dashboard.configAction != nil || model.refreshing)
        .task { await model.refresh() }
    }
}
