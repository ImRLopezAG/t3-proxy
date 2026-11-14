import SwiftUI
import T3ProxyCore

/// Plugin code is downloaded and loaded by the hub. This page only uses its management API.
struct PluginsPane: View {
    @ObservedObject var monitor: Monitor
    @State private var installed: PluginList?
    @State private var store: PluginStore?
    @State private var browse = false
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pending: PluginAction?
    @State private var pendingEpoch = 0
    @State private var configuring: HubPlugin?

    private var locked: Bool { !monitor.hasKey || monitor.management == .rejected }
    private var connection: String { "\(monitor.endpoint.port):\(monitor.keyEpoch):\(locked)" }
    private var enabled: Bool? { browse ? store?.enabled : installed?.enabled }
    private func matches(_ values: String...) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if locked {
                LockedView(monitor: monitor, what: "plugins")
            } else {
                HStack {
                    Picker("Show plugins", selection: $browse) {
                        Text("Installed").tag(false)
                        Text("Browse").tag(true)
                    }.pickerStyle(.segmented).frame(width: 230)
                    Spacer()
                    TextField("Search plugins", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .accessibilityLabel("Search plugins")
                }.padding()
                Form {
                    Section {
                        Button("Manage Client Connectors…") { SettingsRouter.shared.pane = .connectors }
                    } footer: { Text("This page manages hub plugins. ChatGPT/Claude connectors and local MCP servers belong to each client profile.") }
                    if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                    if let notice {
                        Section {
                            HStack(alignment: .top) {
                                Text(notice).textSelection(.enabled)
                                Spacer()
                                Button("Dismiss", systemImage: "xmark") { self.notice = nil }.labelStyle(.iconOnly)
                            }
                        }
                    }
                    if enabled == false {
                        Section {
                            LabeledContent("Plugins are turned off in the hub") {
                                Button("Enable Plugins…") { confirm(.enableAll) }.disabled(busy)
                            }
                        } footer: { Text("Installed plugins stay inactive until the hub’s global Plugins setting is enabled.") }
                    }
                    if browse { browseSection } else { installedSection }
                }.formStyle(.grouped)
            }
        }
        .navigationTitle("Plugins")
        .toolbar {
            ToolbarItemGroup {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Loading plugins") }
                Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(busy || locked)
            }
        }
        .task(id: connection) {
            installed = nil; store = nil; error = nil; notice = nil; pending = nil; configuring = nil
            await load()
        }
        .onChange(of: browse) { _, new in
            if new && store == nil { Task { await load() } }
        }
        .confirmationDialog(pending?.title ?? "Change plugin?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let action = pending {
                    Button(action.button, role: action.destructive ? .destructive : nil) {
                        let epoch = pendingEpoch
                        pending = nil
                        Task { await perform(action, epoch: epoch) }
                    }
                    Button("Cancel", role: .cancel) { pending = nil }
                }
            } message: { Text(pending?.message ?? "") }
        .sheet(item: $configuring) { plugin in
            PluginConfigurationSheet(plugin: plugin, monitor: monitor) { notice = "Configuration saved for \(plugin.name)." }
        }
    }

    private var installedSection: some View {
        Section {
            if let installed {
                let rows = installed.plugins.filter { matches($0.name, $0.id, $0.author) }
                if rows.isEmpty { Text(search.isEmpty ? "No plugins installed. Open Browse to find plugins from the hub’s store." : "No matching plugins.").foregroundStyle(.secondary) }
                ForEach(rows) { plugin in
                    HStack(spacing: 14) {
                        Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.name).font(.headline)
                            Text([plugin.id, plugin.version, plugin.author].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Label(plugin.status, systemImage: plugin.active ? "checkmark.circle.fill" : "circle")
                                .font(.caption).foregroundStyle(plugin.active ? .green : .secondary)
                        }
                        Spacer(minLength: 10)
                        Button("Configure…") { configuring = plugin }
                        Menu {
                            Button(plugin.enabled ? "Disable…" : "Enable…") { confirm(.toggle(plugin)) }
                            Button("Uninstall…", role: .destructive) { confirm(.remove(plugin)) }
                        } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Actions for \(plugin.name)") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 5).disabled(busy)
                }
            } else if busy { Text("Loading installed plugins…").foregroundStyle(.secondary) }
        } header: { Text("Installed Plugins") } footer: {
            Text("Changes apply to the hub and all its clients. T3 Proxy never restarts the hub automatically.")
        }
    }

    private var browseSection: some View {
        Section {
            if let store {
                if store.failedSources > 0 {
                    Label("\(store.failedSources) store source(s) could not be loaded. Results may be incomplete.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                let rows = store.plugins.filter { matches($0.name, $0.pluginID, $0.description, $0.sourceName) }
                if rows.isEmpty { Text(search.isEmpty ? "The hub’s store returned no plugins." : "No matching plugins.").foregroundStyle(.secondary) }
                ForEach(rows) { plugin in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plugin.name).font(.headline)
                            Text("\(plugin.versionLabel) · \(plugin.sourceName) (\(plugin.sourceID))").font(.caption).foregroundStyle(.secondary)
                            if !plugin.sourceHost.isEmpty { Text(plugin.sourceHost).font(.caption).foregroundStyle(.secondary) }
                            if !plugin.author.isEmpty { Text("By \(plugin.author)").font(.caption).foregroundStyle(.secondary) }
                            if !plugin.description.isEmpty { Text(plugin.description).font(.callout).fixedSize(horizontal: false, vertical: true) }
                            if plugin.installed { Text("Installed: \(plugin.installedVersion.isEmpty ? "Version unknown" : plugin.installedVersion)").font(.caption).foregroundStyle(.secondary) }
                            if let issue = plugin.installIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer(minLength: 10)
                        Button(plugin.installed ? (plugin.updateAvailable ? "Update…" : "Installed") : "Install…") { confirm(.install(plugin)) }
                            .disabled(busy || !plugin.canInstall)
                    }.padding(.vertical, 7)
                }
            } else if busy { Text("Loading the hub’s plugin store…").foregroundStyle(.secondary) }
        } header: { Text("Plugin Store") } footer: {
            Text("The hub fetches this catalog and downloads plugins. Installing a plugin loads third-party code into the hub; review its author and source first.")
        }
    }

    private func confirm(_ action: PluginAction) { pendingEpoch = monitor.keyEpoch; pending = action }

    @MainActor private func load() async {
        guard !busy, !locked else { return }
        busy = true; error = nil
        let token = connection
        let loadingBrowse = browse
        defer {
            busy = false
            if token != connection || loadingBrowse != browse { Task { await load() } }
        }
        do {
            if browse {
                let result = try await monitor.management { try await $0.pluginStore(key: $1) }
                guard token == connection else { return }; store = result
            } else {
                let result = try await monitor.management { try await $0.plugins(key: $1) }
                guard token == connection else { return }; installed = result
            }
        } catch {
            guard token == connection else { return }; self.error = PluginError.message(error)
        }
    }

    @MainActor private func perform(_ action: PluginAction, epoch: Int) async {
        guard !busy, !locked, epoch == monitor.keyEpoch else { return }
        busy = true; error = nil; notice = nil
        let token = connection
        do {
            let result: PluginActionResult?
            switch action {
            case .install(let plugin): result = try await monitor.management { try await $0.installPlugin(plugin, key: $1) }
            case .remove(let plugin): result = try await monitor.management { try await $0.removePlugin(plugin, key: $1) }
            case .toggle(let plugin):
                try await monitor.management { try await $0.setPluginEnabled(plugin, enabled: !plugin.enabled, key: $1) }; result = nil
            case .enableAll:
                try await monitor.management { client, key in
                    let summary = try await client.configSummary(key: key)
                    try await client.applySettings([.plugins: .bool(true)], revision: summary.revision, key: key)
                }; result = nil
            }
            if token == connection {
                notice = result?.restartRequired == true ? "Action completed. Restart required; restart the hub when convenient."
                    : "\(action.success) Reloaded status may take a moment to reflect the change."
                installed = nil; store = nil
            }
        } catch {
            if token == connection { self.error = PluginError.message(error) }
        }
        busy = false
        // Refresh reads only. A timed-out or rejected mutation is never retried automatically.
        if token == connection {
            let savedError = error
            await load()
            if let savedError { error = savedError }
        } else {
            await load()
        }
    }
}

