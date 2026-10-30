import SwiftUI
import MihomoControl

struct AppProxyView: View {
    @ObservedObject var dashboard: DashboardStore
    @ObservedObject var model: AppProxyStore
    @State private var search = ""
    @State private var inspecting: AppProxyEntry?
    @State private var editingExecutables: AppProxyEntry?
    @State private var editingBypass = false
    @State private var confirming: AppProxyEntry?
    @State private var addingPath = false
    @State private var newPath = ""
    @State private var dropTargeted = false

    private var busy: Bool { dashboard.configAction != nil || model.busy }
    private var canAdd: Bool {
        !busy && !model.refreshing && !model.extensionStatus.enabled && model.routing != nil && model.draft.applications.count < 32
    }
    private var changeSummary: String {
        if busy { return "Updating App Proxy…" }
        if model.routing == nil { return model.refreshing ? "Loading settings…" : "Refresh to verify saved settings" }
        guard model.dirty else { return "All changes saved" }
        let count = model.changedApplicationCount
        if count == 0 { return "Network bypass has unsaved changes" }
        return "\(count) \(count == 1 ? "app" : "apps") with unsaved changes"
    }
    private var applications: [AppProxyEntry] {
        model.draft.applications.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || ($0.path?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if model.draft.teamPresetMigration != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("These four legacy presets can be merged into OpenAI and Anthropic Team ID policies. Your proxy nodes and network bypasses are kept.")
                        Button("Use Team ID Defaults") { model.restoreDefaults() }
                            .disabled(busy || model.refreshing || model.extensionStatus.enabled)
                        Text("Turn App Proxy off, apply the change, then review code access when enabling it.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }
                bypassSummary.padding(.horizontal, 16).padding(.top, 16)
                LazyVStack(spacing: 1) {
                    if model.draft.applications.isEmpty {
                        ContentUnavailableView("No applications", systemImage: "app.dashed",
                                               description: Text("Add an application or restore the default apps."))
                    } else if applications.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                    ForEach(applications) { app in applicationRow(app) }
                }
                .padding(16)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard canAdd, !urls.isEmpty else { return false }
                Task { for url in urls where url.isFileURL { await model.addApplication(path: url.path) } }
                return true
            } isTargeted: { dropTargeted = $0 && canAdd }
            Divider()
            actionBar
        }
        .background(DashboardTheme.background)
        .sheet(item: $inspecting) { app in executableDetails(app) }
        .sheet(item: $confirming) { app in authorizationConfirmation(app) }
        .sheet(item: $editingExecutables) { app in
            AppProxyExecutableEditor(model: model, application: app)
        }
        .sheet(isPresented: $editingBypass) { AppProxyBypassEditor(model: model) }
    }

