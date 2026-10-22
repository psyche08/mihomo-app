import SwiftUI
import MihomoControl

struct AppProxyView: View {
    @ObservedObject var dashboard: DashboardStore
    @ObservedObject var model: AppProxyStore
    @State private var search = ""
    @State private var inspecting: AppProxyEntry?
    @State private var editingExecutables: AppProxyEntry?
    @State private var editingBypass = false

    private var busy: Bool { dashboard.configAction != nil || model.busy }
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
            Divider()
            actionBar
        }
        .background(DashboardTheme.background)
        .sheet(item: $inspecting) { app in executableDetails(app) }
        .sheet(item: $editingExecutables) { app in
            AppProxyExecutableEditor(model: model, application: app)
        }
        .sheet(isPresented: $editingBypass) { AppProxyBypassEditor(model: model) }
        .task { await model.refresh() }
    }

    private var bypassSummary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local networks and VPNs").font(.headline)
                if model.extensionStatus.requiresReactivation {
                    Text("Turn App Proxy off and on to activate network bypasses after this update.")
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
                Label(model.extensionStatus.connected ? "Connected" : (model.extensionStatus.enabled ? "Disconnected" : "Off"),
                      systemImage: model.extensionStatus.connected ? "circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(model.extensionStatus.connected ? Color.green : .secondary)
            }
            Text("Choose a node for each app. Signed helpers follow the same route.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityLabel("Search applications")
                Button("Add App or CLI…", systemImage: "plus") { Task { await model.addApplication() } }
                    .disabled(busy || model.refreshing || model.extensionStatus.enabled || model.routing == nil || model.draft.applications.count >= 32)
                    .help(model.extensionStatus.enabled ? "Turn off App Proxy to change the application list" : "Add a signed app or CLI executable")
                Menu {
                    Button("Restore Default Apps") { model.restoreDefaults() }
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
                Button("Refresh Nodes", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(busy || model.refreshing)
            }
        }
        .padding(20)
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
                Button("CLI executables · \(app.executablePaths.count)") { editingExecutables = app }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .disabled(busy || model.routing == nil)
                    .accessibilityLabel("Edit CLI executables for \(app.title)")
            }
            Spacer(minLength: 8)
            AppProxyTargetPicker(title: app.title, selection: model.draft.routes[app.id] ?? "",
                                 nodes: model.nodes, groups: model.groups) {
                model.selectTarget($0, for: app.id)
            }
            .frame(width: 230).disabled(busy || model.routing == nil)
            Button(role: .destructive) { model.removeApplication(app.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(busy || model.refreshing || model.extensionStatus.enabled)
                .help(model.extensionStatus.enabled ? "Turn off App Proxy to remove an entry" : "Remove routing; keep the installed application")
                .accessibilityLabel("Remove \(app.title)")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
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
                    Text(model.scanning ? "Scanning signed executables… You can keep choosing nodes." : "Apply restarts the proxy runtime and may interrupt connections.")
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
                    Button("Enable App Proxy") { Task { await dashboard.setAppProxyEnabled(true) } }
                        .disabled(busy || model.refreshing || model.hasConflict || !model.extensionStatus.available || model.routing == nil || model.dirty || !model.valid || model.draft.routes.isEmpty)
                }
            }
            if !model.extensionStatus.available {
                Text("Activation requires the signed MihomoBox system extension.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(DashboardTheme.surface)
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
                    let executables = model.extensionStatus.executables.filter { $0.applicationID == app.id }
                    if executables.isEmpty {
                        Text(model.scanning ? "Checking signatures…" : "No matching signed executables found. Install the app, then rescan.")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                    ForEach(executables) { executable in
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
                }
            }
            Text("Rescan updates this list. Enabling App Proxy always verifies signatures again.")
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
    @State private var error: String?
    @State private var saving = false

    init(model: AppProxyStore, application: AppProxyEntry) {
        self.model = model; self.application = application
        _paths = State(initialValue: application.executablePaths.joined(separator: "\n"))
    }
    private var locked: Bool { model.busy || model.refreshing || model.extensionStatus.enabled || model.hasConflict }
    private var entries: [String] { paths.components(separatedBy: .newlines).filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CLI executables").font(.title2.bold())
            Text(application.title).font(.headline)
            Text("These executables use this app’s selected node, regardless of which app launches them. Other child processes are not included automatically.")
                .foregroundStyle(.secondary)
            Text("Enter one absolute path per line. Add or remove lines to edit the list.").font(.callout)
            TextEditor(text: $paths)
                .font(.system(.body, design: .monospaced))
                .padding(6).frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .disabled(locked || saving)
                .accessibilityLabel("CLI executable paths")
            Text("For example: /usr/bin/curl. Select signed binaries; scripts require their interpreter. Each executable can belong to only one app.")
                .font(.caption).foregroundStyle(.secondary)
            if model.extensionStatus.enabled {
                Label("Turn off App Proxy before editing this list.", systemImage: "info.circle")
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
                            try await model.setExecutablePaths(entries, for: application.id)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(locked || saving || entries == application.executablePaths)
            }
            Text("Update Draft verifies signatures. Apply Changes on the App Proxy page saves the configuration; then enable App Proxy.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 640, height: 540)
        .interactiveDismissDisabled(saving || model.busy)
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
