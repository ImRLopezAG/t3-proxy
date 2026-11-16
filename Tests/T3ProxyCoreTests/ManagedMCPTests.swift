import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct ManagedMCPTests {
    private func fixture(protocolNulls: Bool = false) throws -> (URL, ServiceConnectionStore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fixture-codex")
        let source = #"""
        #!/usr/bin/python3
        import os,sys,json,re
        home=os.environ['CODEX_HOME']; owner=os.path.basename(home)
        config=open(os.path.join(home,'config.toml')).read()
        server=re.search(r'\[mcp_servers\.([^\]]+)\]',config).group(1)
        for line in sys.stdin:
            q=json.loads(line);m=q.get('method')
            if 'id' not in q:continue
            if m=='initialize':r={}
            elif m=='thread/start':
                assert q['params']['ephemeral'] is True
                r={'thread':{'id':'thread-'+owner}}
            elif m=='mcpServerStatus/list':
                tool={'name':'search','description':'Original MCP tool','inputSchema':{'type':'object','properties':{'query':{'type':'string'}}}}
                if PROTOCOL_NULLS:tool.update({'title':None,'annotations':None,'outputSchema':None,'icons':None,'_meta':None})
                r={'data':[{'name':server,'tools':{'search':tool},'authStatus':'unsupported','runtimeStatus':'connected','resources':[],'resourceTemplates':[],'serverCapabilities':{'tools':{},**({'resources':None} if PROTOCOL_NULLS else {})},'serverInfo':{'name':'fixture','version':'1',**({'title':None,'icons':None,'websiteUrl':None} if PROTOCOL_NULLS else {})}}]}
            elif m=='mcpServer/tool/call':
                assert q['params']['server']==server
                assert q['params']['threadId']=='thread-'+owner
                assert 'OPENAI_API_KEY' not in os.environ and 'ANTHROPIC_AUTH_TOKEN' not in os.environ
                if q['params']['arguments']['query']=='stall':
                    open(os.path.join(home,'started'),'w').close()
                    continue
                r={'content':[{'type':'resource',**({'annotations':None} if PROTOCOL_NULLS else {}),'resource':{'uri':'fixture://attachment','mimeType':'text/plain','blob':'aGVsbG8=',**({'_meta':None} if PROTOCOL_NULLS else {})}}], 'structuredContent':{'owner':owner,'query':q['params']['arguments']['query'],**({'nullable':None} if PROTOCOL_NULLS else {})},'isError':False,**({'_meta':None} if PROTOCOL_NULLS else {})}
            elif m=='mcpServer/oauth/login':
                print(json.dumps({'id':q['id'],'result':{'authorizationUrl':'https://mcp.example.com/authorize','loginId':'expected'}}),flush=True)
                for name,login,ok in [('other-server','expected',True),(server,'wrong-login',True),(server,'expected',q['params']['success'])]:
                    print(json.dumps({'method':'mcpServer/oauthLogin/completed','params':{'name':name,'loginId':login,'success':ok}}),flush=True)
                continue
            else:
                print(json.dumps({'id':q['id'],'error':{'code':-32601,'message':'No model turns allowed'}}),flush=True);continue
            print(json.dumps({'id':q['id'],'result':r}),flush=True)
        """#
        try Data(source.replacingOccurrences(of: "PROTOCOL_NULLS", with: protocolNulls ? "True" : "False").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, ServiceConnectionStore(directory: root.appendingPathComponent("registry")), script.path)
    }
    private func request(_ relay: ManagedMCPRelay, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "proof", "method": method, "params": params])
        return try #require(relay.respond(data))
    }
    private func receivedReply(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now() + 2) == .success }
    @Test func sameEndpointAccountsAreIsolatedAndExposeOnlyOriginalTools() throws {
        let (root, store, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ServiceConnection(provider: .remoteMCP, name: "Work Gmail MCP", identity: "work", endpoint: "https://mcp.example.com/mcp")
        let b = ServiceConnection(provider: .remoteMCP, name: "Personal Gmail MCP", identity: "personal", endpoint: "https://mcp.example.com/mcp")
        try store.save(a); try store.save(b)
        let first = try ManagedMCPRelay(id: a.id, store: store, executable: executable)
        let second = try ManagedMCPRelay(id: b.id, store: store, executable: executable)
        defer { first.close(); second.close() }
        let catalog = try request(first, "tools/list")["result"] as! [String: Any]
        let tools = catalog["tools"] as! [[String: Any]]
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "search")
        #expect(tools[0]["description"] as? String == "Original MCP tool")
        let aResult = try request(first, "tools/call", ["name": "search", "arguments": ["query": "invoice"]])["result"] as! [String: Any]
        let bResult = try request(second, "tools/call", ["name": "search", "arguments": ["query": "invoice"]])["result"] as! [String: Any]
        #expect((aResult["structuredContent"] as? [String: String])?["owner"] == a.id.uuidString)
        #expect((bResult["structuredContent"] as? [String: String])?["owner"] == b.id.uuidString)
        let content = bResult["content"] as! [[String: Any]]
        #expect((content[0]["resource"] as? [String: String])?["blob"] == "aGVsbG8=")
        #expect(bResult["isError"] as? Bool == false)
        let config = try String(contentsOf: store.directory.appendingPathComponent(a.id.uuidString + "/config.toml"), encoding: .utf8)
        #expect(config.contains("mcp_oauth_credentials_store = \"keyring\""))
        #expect(config.contains(a.serverName))
        #expect(!config.contains(b.serverName))
    }
    @Test func revocationStopsExistingRelayAndMissingAccountNeverFallsBack() throws {
        let (root, store, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let c = ServiceConnection(provider: .remoteMCP, name: "Fixture", endpoint: "https://mcp.example.com/mcp")
        try store.save(c)
        let relay = try ManagedMCPRelay(id: c.id, store: store, executable: executable); defer { relay.close() }
        try store.remove(c.id)
        let response = try request(relay, "tools/call", ["name": "search", "arguments": ["query": "private"]])
        #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(throws: (any Error).self) { try ManagedMCPRelay(id: UUID(), store: store, executable: executable) }
    }
    @Test func registryIsPrivateAndRejectsCredentialBearingURLs() throws {
        let (root, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ServiceConnection.validEndpoint("http://remote.example.com/mcp"))
        #expect(!ServiceConnection.validEndpoint("https://user:secret@remote.example.com/mcp"))
        #expect(!ServiceConnection.validEndpoint("https://remote.example.com/mcp?token=secret"))
        let c = ServiceConnection(provider: .remoteMCP, name: "Work", endpoint: "https://remote.example.com/mcp", authentication: .oauth)
        try store.save(c)
        #expect(try store.load() == [c])
        #expect(try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("connections.json").path)[.posixPermissions] as? Int == 0o600)
    }
    @Test func protocolOptionalsAreOmittedWithoutChangingServiceNullValues() throws {
        let (root, store, executable) = try fixture(protocolNulls: true); defer { try? FileManager.default.removeItem(at: root) }
        let c = ServiceConnection(provider: .remoteMCP, name: "Fixture", endpoint: "https://mcp.example.com/mcp")
        try store.save(c)
        let relay = try ManagedMCPRelay(id: c.id, store: store, executable: executable); defer { relay.close() }
        let initialized = try request(relay, "initialize")["result"] as! [String: Any]
        let info = initialized["serverInfo"] as! [String: Any]
        #expect(info["title"] == nil && info["icons"] == nil && info["websiteUrl"] == nil)
        #expect((initialized["capabilities"] as? [String: Any])?["resources"] == nil)
        let tools = (try request(relay, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools[0]["annotations"] == nil && tools[0]["outputSchema"] == nil && tools[0]["icons"] == nil)
        let result = try request(relay, "tools/call", ["name": "search", "arguments": ["query": "invoice"]])["result"] as! [String: Any]
        #expect(result["_meta"] == nil)
        #expect((result["structuredContent"] as? [String: Any])?["nullable"] is NSNull)
        let content = result["content"] as! [[String: Any]]
        #expect(content[0]["annotations"] == nil)
        #expect((content[0]["resource"] as? [String: Any])?["blob"] as? String == "aGVsbG8=")
    }
    @Test func toolTimeoutRetiresTransportAndReportsIndeterminateOutcome() throws {
        let (root, store, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let c = ServiceConnection(provider: .remoteMCP, name: "Fixture", endpoint: "https://mcp.example.com/mcp")
        let client = try ManagedMCPClient(connection: c, store: store, executable: executable); defer { client.close() }
        #expect(CodexConnectorProcess.timeout(for: "mcpServer/tool/call") > 600)
        #expect(CodexConnectorProcess.timeout(for: "config/read") == 35)
        #expect(throws: ConnectorError.executionIndeterminate) {
            try client.process.request("mcpServer/tool/call", params: ["threadId": client.threadID, "server": c.serverName, "tool": "search", "arguments": ["query": "stall"]], timeout: 0.05, cancelled: { false })
        }
        #expect(throws: ConnectorError.unavailable) { try client.process.request("ping", params: [:]) }
    }
    @Test func oauthRequiresMatchingServerLoginAndSuccessfulCompletion() throws {
        let (root, store, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let c = ServiceConnection(provider: .remoteMCP, name: "Fixture", endpoint: "https://mcp.example.com/mcp", authentication: .oauth)
        for success in [false, true] {
            let client = try ManagedMCPClient(connection: c, store: store, executable: executable); defer { client.close() }
            let result = try client.process.request("mcpServer/oauth/login", params: ["name": c.serverName, "success": success])
            #expect(result["loginId"] as? String == "expected")
            if success { try client.process.waitForMCPLogin(server: c.serverName, loginID: "expected") }
            else {
                do { try client.process.waitForMCPLogin(server: c.serverName, loginID: "expected"); Issue.record("Unsuccessful OAuth was accepted") }
                catch ServiceConnectionError.authentication { }
            }
        }
    }
    @Test func cancellationIsReadWhileToolIsRunningAndRetiresOnlyOwnedTransport() async throws {
        let (root, store, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let c = ServiceConnection(provider: .remoteMCP, name: "Fixture", endpoint: "https://mcp.example.com/mcp")
        try store.save(c)
        let session = ManagedMCPSession(try ManagedMCPRelay(id: c.id, store: store, executable: executable))
        defer { session.finish() }
        let response = AsyncStream<Data>.makeStream()
        let received = DispatchSemaphore(value: 0)
        let call = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 42, "method": "tools/call", "params": ["name": "search", "arguments": ["query": "stall"]]])
        session.submit(call) { response.continuation.yield($0); received.signal() }
        let started = store.directory.appendingPathComponent(c.id.uuidString + "/started")
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: started.path))
        session.submit(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}"#.utf8)) { _ in }
        #expect(receivedReply(received))
        // The response must arrive before EOF or session teardown cancels pending operations.
        session.finish(); response.continuation.finish()
        var replies: [Data] = []
        for await value in response.stream { replies.append(value) }
        let reply = try JSONSerialization.jsonObject(with: #require(replies.first)) as! [String: Any]
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32800)
        #expect(ContinuousClock.now < deadline)
    }
}
