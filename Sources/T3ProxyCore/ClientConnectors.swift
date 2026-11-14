import Foundation
import Darwin

public struct ConnectorProfile: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: T3CodeProviderKind
    public let home: String
    public let executable: String
    public let original: Bool
}

public enum ConnectorError: Error, Equatable, LocalizedError {
    case unavailable, invalidResponse, unsupported, timedOut, executionIndeterminate, unsafeLogin, loginFailed, transportChanged
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The configured client could not be started. Check its executable and profile home."
        case .invalidResponse: "The client returned an unrecognized connector response."
        case .unsupported: "This client does not support the requested connector operation."
        case .timedOut: "The client check timed out. Access has not been verified."
        case .executionIndeterminate: "The tool deadline expired and this transport was closed. The remote operation may have completed. Check its outcome before retrying."
        case .unsafeLogin: "Sign-in is available only for an isolated Codex profile with a separate hub inference key."
        case .loginFailed: "Client sign-in did not complete. No connector access has been verified."
        case .transportChanged: "The client's inference configuration changed. Recheck this profile before continuing."
        }
    }
}

public enum ConnectorWebStatus: String, Sendable {
    case signInRequired = "ChatGPT sign-in required"
    case disabled = "Apps disabled in client configuration"
    case checked = "Catalog and runtime checked"
    case failed = "Connector discovery incomplete"
    case unsupported = "Web connectors unsupported with proxy authentication"
}

public struct ConnectorIdentity: Sendable, Equatable {
    public let email: String?
    public let workspace: String?
    public let accountID: String?
}

public struct ConnectorApp: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let inCatalog: Bool
    public let callable: Bool
}

public struct ConnectorServer: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let auth: String
    public let tools: [String]
    public let discoveryFailed: Bool
}

public struct ConnectorSnapshot: Sendable {
    public let profile: ConnectorProfile
    public let identity: ConnectorIdentity?
    public let inferenceAtHub: Bool
    public let canSignIn: Bool
    public let webStatus: ConnectorWebStatus
    public let registered: [String]
    public let apps: [ConnectorApp]
    public let servers: [ConnectorServer]
    public let issues: [String]
}

private struct ConnectorInference: Equatable {
    let provider: String
    let baseURL: String?
    let envKey: String?
    let requiresOpenAIAuth: Bool
    init(_ config: [String: Any]) {
        provider = config["model_provider"] as? String ?? "openai"
        let settings = (config["model_providers"] as? [String: [String: Any]])?[provider] ?? [:]
        baseURL = settings["base_url"] as? String
        envKey = settings["env_key"] as? String
        requiresOpenAIAuth = settings["requires_openai_auth"] as? Bool ?? true
    }
    var atHub: Bool { T3CodeLocal.pointsAtHub(baseURL) }
}

// JSON values remain confined to the synchronous client worker. Only the allowlisted projection
// above crosses back to the UI. No credentials, tool descriptions, mail or raw errors are retained.
protocol ConnectorRequesting {
    func request(_ method: String, params: [String: Any]) throws -> [String: Any]
}

