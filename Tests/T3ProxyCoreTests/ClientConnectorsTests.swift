import Foundation
import Testing
@testable import T3ProxyCore

private final class ConnectorFixture: ConnectorRequesting {
    var methods: [String] = []
    var account: [String: Any] = ["account": ["type": "chatgpt", "email": "tools@example.test", "workspaceName": "Accord"]]
    var config: [String: Any] = ["model_provider": "cliproxy", "model_providers": ["cliproxy": ["base_url": "http://127.0.0.1:8317/v1", "env_key": "CLIPROXY_API_KEY", "requires_openai_auth": false]]]
    var registered: [String: Any] = ["monologue": ["url": "https://example.test/mcp"]]
    var installed: [[String: Any]] = [["id": "gmail", "runtimeName": "Gmail", "enabled": true, "callable": false]]
    var servers: [[String: Any]] = [["name": "codex_apps", "authStatus": "oAuth", "tools": [:]]]
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        methods.append(method)
        switch method {
        case "config/read": return ["config": config.merging(["mcp_servers": registered]) { _, new in new }]
        case "account/read": return account
        case "app/list": return ["data": [["id": "gmail", "name": "Gmail", "isAccessible": true, "isEnabled": true]], "nextCursor": NSNull()]
        case "app/installed": return ["apps": installed]
        case "mcpServerStatus/list": return ["data": servers, "nextCursor": NSNull()]
        default: throw ConnectorError.unsupported
        }
    }
}

struct ClientConnectorsTests {
    private let profile = ConnectorProfile(id: "codex_proxy", name: "Codex Proxy", kind: .codex, home: "/tmp/proxy", executable: "/usr/bin/false", original: false)

    @Test func catalogMembershipDoesNotProveCallableTools() throws {
        let result = try ClientConnectors.inspect(profile, using: ConnectorFixture())
        #expect(result.apps.count == 1)
        #expect(result.apps[0].inCatalog && !result.apps[0].callable)
        #expect(result.servers[0].tools.isEmpty)
        #expect(result.identity?.workspace == "Accord")
        #expect(result.canSignIn)
    }

    @Test func runtimeSnapshotAndToolDiscoveryRemainSeparate() throws {
        let fixture = ConnectorFixture()
        fixture.installed[0]["callable"] = true
        fixture.servers[0]["tools"] = ["gmail_search": ["name": "gmail_search", "description": "PRIVATE CONTENT"]]
        let result = try ClientConnectors.inspect(profile, using: fixture)
        #expect(result.apps[0].callable)
        #expect(result.servers[0].tools == ["gmail_search"])
        #expect(!String(describing: result).contains("PRIVATE CONTENT"))
        #expect(result.profile.home == "/tmp/proxy")
    }

    @Test func missingAccountStillDiscoversStandaloneTools() throws {
        let fixture = ConnectorFixture(); fixture.account = ["account": NSNull()]
        let result = try ClientConnectors.inspect(profile, using: fixture)
        #expect(result.identity == nil)
        #expect(result.apps.isEmpty)
        #expect(!fixture.methods.contains("app/list"))
        #expect(fixture.methods.contains("mcpServerStatus/list"))
        #expect(result.webStatus == .signInRequired)
    }

    @Test func disabledAppsAreReportedWithoutPretendingSignInFixesIt() throws {
        let fixture = ConnectorFixture(); fixture.config["features"] = ["apps": false]
        let result = try ClientConnectors.inspect(profile, using: fixture)
        #expect(result.webStatus == .disabled)
        #expect(!fixture.methods.contains("app/list"))
    }

    @Test func loginRequiresExplicitProxyTransportWithItsOwnKey() throws {
        for value: [String: Any] in [[:], ["base_url": "https://example.test/v1", "env_key": "KEY", "requires_openai_auth": false], ["base_url": "http://127.0.0.1:8317/v1", "requires_openai_auth": false], ["base_url": "http://127.0.0.1:8317/v1", "env_key": "KEY", "requires_openai_auth": true]] {
            let fixture = ConnectorFixture(); fixture.config["model_providers"] = ["cliproxy": value]
            #expect(try !ClientConnectors.inspect(profile, using: fixture).canSignIn)
        }
    }