    private var bypassSummary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local networks and VPNs").font(.headline)
                if model.extensionStatus.requiresReactivation {
                    Text("Turn App Proxy off and on to upgrade identity authorization and network bypass settings.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text(model.draft.bypass.cidrs.isEmpty
                     ? "Only loopback callbacks bypass the selected app node."
                     : "\(model.draft.bypass.cidrs.count) IP ranges use macOS routing before the app node, including existing private VPN routes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit Bypass…") { editingBypass = true }
                .disabled(busy || model.refreshing || model.extensionStatus.enabled || model.routing == nil)
                .help("Turn off App Proxy before editing network bypasses")
        }
        .padding(12).background(DashboardTheme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("App Proxy", systemImage: "app.connected.to.app.below.fill")
                    .font(.system(size: 24, weight: .bold))
                Text("\(model.draft.applications.count) apps").foregroundStyle(.secondary)
                Spacer()
                Label(model.extensionStatus.identityReady ? "Code access verified" : (model.extensionStatus.connected ? "Awaiting identity verification" : (model.extensionStatus.enabled ? "Disconnected" : "Off")),
                      systemImage: model.extensionStatus.connected ? "circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(model.extensionStatus.identityReady ? Color.green : .orange)
            }
            if let issue = model.extensionStatus.identityIssue {
                Text(issue == "rollbackUnverified" ? "App Proxy could not verify that interception was disabled. Check MihomoBox VPN status in System Settings before retrying." : "Application identity protection: \(issue). Review code access, then turn App Proxy off and on to retry.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !model.extensionStatus.discoveryIssues.isEmpty {
                Text("Discovery exclusions: " + model.extensionStatus.discoveryIssues.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.extensionStatus.identityReady {
                Text("\(model.extensionStatus.verifiedTargetCount) executable identities verified. DNS and API reachability require application traffic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostics = model.extensionStatus.diagnostics {
                DisclosureGroup("Recent process validation (no traffic contents)") {
                    Text("Generation: " + (diagnostics.generation?.uuidString ?? "unknown"))
                        .font(.caption).textSelection(.enabled)
                    ForEach(Array(diagnostics.recentFlows.enumerated()), id: \.offset) { _, event in
                        Text("t=\(event.uptime, specifier: "%.3f") PID \(event.pid) / PID version \(event.pidVersion): \(event.stage) · flow \(event.flow.uuidString.prefix(8)) · policy \(event.generation?.uuidString.prefix(8) ?? "unknown")")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("These receipts prove only the listed stages. Confirm API recovery in the originating application.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Running Mode")
                Picker("Running Mode", selection: Binding(
                    get: { dashboard.configuration.mode },
                    set: { mode in Task { await dashboard.setMode(mode) } }
                )) {
                    ForEach(DashboardProxyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                .disabled(busy || model.refreshing || dashboard.configState != .loaded)
                .help("Uses the same running mode as MihomoBox. Changes apply to new connections.")
                Spacer()
            }
            Text(modeDescription).foregroundStyle(.secondary)
            if case .failed(let message) = dashboard.configState {
                Text("Running mode unavailable: \(message)").font(.callout).foregroundStyle(.red)
            }
            HStack {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityLabel("Search applications")
                Button("Add App or CLI…", systemImage: "plus") { newPath = ""; addingPath = true }
                    .disabled(!canAdd)
                    .help(model.extensionStatus.enabled ? "Turn off App Proxy to change the application list" : "Add a signed app or CLI executable, or drag one onto the list")
                    .popover(isPresented: $addingPath, arrowEdge: .bottom) { addPathPopover }
                Menu {
                    Button("Restore Team ID Defaults") { model.restoreDefaults() }
                        .disabled(model.extensionStatus.enabled || model.routing == nil || model.refreshing)
                    Button("Rescan Signed Executables") { Task { await model.refreshExecutables(force: true) } }
                        .disabled(model.scanning)
                    if !model.groups.isEmpty {
                        Divider()
                        Menu("Use Group for All Apps") {
                            ForEach(model.groups, id: \.self) { group in
                                Button(group) { model.selectTargetForAll(group) }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(busy).accessibilityLabel("Application actions")
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh Nodes", systemImage: "arrow.clockwise") { Task { await dashboard.refresh(.appProxy) } }
                    .disabled(busy || model.refreshing)
            }
        }
        .padding(20)
    }

    private var modeDescription: String {
        switch dashboard.configuration.mode {
        case .global: "Global: applications use MihomoBox's global node. Saved app nodes apply in Rule mode."
        case .rule: "Rule: follow profile rules; proxy rules use the app's selected node. Direct and reject rules stay unchanged."
        case .direct: "Direct: applications connect directly. Saved app nodes apply in Rule mode."
        }
    }

    private func applicationRow(_ app: AppProxyEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.id.contains("cli") || (app.path != nil && !(app.path?.hasSuffix(".app") ?? false)) ? "terminal" : "app")
                .font(.title2).foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.title).font(.headline).lineLimit(1).help(app.title)
                    if model.draft.routes[app.id] != model.routing?.settings.routes[app.id]
                        || app != model.routing?.settings.applications.first(where: { $0.id == app.id }) {
                        Text("Edited").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if let path = app.path {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path)
                }
                Button {
                    inspecting = app
                } label: {
                    Text(model.hasExecutableInventory ? "Signed executables · \(model.extensionStatus.targetCounts[app.id, default: 0])" : "Signed executables…")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Inspect signed executables for \(app.title)")
                Button(policySummary(app)) { editingExecutables = app }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .disabled(busy || model.routing == nil)
                    .accessibilityLabel("Edit routing policy for \(app.title)")
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                let state = model.extensionStatus.applications[app.id] ?? .init()
                Text(state.summary).font(.caption).foregroundStyle(state.active ? Color.green : Color.secondary)
                    .accessibilityLabel("\(app.title): \(state.summary)")
                HStack {
                    if !state.active {
                        Button(state.requested ? "Retry Authorization" : "Authorize & Enable") { confirming = app }
                    }
                    if state.requested || state.active {
                        Button("Disable") { Task { await dashboard.setAppProxyApplicationEnabled(app.id, enabled: false) } }
                    }
                }
                .disabled(busy || model.refreshing || model.hasConflict || model.routing == nil || model.dirty || !model.valid || !model.extensionStatus.available)
            }.frame(maxWidth: 280, alignment: .trailing)
            AppProxyTargetPicker(title: app.title, selection: model.draft.routes[app.id] ?? "",
                                 nodes: model.nodes, groups: model.groups) {
                model.selectTarget($0, for: app.id)
            }
            .frame(width: 230).disabled(busy || model.routing == nil)
            .help("Used when a profile rule chooses a proxy in Rule mode")
            Button(role: .destructive) { model.removeApplication(app.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(busy || model.refreshing || model.extensionStatus.enabled)
                .help(model.extensionStatus.enabled ? "Turn off App Proxy to remove an entry" : "Remove routing; keep the installed application")
                .accessibilityLabel("Remove \(app.title)")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func policySummary(_ app: AppProxyEntry) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String? { value == 0 ? nil : "\(value) \(value == 1 ? one : many)" }
        var parts = [count(app.teamIdentifiers.count, "team", "teams"), count(app.directories.count, "folder", "folders"),
                     count(app.executablePaths.count, "CLI", "CLIs")].compactMap { $0 }
        if parts.isEmpty { parts = ["app code only"] }
        if !app.capturesLaunchedCLIs { parts.append("launched CLIs direct") }
        return "Policy · " + parts.joined(separator: " · ")
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if model.hasConflict {
                Text("Saved settings changed elsewhere. Discard your edits to load the latest settings.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error = model.discoveryError {
                Text("Executable scan: \(error)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(changeSummary)
                        .font(.callout)
                    Text(model.scanning ? "Scanning signed executables… You can keep choosing nodes." : "Applying node, bypass or app-list changes restarts the proxy runtime; policy-only changes do not.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.dirty || model.hasConflict {
                    Button("Discard") { model.discardChanges() }
                        .disabled(busy || model.routing == nil || model.refreshing)
                }
                Button("Apply Changes") { Task { await dashboard.applyAppProxyRoutes() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || model.refreshing || model.hasConflict || model.routing == nil || !model.valid || !model.dirty)
                if model.extensionStatus.enabled {
                    Button("Turn Off") { Task { await dashboard.setAppProxyEnabled(false) } }
                        .disabled(busy || model.refreshing)
                        .accessibilityLabel("Disable App Proxy")
                } else {
                    Button("Resume Selected Apps") { Task { await dashboard.setAppProxyEnabled(true) } }
                        .disabled(busy || model.refreshing || model.hasConflict || !model.extensionStatus.available || model.routing == nil || model.dirty || !model.valid || model.draft.routes.isEmpty || !model.extensionStatus.applications.values.contains(where: \.requested))
                }
            }
            if !model.extensionStatus.available {
                Text("Activation requires the signed MihomoBox system extension.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(DashboardTheme.surface)
    }

    private var addPathPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add App or CLI").font(.headline)
            TextField("/Applications/Example.app or /usr/local/bin/tool", text: $newPath)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 400)
                .onSubmit(addTypedPath)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: \.isFileURL) else { return false }
                    newPath = url.path; return true
                }
                .accessibilityLabel("Application or executable path")
            Text("Paste a path, drag an app or executable here, or drop it straight onto the list.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose…") { addingPath = false; Task { await model.addApplication() } }
                Spacer()
                Button("Cancel") { addingPath = false }.keyboardShortcut(.cancelAction)
                Button("Add", action: addTypedPath)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(AppProxyStore.normalizedPath(newPath).isEmpty)
            }
        }
        .padding(16)
    }

    private func addTypedPath() {
        let path = newPath
        guard !AppProxyStore.normalizedPath(path).isEmpty else { return }
        addingPath = false
        Task { await model.addApplication(path: path) }
    }

    /// Scan, show what will be routed, then authorize on one click. No file picker:
    /// the code-access broker reads code locations read-only by itself.
    private func authorizationConfirmation(_ app: AppProxyEntry) -> some View {
        let executables = model.extensionStatus.executables.filter { $0.applicationID == app.id }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Authorize \(app.title)").font(.title2.bold())
                    Text("App Proxy will route these signed executables and read only their code to verify them.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if let error = model.discoveryError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            policyScopeSummary(app)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if executables.isEmpty {
                        Text(model.scanning ? "Scanning signatures…" : "No matching signed executables found. Install the app, then try again.")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                    groupedExecutables(app)
                }
            }
            HStack {
                Text("\(executables.count) signed \(executables.count == 1 ? "executable" : "executables")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { confirming = nil }.keyboardShortcut(.cancelAction)
                Button("Authorize & Enable") {
                    confirming = nil
                    Task { await dashboard.setAppProxyApplicationEnabled(app.id, enabled: true) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(busy || model.scanning || executables.isEmpty)
            }
        }
        .padding(20).frame(width: 680, height: 600)
        .background(DashboardTheme.background)
        .task { await model.refreshExecutables(force: true) }
    }

    /// What this consent covers beyond the listed files: scopes admit code that appears later.
    private func policyScopeSummary(_ app: AppProxyEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !app.teamIdentifiers.isEmpty { Text("Team IDs: " + app.teamIdentifiers.joined(separator: ", ")) }
            if !app.directories.isEmpty {
                Text("Folders: " + app.directories.joined(separator: ", ")).lineLimit(2).truncationMode(.middle)
            }
            if !app.executablePaths.isEmpty {
                Text("Exact CLIs: \(app.executablePaths.count)")
            }
            if !app.teamIdentifiers.isEmpty || !app.directories.isEmpty {
                Text("Approving also admits signed code added later under these Team IDs and folders.")
                    .foregroundStyle(.orange)
            }
            Text(app.capturesLaunchedCLIs
                 ? "Other selected apps’ CLIs started by \(app.title) keep their own nodes."
                 : "Other selected apps’ CLIs started by \(app.title) connect directly.")
                .foregroundStyle(.secondary)
        }
        .font(.callout).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private struct ExecutableGroup: Identifiable {
        let id: String
        let executables: [AppProxyExecutable]
    }

    /// Groups executables by the policy entry that admits them, most specific first.
    private func executableGroups(_ app: AppProxyEntry) -> [ExecutableGroup] {
        let appCode = "App and helpers"
        func title(_ executable: AppProxyExecutable) -> String {
            let path = executable.path
            if app.executablePaths.contains(path) { return "Exact CLIs" }
            if let folder = app.directories.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                return "Folder " + folder
            }
            if let bundle = app.path, path == bundle || path.hasPrefix(bundle + "/") { return appCode }
            if let team = executable.teamIdentifier, app.teamIdentifiers.contains(team) { return "Team " + team }
            return appCode
        }
        let grouped = Dictionary(grouping: model.extensionStatus.executables.filter { $0.applicationID == app.id }, by: title)
        func rank(_ title: String) -> Int {
            title == appCode ? 0 : title.hasPrefix("Team ") ? 1 : title.hasPrefix("Folder ") ? 2 : 3
        }
        return grouped.keys.sorted { (rank($0), $0) < (rank($1), $1) }
            .map { ExecutableGroup(id: $0, executables: grouped[$0] ?? []) }
    }

    @ViewBuilder private func groupedExecutables(_ app: AppProxyEntry) -> some View {
        ForEach(executableGroups(app)) { group in
            Text("\(group.id) · \(group.executables.count)").font(.headline).padding(.top, 4)
                .textSelection(.enabled)
            ForEach(group.executables) { executableRow($0) }
        }
    }

    private func executableRow(_ executable: AppProxyExecutable) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(executable.path).font(.system(.callout, design: .monospaced))
            Text("Signing ID: \(executable.signingIdentifier)").font(.caption)
            Text("Team ID: \(executable.teamIdentifier ?? "None")").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Designated requirement") {
                Text(executable.requirement).font(.system(.caption, design: .monospaced))
            }.font(.caption)
        }
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func executableDetails(_ app: AppProxyEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.title).font(.title2.bold())
                    Text("Signed executables").foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await model.refreshExecutables(force: true) } }
                    .disabled(model.scanning || busy)
                Button("Done") { inspecting = nil }.keyboardShortcut(.cancelAction)
            }
            if let error = model.discoveryError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !model.extensionStatus.executables.contains(where: { $0.applicationID == app.id }) {
                        Text(model.scanning ? "Checking signatures…" : "No matching signed executables found. Install the app, then rescan.")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                    groupedExecutables(app)
                }
            }
            Text("Rescan updates this list. App Proxy verifies signatures before enabling and refreshes identities while enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 680, height: 520)
        .background(DashboardTheme.background)
        .task { await model.refreshExecutables() }
    }
}

private struct AppProxyBypassEditor: View {
    @ObservedObject var model: AppProxyStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    init(model: AppProxyStore) {
        self.model = model
        _text = State(initialValue: model.draft.bypass.cidrs.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local networks and VPNs").font(.title2.bold())
            Text("Matching IP destinations use macOS routing before the selected node in every mode. DNS still uses Mihomo. Enter one IPv4 or IPv6 CIDR per line; leave empty to disable these bypasses. Loopback callbacks remain local.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                .accessibilityLabel("Network bypass CIDRs")
            Text("Add the specific range for VPNs using other addresses, such as 100.64.0.0/10. Public IP ranges also bypass your app node when explicitly listed. No default VPN route is automatically exempted.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Restore Private Ranges") { text = AppProxyBypassPolicy.defaultCIDRs.joined(separator: "\n") }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Draft") {
                    do {
                        try model.setBypassCIDRs(text.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 580)
    }
}

private struct AppProxyExecutableEditor: View {
    @ObservedObject var model: AppProxyStore
    let application: AppProxyEntry
    @Environment(\.dismiss) private var dismiss
    @State private var paths: String
    @State private var teams: String
    @State private var directories: String
    @State private var capturesLaunchedCLIs: Bool
    @State private var error: String?
    @State private var saving = false

    init(model: AppProxyStore, application: AppProxyEntry) {
        self.model = model; self.application = application
        _paths = State(initialValue: application.executablePaths.joined(separator: "\n"))
        _teams = State(initialValue: application.teamIdentifiers.joined(separator: "\n"))
        _directories = State(initialValue: application.directories.joined(separator: "\n"))
        _capturesLaunchedCLIs = State(initialValue: application.capturesLaunchedCLIs)
    }
    private var locked: Bool { model.busy || model.refreshing || model.extensionStatus.enabled || model.hasConflict }
    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map(AppProxyStore.normalizedPath).filter { !$0.isEmpty }
    }
    private var entries: [String] { lines(paths) }
    private var directoryEntries: [String] { lines(directories) }
    private var teamEntries: [String] {
        teams.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }
    private var unchanged: Bool {
        entries == application.executablePaths && teamEntries == application.teamIdentifiers
            && directoryEntries == application.directories && capturesLaunchedCLIs == application.capturesLaunchedCLIs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Routing policy").font(.title2.bold())
                Text(application.title).font(.headline)
                Text("Choose the code that uses this app’s node. One entry per line; type, paste or drag items in.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeSection("Team IDs", hint: "All signed apps in Applications and CLIs in the usual bin folders from these developers. Drop an app to add its Team ID.",
                                 text: $teams, label: "Team IDs") { urls in
                        urls.compactMap { AppProxyStore.teamIdentifier(ofCodeAt: Bundle(url: $0)?.executableURL?.path ?? $0.path) }
                    }
                    scopeSection("Directories", hint: "All signed executables under these folders, including versions installed later. Apple’s own programs are skipped.",
                                 text: $directories, label: "Directories") { urls in
                        urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                    }
                    scopeSection("CLI executables", hint: "Exactly these executables, for example /usr/bin/curl. Scripts require their interpreter.",
                                 text: $paths, label: "CLI executable paths") { urls in
                        urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                    }
                    Divider()
                    launchSection
                }
                .padding(.trailing, 6)
            }
            if model.extensionStatus.enabled {
                Label("Turn off App Proxy before editing this policy.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.hasConflict { Text("Discard conflicting changes on the App Proxy page before editing.").foregroundStyle(.orange) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Choose Executable…") {
                    Task {
                        do {
                            if let path = try await model.chooseExecutable(), !entries.contains(path) {
                                paths = (entries + [path]).joined(separator: "\n")
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(locked || saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving || model.busy)
                Button("Update Draft") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            try await model.setPolicy(executablePaths: entries, teamIdentifiers: teamEntries,
                                                      directories: directoryEntries,
                                                      capturesLaunchedCLIs: capturesLaunchedCLIs, for: application.id)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(locked || saving || unchanged)
            }
            Text("Update Draft scans and verifies signatures. Apply Changes on the App Proxy page saves the policy; then authorize the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 680, height: 720)
        .interactiveDismissDisabled(saving || model.busy)
        .task { await model.refreshExecutables() }
    }

    /// Capture follows the process that launched a CLI, not the CLI alone.
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where CLIs are captured").font(.headline)
            Text("A CLI matched here uses this node when it runs on its own, from \(application.title), from another selected app that routes launched CLIs, or from these launchers. Started from any other app it is not routed, and its connections may be refused.")
                .font(.caption).foregroundStyle(.secondary)
            Text(launcherNames).font(.callout).textSelection(.enabled)
                .accessibilityLabel("Detected launchers")
            Toggle("Route other selected apps’ CLIs launched by \(application.title)", isOn: $capturesLaunchedCLIs)
                .disabled(locked || saving)
            Text("For example, codex started by Claude Code keeps the codex CLI’s own node. Off, such CLIs connect directly.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var launcherNames: String {
        var seen = Set<String>()
        let names = model.extensionStatus.launchHosts.map(\.name).filter { seen.insert($0).inserted }
        if !names.isEmpty { return names.joined(separator: " · ") }
        return model.scanning ? "Detecting terminals, editors and SSH…" : "No terminal, editor or SSH launcher detected. Rescan after installing one."
    }

    private func scopeSection(_ title: String, hint: String, text: Binding<String>, label: String,
                              dropped: @escaping ([URL]) -> [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .padding(4).frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .disabled(locked || saving)
                .dropDestination(for: URL.self) { urls, _ in
                    guard !locked, !saving else { return false }
                    var current = text.wrappedValue.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    for value in dropped(urls.filter(\.isFileURL)) where !current.contains(value) { current.append(value) }
                    text.wrappedValue = current.joined(separator: "\n")
                    return true
                }
                .accessibilityLabel(label)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AppProxyTargetPicker: View {
    let title: String
    let selection: String
    let nodes: [String]
    let groups: [String]
    var select: (String) -> Void
    @State private var presented = false
    @State private var search = ""
    @FocusState private var searching: Bool

    var body: some View {
        Button {
            search = ""; presented = true
        } label: {
            HStack {
                Text(selection.isEmpty ? "Choose a node…" : selection).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }.contentShape(Rectangle())
        }
        .accessibilityLabel("\(title) proxy")
        .accessibilityValue(selection)
        .help(selection.isEmpty ? "Choose a proxy node or group" : selection)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Proxy for \(title)").font(.headline)
                TextField("Search nodes and groups", text: $search)
                    .textFieldStyle(.roundedBorder).focused($searching)
                    .onSubmit {
                        let matches = (groups + nodes).filter(matches)
                        if matches.count == 1, let target = matches.first { choose(target) }
                    }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !selection.isEmpty, !(groups + nodes).contains(selection) {
                            Label("Unavailable: \(selection)", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).padding(6)
                        }
                        targets("Groups", values: groups)
                        targets("Nodes", values: nodes)
                        if !(groups + nodes).contains(where: matches) {
                            Text("No matching targets").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }.frame(maxHeight: 300)
            }
            .padding(14).frame(width: 340)
            .onAppear { searching = true }
        }
    }

    private func matches(_ target: String) -> Bool {
        search.isEmpty || target.localizedCaseInsensitiveContains(search)
    }

    private func choose(_ target: String) { select(target); presented = false }

    @ViewBuilder private func targets(_ heading: String, values: [String]) -> some View {
        let filtered = values.filter(matches)
        if !filtered.isEmpty {
            Text(heading).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(filtered, id: \.self) { target in
                Button { choose(target) } label: {
                    HStack {
                        Text(target).lineLimit(2)
                        Spacer()
                        if target == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(target == selection ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