public enum ClientConnectors {
    public static func profiles(settings: Data?, home: String = NSHomeDirectory()) throws -> [ConnectorProfile] {
        let settings = settings.flatMap { T3CodeSettings.parse($0, home: home) }
        var profiles = (settings?.instances ?? []).compactMap { instance -> ConnectorProfile? in
            guard instance.enabled, let kind = instance.kind else { return nil }
            let base = home + (kind == .codex ? "/.codex" : "/.claude")
            let path = instance.homePath ?? base
            let configured = instance.binaryPath
            let binary = configured.flatMap { $0.contains("/") ? $0 : nil } ?? executable(kind, name: configured)
            let original = URL(fileURLWithPath: path).resolvingSymlinksInPath() == URL(fileURLWithPath: base).resolvingSymlinksInPath()
            return .init(id: instance.id, name: instance.displayName, kind: kind, home: path,
                         executable: binary, original: original)
        }
        for kind in [T3CodeProviderKind.codex, .claude] {
            let path = home + (kind == .codex ? "/.codex" : "/.claude")
            if !profiles.contains(where: { $0.kind == kind && $0.home == path }) {
                profiles.append(.init(id: "original_" + (kind == .codex ? "codex" : "claude"),
                                      name: kind == .codex ? "Codex (original)" : "Claude (original)",
                                      kind: kind, home: path, executable: executable(kind), original: true))
            }
        }
        return profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func executable(_ kind: T3CodeProviderKind, name: String? = nil) -> String {
        let name = name ?? (kind == .codex ? "codex" : "claude")
        for dir in [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/" + name
    }

    public static func inspect(_ profile: ConnectorProfile) async throws -> ConnectorSnapshot {
        let worker = Task.detached {
            if profile.kind == .claude { return try inspectClaude(profile) }
            let client = try CodexConnectorProcess(profile: profile)
            defer { client.close() }
            return try inspect(profile, using: client)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public static func registrations(_ profile: ConnectorProfile) async throws -> [String] {
        let worker = Task.detached {
            if profile.kind == .claude { return try readClaudeRegistrations(profile) }
            let client = try CodexConnectorProcess(profile: profile)
            defer { client.close() }
            return try registrations(using: client)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func registrations(using client: any ConnectorRequesting) throws -> [String] {
        guard let config = try client.request("config/read", params: ["includeLayers": false])["config"] as? [String: Any] else {
            throw ConnectorError.invalidResponse
        }
        return ((config["mcp_servers"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    /// Codex owns OAuth and credential storage. This app opens only the supported browser flow;
    /// it never imports OAuth state from a source profile or a rotating hub subscription.
    public static func signIn(_ profile: ConnectorProfile, open: @escaping @Sendable (URL) -> Void) async throws {
        let worker = Task.detached {
            guard profile.kind == .codex, !profile.original else { throw ConnectorError.unsafeLogin }
            let client = try CodexConnectorProcess(profile: profile)
            defer { client.close() }
            let before = try client.request("config/read", params: ["includeLayers": false])
            guard let config = before["config"] as? [String: Any], loginAllowed(profile, config: config) else {
                throw ConnectorError.unsafeLogin
            }
            let response = try client.request("account/login/start", params: ["type": "chatgpt"])
            guard let raw = response["authUrl"] as? String, let url = loginURL(raw),
                  let id = response["loginId"] as? String else { throw ConnectorError.loginFailed }
            open(url)
            try client.waitForLogin(id)
            let after = try client.request("config/read", params: ["includeLayers": false])
            guard let current = after["config"] as? [String: Any],
                  loginAllowed(profile, config: current), ConnectorInference(config) == ConnectorInference(current) else {
                throw ConnectorError.transportChanged
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func loginURL(_ value: String) -> URL? {
        guard let c = URLComponents(string: value), c.scheme == "https", c.host == "auth.openai.com",
              c.port == nil || c.port == 443, c.user == nil, c.password == nil,
              c.path == "/oauth/authorize" else { return nil }
        return c.url
    }

    private static func loginAllowed(_ profile: ConnectorProfile, config: [String: Any]) -> Bool {
        let inference = ConnectorInference(config)
        return !profile.original && inference.atHub && !(inference.envKey ?? "").isEmpty && !inference.requiresOpenAIAuth
    }

    static func inspect(_ profile: ConnectorProfile, using client: any ConnectorRequesting) throws -> ConnectorSnapshot {
        guard let config = try client.request("config/read", params: ["includeLayers": false])["config"] as? [String: Any] else {
            throw ConnectorError.invalidResponse
        }
        let account = try client.request("account/read", params: ["refreshToken": false])
        let info = account["account"] as? [String: Any]
        let identity = info?["type"] as? String == "chatgpt" ? ConnectorIdentity(
            email: info?["email"] as? String, workspace: info?["workspaceName"] as? String,
            accountID: (account["workspaceRouting"] as? [String: Any])?["chatgptAccountId"] as? String) : nil
        var status: ConnectorWebStatus = identity == nil ? .signInRequired : .checked
        if (config["features"] as? [String: Any])?["apps"] as? Bool == false { status = .disabled }
        var issues: [String] = [], catalog: [[String: Any]] = [], installed: [[String: Any]] = []
        if status == .checked {
            do {
                catalog = try pages(client, method: "app/list", params: ["forceRefetch": true])
                guard let apps = try client.request("app/installed", params: ["forceRefresh": true])["apps"] as? [[String: Any]] else {
                    throw ConnectorError.invalidResponse
                }
                installed = apps
            } catch is CancellationError { throw CancellationError() }
            catch { status = .failed; issues.append("Web connector catalog or runtime could not be checked. Access remains unverified.") }
        }
        var servers: [ConnectorServer] = []
        do {
            servers = try pages(client, method: "mcpServerStatus/list", params: ["detail": "toolsAndAuthOnly"]).map { value in
                guard let name = value["name"] as? String, let auth = value["authStatus"] as? String,
                      let tools = value["tools"] as? [String: Any] else { throw ConnectorError.invalidResponse }
                return .init(name: name, auth: auth, tools: tools.keys.sorted(), discoveryFailed: value["toolsError"] is String)
            }.sorted { $0.name < $1.name }
        } catch is CancellationError { throw CancellationError() }
        catch { issues.append("MCP tool discovery failed. Registered server names do not prove tool access.") }
        let ids = Set(catalog.compactMap { $0["id"] as? String } + installed.compactMap { $0["id"] as? String })
        let apps: [ConnectorApp] = ids.sorted().map { id in
            let entry = catalog.first { $0["id"] as? String == id }
            let runtime = installed.first { $0["id"] as? String == id }
            return .init(id: id, name: entry?["name"] as? String ?? runtime?["runtimeName"] as? String ?? id,
                         inCatalog: entry != nil, callable: runtime?["callable"] as? Bool == true)
        }
        return .init(profile: profile, identity: identity, inferenceAtHub: ConnectorInference(config).atHub,
                     canSignIn: loginAllowed(profile, config: config), webStatus: status,
                     registered: ((config["mcp_servers"] as? [String: Any]) ?? [:]).keys.sorted(),
                     apps: apps, servers: servers, issues: issues)
    }

    private static func pages(_ client: any ConnectorRequesting, method: String, params: [String: Any]) throws -> [[String: Any]] {
        var result: [[String: Any]] = [], params = params, seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try client.request(method, params: params)
            guard let data = page["data"] as? [[String: Any]] else { throw ConnectorError.invalidResponse }
            result += data
            guard let cursor = page["nextCursor"] as? String else { return result }
            guard seen.insert(cursor).inserted, seen.count < 100 else { throw ConnectorError.invalidResponse }
            params["cursor"] = cursor
        } while true
    }

    static func claudeRegistrations(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorError.invalidResponse }
        guard root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else { throw ConnectorError.invalidResponse }
        return ((root["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    private static func inspectClaude(_ profile: ConnectorProfile) throws -> ConnectorSnapshot {
        let names = try readClaudeRegistrations(profile)
        // Read only the transport selector. OAuth/credential files are never read by this app.
        let settingsURL = URL(fileURLWithPath: profile.home + "/settings.json")
        let settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let env = settings["env"] as? [String: Any] ?? [:]
        let atHub = T3CodeLocal.pointsAtHub(env["ANTHROPIC_BASE_URL"] as? String)
        return .init(profile: profile, identity: nil, inferenceAtHub: atHub, canSignIn: false,
                     webStatus: atHub ? .unsupported : .failed, registered: names, apps: [], servers: [],
                     issues: [atHub ? "Claude.ai connectors are disabled by Claude Code when proxy token authentication is active. A standalone MCP server needs its own supported endpoint and sign-in." : "Original Claude connector discovery must be checked in that client's /mcp panel. This is a registration inventory only."])
    }

    private static func readClaudeRegistrations(_ profile: ConnectorProfile) throws -> [String] {
        let path = profile.original ? (profile.home as NSString).deletingLastPathComponent + "/.claude.json" : profile.home + "/.claude.json"
        return try claudeRegistrations(Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// Private, owned subprocess. No inference request is made. Work runs off the UI thread, with
/// bounded reads and cancellation; shutdown never touches an existing client or the live hub.
final class CodexConnectorProcess: ConnectorRequesting {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    private var loginCompletion: [String: Any]?
    private var mcpLoginCompletion: [String: Any]?
    private var closed = false

    init(profile: ConnectorProfile, environment: [String: String]? = nil) throws {
        process.executableURL = URL(fileURLWithPath: profile.executable)
        process.arguments = ["app-server", "--stdio"]
        var env = environment ?? ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = profile.home
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: profile.home)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ConnectorError.unavailable }
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "t3_proxy_connectors", "version": "1.0"],
                                                  "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true]])
            try send(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        try request(method, params: params, timeout: Self.timeout(for: method), cancelled: { false })
    }

    static func timeout(for method: String) -> TimeInterval {
        method == "mcpServer/tool/call" ? 610 : 35
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval, cancelled: () -> Bool) throws -> [String: Any] {
        guard !closed else { throw ConnectorError.unavailable }
        if cancelled() { throw CancellationError() }
        try Task.checkCancellation()
        sequence += 1
        let id = sequence
        try send(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while true {
                let value = try next(deadline, cancelled: cancelled)
                if value["id"] as? Int == id, value["method"] == nil {
                    if value["error"] != nil { throw ConnectorError.unsupported }
                    guard let result = value["result"] as? [String: Any] else { throw ConnectorError.invalidResponse }
                    return result
                }
                try handle(value)
            }
        } catch {
            if error is CancellationError || (error as? ConnectorError) == .timedOut {
                close()
                if method == "mcpServer/tool/call", error is ConnectorError { throw ConnectorError.executionIndeterminate }
            }
            throw error
        }
    }

    func waitForLogin(_ id: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 300
        while true {
            try Task.checkCancellation()
            if let completion = loginCompletion, completion["loginId"] as? String == id {
                guard completion["success"] as? Bool == true else { throw ConnectorError.loginFailed }
                return
            }
            try handle(next(deadline))
        }
    }

    func waitForMCPLogin(server: String, loginID: String?) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 190
        while true {
            try Task.checkCancellation()
            if let result = mcpLoginCompletion, result["name"] as? String == server,
               loginID == nil || result["loginId"] as? String == loginID {
                guard result["success"] as? Bool == true else { throw ServiceConnectionError.authentication }
                return
            }
            try handle(next(deadline))
        }
    }

    private func handle(_ value: [String: Any]) throws {
        if value["method"] as? String == "account/login/completed" { loginCompletion = value["params"] as? [String: Any] }
        if value["method"] as? String == "mcpServer/oauthLogin/completed" { mcpLoginCompletion = value["params"] as? [String: Any] }
        if let id = value["id"], value["method"] != nil {
            // Discovery cannot grant tool, command, or elicitation approvals.
            try send(["id": id, "error": ["code": -32601, "message": "Interactive requests unavailable during connector inspection"]])
        }
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw ConnectorError.unavailable }
    }

    private func next(_ deadline: TimeInterval, cancelled: () -> Bool = { false }) throws -> [String: Any] {
        while true {
            if cancelled() { throw CancellationError() }
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ConnectorError.invalidResponse }
                return value
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ConnectorError.timedOut }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw ConnectorError.unavailable }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw ConnectorError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 16 << 20 else { throw ConnectorError.invalidResponse }
        }
    }

    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        let end = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < end { _ = poll(nil, 0, 20) }
        if process.isRunning { process.terminate() }
        let grace = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { _ = poll(nil, 0, 20) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }

    deinit { close() }
}
