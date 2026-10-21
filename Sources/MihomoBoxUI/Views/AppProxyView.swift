import SwiftUI
import MihomoControl

struct AppProxyView: View {
    @ObservedObject var dashboard: DashboardStore
    @ObservedObject var model: AppProxyStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("App Proxy", systemImage: "app.connected.to.app.below.fill")
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                    Text(model.extensionStatus.connected ? "Connected" : (model.extensionStatus.enabled ? "Enabled · disconnected" : "Off"))
                        .foregroundStyle(model.extensionStatus.connected ? Color.green : .secondary)
                    Button("Refresh") { Task { await model.refresh() } }
                }
                Text("Choose a proxy node or group for each application. Signed helpers inside an app follow its route.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add App or CLI…", systemImage: "plus") { Task { await model.addApplication() } }
                        .disabled(model.extensionStatus.enabled || model.routing == nil || model.draft.applications.count >= 32)
                    Button("Restore Default Apps") { model.restoreDefaults() }
                        .disabled(model.extensionStatus.enabled || model.routing == nil)
                    Spacer()
                    if model.dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.orange) }
                }
                if model.extensionStatus.enabled {
                    Text("Disable App Proxy before adding or removing applications. Node selections can be applied while connected.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.draft.applications.isEmpty {
                    ContentUnavailableView("No applications", systemImage: "app.dashed", description: Text("Add an application or restore the default apps."))
                }
                ForEach(model.draft.applications) { app in applicationCard(app) }
                if let error = model.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if !model.extensionStatus.available {
                    Text("Activation requires the signed MihomoBox system extension.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if model.refreshing || dashboard.configAction == .updatingAppProxy { ProgressView().controlSize(.small) }
                    Button("Apply Routes") { Task { await dashboard.applyAppProxyRoutes() } }
                        .disabled(model.routing == nil || !model.valid || !model.dirty)
                    Spacer()
                    if model.extensionStatus.enabled {
                        Button("Disable App Proxy") { Task { await dashboard.setAppProxyEnabled(false) } }
                    } else {
                        Button("Enable App Proxy…") { Task { await dashboard.setAppProxyEnabled(true) } }
                            .disabled(!model.extensionStatus.available || model.routing == nil || model.dirty || !model.valid || model.draft.routes.isEmpty)
                    }
                }
                Text("Apply Routes saves the application list and restarts the proxy runtime. Existing connections may be interrupted. DNS outside selected app flows follows macOS settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(DashboardTheme.background)
        .disabled(dashboard.configAction != nil || model.refreshing)
        .task { await model.refresh() }
    }

    private func applicationCard(_ app: AppProxyEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.title).font(.headline)
                    if let path = app.path { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer(minLength: 20)
                Picker(app.title, selection: Binding(
                    get: { model.draft.routes[app.id] ?? "" },
                    set: { model.draft.routes[app.id] = $0 }
                )) {
                    Text("Choose a node…").tag("")
                    if let current = model.draft.routes[app.id], !model.nodes.contains(current), !model.groups.contains(current) {
                        Text("Unavailable: \(current)").tag(current)
                    }
                    Section("Nodes") { ForEach(model.nodes, id: \.self) { Text($0).tag($0) } }
                    Section("Groups") { ForEach(model.groups, id: \.self) { Text($0).tag($0) } }
                }.labelsHidden().frame(maxWidth: 300)
                    .accessibilityLabel("\(app.title) proxy")
                Button(role: .destructive) { model.removeApplication(app.id) } label: { Image(systemName: "trash") }
                    .disabled(model.extensionStatus.enabled)
                    .help("Remove from App Proxy; the application stays installed")
                    .accessibilityLabel("Remove \(app.title)")
            }
            DisclosureGroup("Signed executables (\(model.extensionStatus.targetCounts[app.id, default: 0]))") {
                let executables = model.extensionStatus.executables.filter { $0.applicationID == app.id }
                if executables.isEmpty {
                    Text("No matching signed executables found. Install the application, then refresh.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                ForEach(executables) { executable in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(executable.path).font(.system(.caption, design: .monospaced))
                        Text("Signing ID: \(executable.signingIdentifier)").font(.caption)
                        Text("Team ID: \(executable.teamIdentifier ?? "None")").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Designated requirement") {
                            Text(executable.requirement).font(.system(.caption2, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(DashboardTheme.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .font(.callout)
        }
        .padding(18)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
