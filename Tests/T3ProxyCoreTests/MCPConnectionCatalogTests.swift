import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct MCPConnectionCatalogTests {
    @Test func sameServiceKeepsSeparateAccountsAndClientTargets() throws {
        let preset = try #require(MCPConnectionCatalog.presets.first { $0.id == "linear" })
        let work = preset.makeConnection(name: "Work Linear", identity: "Work", targets: [.codex])
        let personal = preset.makeConnection(name: "Personal Linear", identity: "Personal", targets: [.claude])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServiceConnectionStore(directory: directory)
        try store.save(work)
        try store.save(personal)
        let saved = try store.load()
        #expect(saved.count == 2)
        #expect(saved.contains(work) && saved.contains(personal))
        #expect(work.id != personal.id && work.serverName != personal.serverName)
        #expect(work.endpoint == "https://mcp.linear.app/mcp")
        #expect(work.authentication == .oauth)
        #expect(work.targets == [.codex] && personal.targets == [.claude])
    }

    @Test func presetsCreateRegistrableConnectionsWithoutCredentialsOrLocalCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServiceConnectionStore(directory: directory)
        #expect(!MCPConnectionCatalog.presets.isEmpty)
        for preset in MCPConnectionCatalog.presets {
            let connection = preset.makeConnection()
            try store.save(connection)
            #expect(connection.provider == .remoteMCP)
            #expect(connection.command == nil && connection.arguments.isEmpty && connection.environmentNames.isEmpty)
            #expect(connection.targets == [.codex, .claude])
        }
        #expect(try store.load().count == MCPConnectionCatalog.presets.count)
        let github = try #require(MCPConnectionCatalog.presets.first { $0.id == "github" })
        #expect(github.makeConnection().authentication == .bearer)
    }
}
