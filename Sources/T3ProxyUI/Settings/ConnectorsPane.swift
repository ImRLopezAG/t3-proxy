import SwiftUI
import AppKit
import T3ProxyCore

/// Client-owned tools are independent of the hub's plugin store and rotating subscriptions.
struct ClientConnectorDiagnostics: View {
    @State private var profiles: [ConnectorProfile] = []
    @State private var selected = "codex_proxy"
    @State private var snapshot: ConnectorSnapshot?
    @State private var source: [String]?
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?

    public init() {}
    private var profile: ConnectorProfile? { profiles.first { $0.id == selected } }

    public var body: some View {
        Form {
            Section {
                Picker("Client profile", selection: $selected) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }.disabled(busy)
                if let profile {
                    LabeledContent("Profile home") { Text(profile.home).font(.caption).textSelection(.enabled) }
                    Text("Checks apply to this profile's home configuration. Workspace overrides and existing T3 threads may have a different tool catalog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Tools") { check() }.disabled(profile == nil || busy)
                    if profile?.original == false {
                        Button("Compare Original") { compare() }.disabled(snapshot == nil || busy)
                    }
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { operation?.cancel() }
                    }
                }
            } header: { Text("Client tools") } footer: {
                Text("This starts a temporary client for inspection. Configured MCP servers may start and contact their services. It makes no model or mail requests and leaves the hub running.")
            }
            if let message { Section { Text(message).foregroundStyle(.orange).textSelection(.enabled) } }
            if let snapshot {
                identitySection(snapshot)
                if !snapshot.apps.isEmpty {
                    Section {
                        ForEach(snapshot.apps) { app in
                            LabeledContent(app.name) {
                                Text(app.callable ? "Callable in client runtime" : app.inCatalog ? "Catalog only · access unverified" : "No callable tools")
                                    .font(.caption).foregroundStyle(app.callable ? .green : .secondary)
                            }
                        }
                    } header: { Text("Web account connectors") } footer: {
                        Text("A catalog entry is not tool access. Even a callable runtime entry does not prove Gmail search, mail reading or attachment retrieval.")
                    }
                }
                Section {
                    if snapshot.servers.isEmpty { Text("No tool catalog verified.").foregroundStyle(.secondary) }
                    ForEach(snapshot.servers) { server in
                        DisclosureGroup {
                            ForEach(server.tools, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            if server.tools.isEmpty { Text("No tools discovered.").font(.caption).foregroundStyle(.secondary) }
                        } label: {
                            HStack {
                                Text(server.name)
                                Spacer()
                                Text(server.discoveryFailed ? "Discovery failed" : "\(server.tools.count) tools · \(auth(server.auth))")
                                    .font(.caption).foregroundStyle(server.discoveryFailed ? .orange : .secondary)
                            }
                        }
                    }
                    ForEach(snapshot.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Discovered MCP tools") }
                Section {
                    Text(snapshot.registered.isEmpty ? "No profile-level MCP servers registered." : snapshot.registered.joined(separator: ", "))
                        .font(.caption).textSelection(.enabled)
                    if let source {
                        let missing = source.filter { !snapshot.registered.contains($0) }
                        Text(missing.isEmpty ? "No server names missing relative to the original profile." : "Missing from this profile: " + missing.joined(separator: ", "))
                            .font(.caption).foregroundStyle(missing.isEmpty ? Color.secondary : .orange)
                        Text("Names only were compared. Server settings, OAuth grants, plugin-provided servers and project configuration may differ. No configuration or credentials were copied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Show Client Configuration") { reveal(snapshot.profile) }
                } header: { Text("Local MCP registrations") } footer: {
                    Text("Standalone MCP servers use their own endpoint and authentication. Register them in the selected client profile using its supported MCP setup. Hub plugins do not synchronize these files or supply web-account permissions.")
                }
            }
            Section {
                Link("Codex MCP setup", destination: URL(string: "https://developers.openai.com/codex/mcp/")!)
                Link("Claude connector support", destination: URL(string: "https://code.claude.com/docs/en/mcp#use-mcp-servers-from-claudeai")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connectors")
        .task { loadProfiles() }
        .onChange(of: selected) { _, _ in snapshot = nil; source = nil; message = nil }
        .onDisappear { operation?.cancel() }

    }

    @ViewBuilder private func identitySection(_ value: ConnectorSnapshot) -> some View {
        Section {
            LabeledContent("Inference configuration", value: value.inferenceAtHub ? "Points to local hub" : "Outside local hub / unknown")
            Text("Configuration check only; no inference request was sent.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Web connectors", value: value.webStatus.rawValue)
            if let identity = value.identity {
                LabeledContent("Tool account", value: identity.email ?? "ChatGPT account")
                LabeledContent("Workspace", value: identity.workspace ?? "Name not supplied by client")
                if let id = identity.accountID { Text("Workspace ID: " + id).font(.caption).textSelection(.enabled) }
            }

        } header: { Text("Tool identity") } footer: {
            Text("These are client diagnostics. Shared T3 connections use their own service authorization and do not depend on these web accounts.")
        }
    }

    private func auth(_ value: String) -> String {
        switch value {
        case "notLoggedIn": "sign-in required"
        case "oAuth": "OAuth"
        case "bearerToken": "bearer authentication"
        case "unsupported": "no OAuth status"
        default: "authentication unknown"
        }
    }

    private func loadProfiles() {
        do {
            profiles = try ClientConnectors.profiles(settings: try? Data(contentsOf: URL(fileURLWithPath: T3CodePaths().settings)))
            if profile == nil { selected = profiles.first?.id ?? "" }
        } catch { message = "Client profiles could not be read." }
    }

    private func check() {
        guard let profile, !busy else { return }
        busy = true; message = nil; snapshot = nil; source = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do { snapshot = try await ClientConnectors.inspect(profile) }
            catch is CancellationError { message = "Check cancelled. Access remains unverified." }
            catch { message = (error as? ConnectorError)?.localizedDescription ?? "Client configuration could not be checked." }
        }
    }

    private func compare() {
        guard let profile, let original = profiles.first(where: { $0.kind == profile.kind && $0.original }), !busy else { return }
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do { source = try await ClientConnectors.registrations(original) }
            catch { message = "The original profile could not be checked. No comparison was made." }
        }
    }

    private func reveal(_ profile: ConnectorProfile) {
        let path = profile.kind == .codex ? profile.home + "/config.toml" : profile.original
            ? (profile.home as NSString).deletingLastPathComponent + "/.claude.json" : profile.home + "/.claude.json"
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