private enum PluginAction {
    case install(StorePlugin), toggle(HubPlugin), remove(HubPlugin), enableAll
    var destructive: Bool { if case .remove = self { true } else { false } }
    var button: String {
        switch self {
        case .install(let p): p.installed ? "Update" : "Install"
        case .toggle(let p): p.enabled ? "Disable" : "Enable"
        case .remove: "Uninstall"
        case .enableAll: "Enable Plugins"
        }
    }
    var title: String {
        switch self {
        case .install(let p): "\(button) \(p.name)?"
        case .toggle(let p), .remove(let p): "\(button) \(p.name)?"
        case .enableAll: "Enable plugins for the hub?"
        }
    }
    var message: String {
        switch self {
        case .install(let p): "\(p.versionLabel) from \(p.sourceName) (\(p.sourceID))\(p.sourceHost.isEmpty ? "" : " at " + p.sourceHost), by \(p.author.isEmpty ? "an unspecified author" : p.author). This downloads and loads third-party code into CLIProxyAPI. It affects every client using the hub."
        case .remove: "Remove this plugin’s file and saved configuration from the hub. This affects every client and cannot be undone here."
        case .toggle: "Change this plugin’s enabled setting for every client using the hub."
        case .enableAll: "Turn on the hub’s plugin system. Plugins already configured as enabled may begin running for every client."
        }
    }
    var success: String {
        switch self {
        case .install: "Plugin installed."
        case .remove: "Plugin uninstalled."
        case .toggle: "Plugin setting saved."
        case .enableAll: "Plugins enabled."
        }
    }
}

