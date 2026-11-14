import SwiftUI
import AppKit
import T3ProxyCore

public struct ConnectorsPane: View {
    @State private var connections: [ServiceConnection] = []
    @State private var message: String?
    @State private var statuses: [UUID: String] = [:]
    @State private var busy = false
    @State private var committing = false
    @State private var operation: Task<Void, Never>?
    @State private var adding = false
    @State private var diagnostics = false
    @State private var removing: ServiceConnection?
    @State private var hubKey = ""
    public init() {}
    public var body: some View {
        Form {
            Section {
                Text("Connect once. Use in both clients.").font(.headline)
                Text("Manage existing MCP servers and share each authenticated account with Codex Proxy and Claude Proxy.").foregroundStyle(.secondary)
                Button("Set Up T3 Proxy") { setup() }.buttonStyle(.borderedProminent).disabled(busy)
                DisclosureGroup("New profiles: hub inference key") {
                    SecureField("Hub API key", text: $hubKey)
                    Button("Save Inference Key") { saveHubKey() }.disabled(hubKey.isEmpty || busy)
                    Text("New client launchers use this Keychain item. Existing launchers keep their authentication. This is separate from the management key and MCP accounts.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Setup") } footer: {
                Text("Creates proxy profiles, shares skills and plugins, and registers your connections. Applies to new client sessions.")
            }
            if let message { Section { Text(message).textSelection(.enabled) } }
            Section {
                if connections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No connections yet").fontWeight(.medium)
                        Text("Add an existing MCP server. Use a separate connection for each account or workspace.").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                ForEach(connections) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.name).fontWeight(.medium)
                                Text(c.identity ?? c.endpoint ?? c.command ?? "MCP server").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(c.targets.map { $0 == .codex ? "Codex Proxy" : "Claude Proxy" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if c.authentication == .oauth { Button("Sign In…") { signIn(c) }.disabled(busy) }
                            Button("Check") { check(c) }.disabled(busy)
                            Button { removing = c } label: { Image(systemName: "trash") }.help("Remove this connection").disabled(busy)
                        }
                        Text(statuses[c.id] ?? "Tool access not checked in this session").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                HStack {
                    Button { adding = true } label: { Label("Add MCP Connection", systemImage: "plus") }.disabled(busy)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                        if committing { Text("Applying changes…").font(.caption) }
                        Button("Cancel") { operation?.cancel() }.disabled(committing)
                    }
                }
            } header: { Text("MCP connections") } footer: {
                Text("Each connection keeps its chosen account and workspace across both clients.")
            }
            Section {
                Text("Requires installed Codex CLI and Claude Code. Sign-in and available tools depend on the MCP server.").font(.caption).foregroundStyle(.secondary)
                Button("Client Diagnostics…") { diagnostics = true }
            }
        }
        .formStyle(.grouped).navigationTitle("Connectors")
        .task { reload() }.onDisappear { operation?.cancel() }
        .sheet(isPresented: $adding) { AddMCPConnection { reload(); setup() } }
        .sheet(isPresented: $diagnostics) {
            VStack { ClientConnectorDiagnostics(); Button("Done") { diagnostics = false }.padding() }.frame(minWidth: 640, minHeight: 600)
        }
        .confirmationDialog("Remove \(removing?.name ?? "connection")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { c in
            Button("Remove Connection", role: .destructive) { remove(c) }
        } message: { _ in Text("Removes the connection from fresh sessions and stops existing sessions from forwarding it. Revoke OAuth consent separately in the service account.") }
    }
    private func reload() {
        do { connections = try ServiceConnectionStore().load() }
        catch { message = "Connections could not be read. Storage was preserved." }
    }
    private func setup() {
        guard !busy else { return }; busy = true; message = nil
        let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("T3Connectors").path ?? ""
        operation = Task { @MainActor in
            defer { busy = false; committing = false }
            guard FileManager.default.isExecutableFile(atPath: helper) else { message = "The connection helper is missing. Install the complete T3 Proxy app bundle."; return }
            guard await ProxyClient().health() else { message = "The hub is unavailable on the configured port. Start CLIProxyAPI or update Connection settings first."; return }
            do {
                try Task.checkCancellation()
                let profiles = try ClientConnectors.profiles(settings: nil)
                guard let codex = profiles.first(where: { $0.kind == .codex }), let claude = profiles.first(where: { $0.kind == .claude }),
                      FileManager.default.isExecutableFile(atPath: codex.executable), FileManager.default.isExecutableFile(atPath: claude.executable) else { message = "Install Codex CLI and Claude Code before setup."; return }
                let port = HubPort.current(), connections = self.connections
                committing = true
                let result = try await mutate { try ConnectorSetup(helper: helper, codex: codex.executable, claude: claude.executable, hubPort: port, connections: connections).install() }
                try Task.checkCancellation()
                message = result.changed.isEmpty ? "Setup is current. Start fresh proxy sessions to load managed connections." : "Configured \(result.changed.count) files and links. Start fresh proxy sessions. Registration is complete; inference and MCP access still need separate checks."
            } catch is CancellationError { }
            catch { if !Task.isCancelled { message = (error as? ConnectorSetupError)?.localizedDescription ?? "Setup failed. Check profile files and private backups before retrying." } }
        }
    }
    private func saveHubKey() {
        let value = hubKey; hubKey = ""; busy = true
        operation = Task { @MainActor in
            defer { busy = false; committing = false }
            committing = true
            do { try await mutate { try ConnectorCredentialStore(account: "hub-inference").save(.init(accessToken: value)) }; try Task.checkCancellation(); message = "Inference key saved in Keychain." }
            catch { if !Task.isCancelled { message = "The inference key could not be saved." } }
        }
    }
    private func check(_ c: ServiceConnection) {
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do { let status = try await ManagedMCP.inspect(c); statuses[c.id] = "\(status.tools.count) tools discovered · tool calls not yet verified" }
            catch { statuses[c.id] = (error as? ServiceConnectionError)?.localizedDescription ?? "MCP discovery failed. Check the server and authorization." }
        }
    }
    private func signIn(_ c: ServiceConnection) {
        busy = true; message = "Complete this MCP server's consent flow in your browser. Choose the intended account and workspace."
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                try await ManagedMCP.signIn(c) { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
                let status = try await ManagedMCP.inspect(c)
                statuses[c.id] = "Signed in · \(status.tools.count) tools discovered · tool calls unverified"
                message = "MCP authorization completed for \(c.name). Both selected clients use this connection."
            } catch { message = (error as? ServiceConnectionError)?.localizedDescription ?? "MCP sign-in did not complete. This endpoint may need a pre-registered OAuth client or different authentication." }
        }
    }
    private func remove(_ c: ServiceConnection) {
        busy = true
        operation = Task { @MainActor in
            defer { committing = false }
            do {
                committing = true
                try await mutate { try ServiceConnectionStore().remove(c.id); try ConnectorCredentialStore(account: c.id.uuidString).remove() }
                try Task.checkCancellation()
                statuses[c.id] = nil; reload(); busy = false; setup()
            } catch { busy = false; if !Task.isCancelled { reload(); message = "Removal did not fully complete. Check storage and Keychain before retrying." } }
        }
    }
    private func mutate<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached { try Task.checkCancellation(); return try action() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private struct AddMCPConnection: View {
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ServiceProvider.remoteMCP
    @State private var authentication = MCPAuthentication.oauth
    @State private var name = ""
    @State private var endpoint = ""
    @State private var workspace = ""
    @State private var token = ""
    @State private var command = ""
    @State private var arguments = "[]"
    @State private var environment: [CredentialField] = []
    @State private var codex = true
    @State private var claude = true
    @State private var busy = false
    @State private var error: String?
    private struct CredentialField: Identifiable { let id = UUID(); var name = ""; var value = "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add MCP Connection").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Connection name", text: $name, prompt: Text("Work Gmail, Personal GitHub…"))
                TextField("Account / workspace / project", text: $workspace)
                Picker("Transport", selection: $provider) { Text("Remote HTTP").tag(ServiceProvider.remoteMCP); Text("Local stdio").tag(ServiceProvider.stdio) }
                if provider == .remoteMCP {
                    TextField("MCP URL", text: $endpoint, prompt: Text("The server's documented MCP endpoint"))
                    Picker("Authentication", selection: $authentication) {
                        Text("OAuth · browser sign-in").tag(MCPAuthentication.oauth); Text("Bearer token").tag(MCPAuthentication.bearer); Text("None").tag(MCPAuthentication.none)
                    }
                    if authentication == .bearer { SecureField("Bearer token", text: $token) }
                    Text("Use an existing MCP service and its consent flow. ChatGPT and Claude web connections cannot be imported automatically.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Executable path", text: $command, prompt: Text("/opt/homebrew/bin/npx"))
                    TextField("Arguments (JSON array)", text: $arguments)
                    ForEach($environment) { $field in HStack { TextField("ENV_VARIABLE", text: $field.name); SecureField("Credential", text: $field.value) } }
                    Button("Add Credential Variable") { environment.append(CredentialField()) }
                    Text("Runs the executable you specify. Keep secrets in credential variables; those values are stored in Keychain.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Toggle("Codex Proxy", isOn: $codex); Toggle("Claude Proxy", isOn: $claude) }
            }.formStyle(.grouped).disabled(busy)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.disabled(busy)
                Button("Add Connection") { add() }.buttonStyle(.borderedProminent)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || (!codex && !claude) || (provider == .remoteMCP ? !ServiceConnection.validEndpoint(endpoint) || (authentication == .bearer && token.isEmpty) : command.isEmpty))
            }
        }.padding(24).frame(width: 620, height: 570)
    }
    private func add() {
        do {
            let args = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
            var env: [String: String] = [:]
            if provider == .stdio {
                for field in environment {
                    guard field.name.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil, env[field.name] == nil else { throw ServiceConnectionError.invalidArguments }
                    env[field.name] = field.value
                }
            }
            let targets: [MCPClientTarget] = [codex ? .codex : nil, claude ? .claude : nil].compactMap { $0 }
            let connection = ServiceConnection(provider: provider, name: name, identity: workspace.isEmpty ? nil : workspace, endpoint: provider == .remoteMCP ? endpoint : nil,
                authentication: provider == .remoteMCP ? authentication : .none, command: provider == .stdio ? command : nil, arguments: provider == .stdio ? args : [], environmentNames: env.keys.sorted(), targets: targets)
            let credential = ConnectorCredential(accessToken: authentication == .bearer && provider == .remoteMCP ? token : "", environment: env)
            busy = true; error = nil
            Task { @MainActor in
                defer { busy = false }
                do {
                    try await Task.detached {
                        let credentials = ConnectorCredentialStore(account: connection.id.uuidString)
                        if !credential.accessToken.isEmpty || !credential.environment.isEmpty { try credentials.save(credential) }
                        do { try ServiceConnectionStore().save(connection) } catch { try? credentials.remove(); throw error }
                    }.value
                    token = ""; environment = []; saved(); dismiss()
                } catch { self.error = (error as? ServiceConnectionError)?.localizedDescription ?? "MCP connection could not be saved." }
            }
        } catch { self.error = "Check the executable, JSON argument array and unique credential variable names." }
    }
}