    @Test func incompleteOrUnknownRuntimeIsNotSuccessfulDiscovery() throws {
        let fixture = ConnectorFixture(); fixture.servers = [["name": "gmail", "authStatus": "notLoggedIn", "tools": [:], "toolsError": "private endpoint token"]]
        let result = try ClientConnectors.inspect(profile, using: fixture)
        #expect(result.servers[0].discoveryFailed)
        #expect(result.servers[0].auth == "notLoggedIn")
        #expect(!String(describing: result).contains("private endpoint"))
    }

    @Test func claudeInventoryNeverExposesCredentialsOrClaimsDiscovery() throws {
        let data = Data(#"{"mcpServers":{"monologue":{"type":"http","url":"https://example.test/mcp?token=SECRET","headers":{"Authorization":"SECRET"}},"local":{"command":"node","env":{"KEY":"SECRET"}}},"oauthAccount":{"accessToken":"SECRET"}}"#.utf8)
        let result = try ClientConnectors.claudeRegistrations(data)
        #expect(result == ["local", "monologue"])
        #expect(!String(describing: result).contains("SECRET"))
    }

    @Test func unknownClaudeConfigIsAnErrorNotAnEmptyCatalog() throws {
        #expect(throws: ConnectorError.invalidResponse) { try ClientConnectors.claudeRegistrations(Data("[]".utf8)) }
    }

    @Test func signInURLMustBeOpenAIOAuthNotAnArbitraryRedirect() {
        #expect(ClientConnectors.loginURL("https://auth.openai.com/oauth/authorize?state=one") != nil)
        for value in ["http://auth.openai.com/oauth/authorize", "https://auth.openai.com.evil.test/oauth/authorize", "https://user@auth.openai.com/oauth/authorize", "file:///tmp/login", "https://auth.openai.com:1234/oauth/authorize"] {
            #expect(ClientConnectors.loginURL(value) == nil)
        }
    }

    @Test func profileListUsesT3IdentityAndDoesNotMergeHomes() throws {
        let data = Data(#"{"providerInstances":{"codex_proxy":{"driver":"codex","displayName":"My proxy","config":{"homePath":"~/.codex-proxy","binaryPath":"~/.codex-proxy/codex"}},"claude_proxy":{"driver":"claudeAgent","config":{"homePath":"~/.claude-proxy"}}}}"#.utf8)
        let profiles = try ClientConnectors.profiles(settings: data, home: "/Users/test")
        #expect(profiles.first { $0.id == "codex_proxy" }?.executable == "/Users/test/.codex-proxy/codex")
        #expect(profiles.first { $0.id == "codex_proxy" }?.home == "/Users/test/.codex-proxy")
        #expect(profiles.contains { $0.original && $0.home == "/Users/test/.codex" })
        #expect(Set(profiles.map(\.home)).count == 4)
    }

    @Test func realClientTransportHandlesNotificationsAndPreservesProfileFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fixture-client")
        let config = dir.appendingPathComponent("config.toml")
        let contents = Data("model_provider = 'cliproxy'\n# preserve this user's settings\n".utf8)
        try contents.write(to: config)
        let source = #"""
        #!/usr/bin/python3
        import json, sys, os
        for line in sys.stdin:
            q = json.loads(line)
            if 'id' not in q: continue
            m = q['method']
            if m == 'initialize': r = {}
            elif m == 'config/read':
                r = {'config': {'mcp_servers': {'profile-' + os.path.basename(os.environ['CODEX_HOME']): {}}}}
            elif m == 'account/read': r = {'account': None}
            elif m == 'mcpServerStatus/list':
                r = {'data': [{'name':'fixture-only', 'authStatus':'unsupported', 'tools':{'fixture_search':{}}}]}
            else:
                print(json.dumps({'id':q['id'], 'error':{'code':-32601, 'message':'unexpected mutation'}}), flush=True)
                continue
            print(json.dumps({'method':'fixture/notification', 'params':{}}), flush=True)
            print(json.dumps({'id':q['id'], 'result':r}), flush=True)
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = ConnectorProfile(id: "fixture", name: "Fixture only", kind: .codex, home: dir.path,
                                       executable: script.path, original: false)
        let result = try await ClientConnectors.inspect(profile)
        #expect(result.webStatus == .signInRequired)
        #expect(result.registered == ["profile-" + dir.lastPathComponent])
        #expect(result.servers.first?.tools == ["fixture_search"])
        #expect(try Data(contentsOf: config) == contents)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["config.toml", "fixture-client"])
    }
}