private struct PluginConfigurationSheet: View {
    let plugin: HubPlugin
    @ObservedObject var monitor: Monitor
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var config: PluginConfiguration?
    @State private var draft: [String: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var confirming = false
    @State private var epoch = 0

    private var changes: [String: PluginValue] {
        guard let config else { return [:] }
        return draft.reduce(into: [:]) { out, pair in
            if let field = config.fields.first(where: { $0.id == pair.key }),
               let value = field.parse(pair.value), field.secret || field.value != value { out[pair.key] = value }
        }
    }
    private var invalid: Bool {
        guard let config else { return true }
        return draft.contains { name, text in config.fields.first(where: { $0.id == name })?.parse(text) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plugin.name).font(.title2.bold()).padding()
            Form {
                if let error { Text(error).foregroundStyle(.orange) }
                if let config {
                    if config.fields.isEmpty { Text("This plugin does not declare configuration fields.").foregroundStyle(.secondary) }
                    ForEach(config.fields) { field in
                        Section {
                            if !field.editable {
                                LabeledContent(field.id, value: "Configure \(field.type) values in the hub’s config file")
                            } else if field.secret {
                                SecureField(field.id, text: binding(field), prompt: Text(field.isSet ? "Stored — leave unchanged to keep" : "Not set"))
                            } else if !field.choices.isEmpty {
                                Picker(field.id, selection: binding(field)) {
                                    if !field.choices.contains(binding(field).wrappedValue) { Text("Choose…").tag(binding(field).wrappedValue) }
                                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                                }
                            } else if ["boolean", "bool"].contains(field.type) {
                                Toggle(field.id, isOn: Binding(get: { binding(field).wrappedValue == "true" },
                                                             set: { draft[field.id] = $0 ? "true" : "false" }))
                            } else {
                                TextField(field.id, text: binding(field))
                            }
                            if draft[field.id] != nil {
                                Button("Leave unchanged") { draft[field.id] = nil }.font(.caption)
                            }
                        } footer: { if !field.description.isEmpty { Text(field.description) } }
                    }
                } else if busy { ProgressView("Loading configuration…") }
            }.formStyle(.grouped).disabled(busy)
            HStack {
                Text("Only changed fields are saved. Stored secrets stay hidden.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save…") { confirming = true }.keyboardShortcut(.defaultAction)
                    .disabled(busy || invalid || changes.isEmpty || epoch != monitor.keyEpoch)
            }.padding()
        }.frame(width: 620, height: 520)
        .interactiveDismissDisabled(busy)
        .task {
            epoch = monitor.keyEpoch; busy = true
            defer { busy = false }
            do {
                let result = try await monitor.management { try await $0.pluginConfiguration(id: plugin.id, key: $1) }
                guard epoch == monitor.keyEpoch else { dismiss(); return }; config = result
            } catch { self.error = PluginError.message(error) }
        }
        .confirmationDialog("Save plugin configuration?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Save") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Change \(changes.keys.sorted().joined(separator: ", ")) for every client using the hub.") }
    }

    private func binding(_ field: PluginField) -> Binding<String> {
        Binding(get: { draft[field.id] ?? field.value?.text ?? "" }, set: { draft[field.id] = $0 })
    }

    @MainActor private func save() async {
        guard let config, !busy, !invalid, epoch == monitor.keyEpoch else { return }
        let patch = changes
        busy = true; error = nil
        defer { busy = false }
        do {
            try await monitor.management { try await $0.savePluginConfiguration(config, changes: patch, key: $1) }
            draft = [:]
            guard epoch == monitor.keyEpoch else { dismiss(); return }
            onSaved(); dismiss()
        } catch { self.error = PluginError.message(error) }
    }
}
