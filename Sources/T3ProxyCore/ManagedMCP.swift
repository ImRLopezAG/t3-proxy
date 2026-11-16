import Foundation

public struct ManagedMCPStatus: Sendable {
    public let tools: [String]
    public let auth: String
    public let discoveryVerified: Bool
}

/// Uses the installed Codex MCP client as a transport/auth engine, without ever starting a model turn.
/// Each connection gets a private home and unique MCP server name, including when URLs are identical.
public enum ManagedMCP {
    public static func executable() throws -> String {
        for path in [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw ConnectorError.unavailable
    }
    public static func inspect(_ connection: ServiceConnection, store: ServiceConnectionStore = .init()) async throws -> ManagedMCPStatus {
        let worker = Task.detached {
            let client = try ManagedMCPClient(connection: connection, store: store)
            defer { client.close() }
            let status = try client.status()
            guard status["toolsError"] == nil || status["toolsError"] is NSNull else { throw ServiceConnectionError.network }
            let auth = status["authStatus"] as? String ?? "unknown"
            guard auth != "notLoggedIn" else { throw ServiceConnectionError.authentication }
            return ManagedMCPStatus(tools: ((status["tools"] as? [String: Any]) ?? [:]).keys.sorted(), auth: auth, discoveryVerified: true)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public static func signIn(_ connection: ServiceConnection, store: ServiceConnectionStore = .init(), open: @escaping @Sendable (URL) -> Void) async throws {
        guard connection.provider == .remoteMCP, connection.authentication == .oauth else { throw ServiceConnectionError.unsupported }
        let worker = Task.detached {
            let client = try ManagedMCPClient(connection: connection, store: store)
            defer { client.close() }
            let result = try client.process.request("mcpServer/oauth/login", params: ["name": connection.serverName, "timeoutSecs": 180])
            guard let text = result["authorizationUrl"] as? String, let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ServiceConnectionError.unsupported }
            open(url)
            try client.process.waitForMCPLogin(server: connection.serverName, loginID: result["loginId"] as? String)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

final class ManagedMCPClient {
    let process: CodexConnectorProcess
    let connection: ServiceConnection
    let threadID: String
    init(connection: ServiceConnection, store: ServiceConnectionStore, executable: String? = nil) throws {
        self.connection = connection
        guard connection.enabled else { throw ServiceConnectionError.invalidArguments }
        let home = store.directory.appendingPathComponent(connection.id.uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func quote(_ text: String) throws -> String { try ConnectorFiles.tomlString(text) }
        var config = """
        model_provider = "t3_mcp_only"
        mcp_oauth_credentials_store = "keyring"
        [features]
        apps = false
        [model_providers.t3_mcp_only]
        name = "MCP transport only"
        base_url = "http://127.0.0.1:1/v1"
        wire_api = "responses"
        requires_openai_auth = false

        [mcp_servers.\(connection.serverName)]
        tool_timeout_sec = 600

        """
        let sourceEnv = ProcessInfo.processInfo.environment
        var env = sourceEnv.filter { ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR"].contains($0.key) }
        if connection.provider == .remoteMCP {
            guard let endpoint = connection.endpoint, ServiceConnection.validEndpoint(endpoint) else { throw ServiceConnectionError.unsupported }
            config += "url = \(try quote(endpoint))\n"
            if connection.authentication == .bearer {
                guard let token = try ConnectorCredentialStore(account: connection.id.uuidString).load()?.accessToken, !token.isEmpty else { throw ServiceConnectionError.authentication }
                config += "bearer_token_env_var = \"T3_MCP_BEARER\"\n"; env["T3_MCP_BEARER"] = token
            }
        } else {
            guard let command = connection.command, command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command), connection.authentication != .oauth else { throw ServiceConnectionError.invalidArguments }
            config += "command = \(try quote(command))\nargs = [\(try connection.arguments.map(quote).joined(separator: ", "))]\n"
            if !connection.environmentNames.isEmpty {
                let credentials = try ConnectorCredentialStore(account: connection.id.uuidString).load()?.environment ?? [:]
                for name in connection.environmentNames {
                    guard name.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil, let value = credentials[name] else { throw ServiceConnectionError.authentication }
                    env[name] = value
                }
                config += "env_vars = [\(try connection.environmentNames.map(quote).joined(separator: ", "))]\n"
            }
        }
        let configURL = home.appendingPathComponent("config.toml")
        let data = Data(config.utf8)
        if (try? Data(contentsOf: configURL)) != data { try ConnectorFiles.write(data, to: configURL) }
        let client = try CodexConnectorProcess(profile: .init(id: connection.id.uuidString, name: connection.name, kind: .codex, home: home.path, executable: try executable ?? ManagedMCP.executable(), original: false), environment: env)
        do {
            let result = try client.request("thread/start", params: ["ephemeral": true, "cwd": home.path, "approvalPolicy": "never", "sandbox": "read-only"])
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw ConnectorError.invalidResponse }
            threadID = id; process = client
        } catch { client.close(); throw error }
    }
    func status(cancelled: () -> Bool = { false }) throws -> [String: Any] {
        var cursor: String?, seen: Set<String> = []
        repeat {
            var params: [String: Any] = ["threadId": threadID, "serverName": connection.serverName]
            if let cursor { params["cursor"] = cursor }
            let result = try process.request("mcpServerStatus/list", params: params, timeout: 35, cancelled: cancelled)
            guard let values = result["data"] as? [[String: Any]] else { throw ConnectorError.invalidResponse }
            if let value = values.first(where: { $0["name"] as? String == connection.serverName }) {
                let state = value["runtimeStatus"] as? String
                if state == "authenticationRequired" || value["authStatus"] as? String == "notLoggedIn" { throw ServiceConnectionError.authentication }
                guard state == "connected" else { throw ServiceConnectionError.network }
                return value
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw ConnectorError.invalidResponse }
        } while cursor != nil
        throw ServiceConnectionError.network
    }
    func close() { process.close() }
    deinit { close() }
}

/// Internal per-connection relay. Both clients see the existing server's tools, with the same account binding.
/// The manager has no aggregate tool catalog and creates no service-specific tools.
public final class ManagedMCPRelay {
    private let client: ManagedMCPClient
    private let store: ServiceConnectionStore
    private let connection: ServiceConnection
    public init(id: UUID, store: ServiceConnectionStore = .init(), executable: String? = nil) throws {
        guard let connection = try store.load().first(where: { $0.id == id && $0.enabled }) else { throw ServiceConnectionError.invalidArguments }
        self.connection = connection; self.store = store
        client = try ManagedMCPClient(connection: connection, store: store, executable: executable)
    }
    public func respond(_ data: Data) -> [String: Any]? { respond(data, cancelled: { false }) }
    func respond(_ data: Data, cancelled: () -> Bool) -> [String: Any]? {
        func failure(_ id: Any, _ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return failure(NSNull(), -32700, "Invalid JSON.") }
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return failure(id, -32600, "Invalid request.") }
        if request["id"] == nil { return nil }
        do {
            if cancelled() { throw CancellationError() }
            guard try store.load().contains(connection) else { throw ServiceConnectionError.authentication }
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                let status = try client.status(cancelled: cancelled)
                var capabilities: [String: Any] = [:]
                if let source = status["serverCapabilities"] as? [String: Any] {
                    if source["tools"] is [String: Any] { capabilities["tools"] = ["listChanged": false] }
                    if source["resources"] is [String: Any] { capabilities["resources"] = ["listChanged": false, "subscribe": false] }
                } else { capabilities["tools"] = ["listChanged": false] }
                let requested = params["protocolVersion"] as? String ?? "2025-03-26"
                result = ["protocolVersion": ["2025-03-26", "2025-06-18", "2025-11-25"].contains(requested) ? requested : "2025-03-26", "capabilities": capabilities,
                          "serverInfo": MCPWire.optionalFields(status["serverInfo"] as? [String: Any] ?? ["name": connection.name, "version": "1.0"], ["title", "icons", "websiteUrl", "description"]),
                          "instructions": "Connection: \(connection.name), account/workspace: \(connection.identity ?? "not specified"). This connection never rotates with model subscriptions."]
            case "ping": result = [:]
            case "tools/list":
                let status = try client.status(cancelled: cancelled)
                if let error = status["toolsError"], !(error is NSNull) { throw ServiceConnectionError.network }
                guard let tools = status["tools"] as? [String: [String: Any]] else { throw ServiceConnectionError.network }
                result = ["tools": tools.sorted { $0.key < $1.key }.map { MCPWire.definition($0.value) }]
            case "tools/call":
                guard let name = params["name"] as? String else { return failure(id, -32602, "Tool name required.") }
                var args: [String: Any] = ["threadId": client.threadID, "server": connection.serverName, "tool": name, "arguments": params["arguments"] as? [String: Any] ?? [:]]
                if let meta = params["_meta"] { args["_meta"] = meta }
                result = MCPWire.toolResult(try client.process.request("mcpServer/tool/call", params: args, timeout: CodexConnectorProcess.timeout(for: "mcpServer/tool/call"), cancelled: cancelled))
            case "resources/list": result = ["resources": (try client.status(cancelled: cancelled)["resources"] as? [[String: Any]] ?? []).map(MCPWire.definition)]
            case "resources/templates/list": result = ["resourceTemplates": (try client.status(cancelled: cancelled)["resourceTemplates"] as? [[String: Any]] ?? []).map(MCPWire.definition)]
            case "resources/read":
                guard let uri = params["uri"] as? String else { return failure(id, -32602, "Resource URI required.") }
                var response = try client.process.request("mcpServer/resource/read", params: ["threadId": client.threadID, "server": connection.serverName, "uri": uri], timeout: 35, cancelled: cancelled)
                if let contents = response["contents"] as? [[String: Any]] { response["contents"] = contents.map(MCPWire.definition) }
                result = response
            default: return failure(id, -32601, "This MCP capability is not supported by the shared connection relay.")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch {
            if error is CancellationError { return failure(id, -32800, "Request cancelled. The remote operation may have completed; check its outcome before retrying.") }
            let message = (error as? ServiceConnectionError)?.localizedDescription ?? (error as? ConnectorError)?.localizedDescription ?? "The MCP connection failed. Check authorization and server availability in T3 Proxy."
            if request["method"] as? String == "tools/call" { return ["jsonrpc": "2.0", "id": id, "result": ["isError": true, "content": [["type": "text", "text": message]]]] }
            return failure(id, -32603, message)
        }
    }
    public func close() { client.close() }
    deinit { close() }
}

/// App-server emits null for typed optional MCP fields. Omit only protocol optionals;
/// never walk arbitrary inputSchema, outputSchema, structuredContent or _meta payloads.
enum MCPWire {
    static func optionalFields(_ value: [String: Any], _ fields: [String]) -> [String: Any] {
        var value = value
        for key in fields where value[key] is NSNull { value.removeValue(forKey: key) }
        return value
    }
    static func definition(_ value: [String: Any]) -> [String: Any] {
        var value = optionalFields(value, ["title", "description", "annotations", "icons", "outputSchema", "mimeType", "size", "_meta"])
        if let annotations = value["annotations"] as? [String: Any] {
            value["annotations"] = optionalFields(annotations, ["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint", "audience", "priority", "lastModified"])
        }
        return value
    }
    static func toolResult(_ result: [String: Any]) -> [String: Any] {
        var result = optionalFields(result, ["isError", "structuredContent", "_meta"])
        if let content = result["content"] as? [[String: Any]] {
            result["content"] = content.map { item in
                var item = definition(item)
                if let resource = item["resource"] as? [String: Any] { item["resource"] = definition(resource) }
                return item
            }
        }
        return result
    }
}

/// Input keeps flowing while the serial worker owns the transport. Only cancellation flags
/// cross queues; the app-server process and its buffers stay confined to the worker.
public final class ManagedMCPSession: @unchecked Sendable {
    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.withLock { stopped = true } }
        var cancelled: Bool { lock.withLock { stopped } }
    }
    private let relay: ManagedMCPRelay
    private let queue = DispatchQueue(label: "t3.mcp.connection")
    private let lock = NSLock()
    private var pending: [Data: Operation] = [:]
    private var finished = false
    public init(_ relay: ManagedMCPRelay) { self.relay = relay }
    public func submit(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        func key(_ id: Any?) -> Data? { id.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) } }
        if request?["method"] as? String == "notifications/cancelled", request?["id"] == nil {
            if let id = key((request?["params"] as? [String: Any])?["requestId"]) { lock.withLock { pending[id]?.cancel() } }
            return
        }
        let id = key(request?["id"]), operation = Operation()
        let accepted = lock.withLock {
            guard !finished, id == nil || pending[id!] == nil else { return false }
            if let id { pending[id] = operation }
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            defer { if let id { _ = lock.withLock { pending.removeValue(forKey: id) } } }
            if let value = relay.respond(data, cancelled: { operation.cancelled }),
               let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) { reply(encoded) }
        }
    }
    public func finish() {
        lock.withLock { finished = true; for operation in pending.values { operation.cancel() } }
        queue.sync { relay.close() }
    }
}
