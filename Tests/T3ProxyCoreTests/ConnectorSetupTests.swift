import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct ConnectorSetupTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func installsWithoutChangingInferenceOrExistingToolsAndIsIdempotent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent(".codex-proxy")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let original = "model_provider = \"cliproxy\"\n[mcp_servers.existing]\ncommand = \"keep-me\"\n"
        try original.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let connection = ServiceConnection(provider: .remoteMCP, name: "Work Gmail MCP", endpoint: "https://mcp.example.com/mcp")
        let setup = ConnectorSetup(home: root, helper: "/Applications/T3 Proxy.app/Contents/MacOS/T3Connectors", codex: "/usr/bin/codex", claude: "/usr/bin/claude", hubPort: 8317, connections: [connection])
        let first = try setup.install()
        #expect(!first.changed.isEmpty)
        let config = try String(contentsOf: codex.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(config.hasPrefix(original))
        #expect(config.contains("[mcp_servers.\(connection.serverName)]"))
        #expect(config.contains("command = \"/Applications/T3 Proxy.app/Contents/MacOS/T3Connectors\""))
        #expect(try setup.install().changed.isEmpty)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".t3/userdata/settings.json"))) as! [String: Any]
        let providers = settings["providerInstances"] as! [String: [String: Any]]
        #expect(providers["codex_proxy"]?["driver"] as? String == "codex")
        #expect(providers["claude_proxy"]?["driver"] as? String == "claudeAgent")
    }
    @Test func conflictDoesNotPartiallyInstallOrFollowConfigSymlinks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent(".claude-proxy")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.json")
        let data = Data("{\"mcpServers\":{\"keep\":{\"command\":\"original\"}}}".utf8)
        try data.write(to: source)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent(".claude.json"), withDestinationURL: source)
        let setup = ConnectorSetup(home: root, helper: "/app/helper", codex: "/bin/codex", claude: "/bin/claude", hubPort: 8317)
        #expect(throws: (any Error).self) { try setup.install() }
        #expect(try Data(contentsOf: source) == data)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex-proxy/config.toml").path))
    }
    @Test func preservesT3FieldsAndSharedCustomizations() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".t3/userdata"), withIntermediateDirectories: true)
        let settings = Data("{\"theme\":\"dark\",\"providerInstances\":{\"custom\":{\"driver\":\"codex\",\"config\":{\"homePath\":\"/elsewhere\"}}}}".utf8)
        try settings.write(to: root.appendingPathComponent(".t3/userdata/settings.json"))
        _ = try ConnectorSetup(home: root, helper: "/app/helper", codex: "/bin/codex", claude: "/bin/claude", hubPort: 8317).install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(".codex-proxy/skills").path) == root.appendingPathComponent(".codex/skills").path)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".t3/userdata/settings.json"))) as! [String: Any]
        #expect(result["theme"] as? String == "dark")
        #expect((result["providerInstances"] as? [String: Any])?["custom"] != nil)
    }
    @Test func targetsAndRemovalOnlyChangeManagedEntries() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = ServiceConnection(provider: .remoteMCP, name: "Work", endpoint: "https://mcp.example.com/mcp", targets: [.claude])
        let helper = "/app/T3Connectors"
        _ = try ConnectorSetup(home: root, helper: helper, codex: "/bin/codex", claude: "/bin/claude", hubPort: 8317, connections: [connection]).install()
        let config = try String(contentsOf: root.appendingPathComponent(".codex-proxy/config.toml"), encoding: .utf8)
        #expect(!config.contains(connection.serverName))
        let path = root.appendingPathComponent(".claude-proxy/.claude.json")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        #expect((before["mcpServers"] as? [String: Any])?[connection.serverName] != nil)
        _ = try ConnectorSetup(home: root, helper: helper, codex: "/bin/codex", claude: "/bin/claude", hubPort: 8317).install()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        #expect((after["mcpServers"] as? [String: Any])?[connection.serverName] == nil)
    }
    @Test func cancelledSetupNeverWritesProfiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ConnectorSetup(home: root, helper: "/app/helper", codex: "/bin/codex", claude: "/bin/claude", hubPort: 8317).install()
        }
        do { _ = try await task.value; Issue.record("Cancelled setup completed") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex-proxy/config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".t3/userdata/settings.json").path))
    }
}
