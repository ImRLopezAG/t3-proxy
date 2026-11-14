import Foundation
import Darwin

public enum ConnectorSetupError: Error, LocalizedError {
    case conflict(String), changed, unavailable
    public var errorDescription: String? {
        switch self {
        case .conflict(let path): "Setup preserved a conflicting file: \(path). Resolve it before running setup again."
        case .changed: "Configuration changed during setup. Recheck it and run setup again."
        case .unavailable: "Setup could not write its files. Existing files have private backups alongside them."
        }
    }
}

/// Only installs client-side files. Never touches the running hub, source credentials or source configs.
public struct ConnectorSetup: Sendable {
    public struct Result: Sendable { public let changed: [String] }
    let home: URL
    let helper: String
    let codex: String
    let claude: String
    let hubPort: Int
    let connections: [ServiceConnection]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, helper: String, codex: String, claude: String, hubPort: Int, connections: [ServiceConnection] = []) {
        self.home = home; self.helper = helper; self.codex = codex; self.claude = claude; self.hubPort = hubPort; self.connections = connections
    }
    public func install() throws -> Result {
        try Task.checkCancellation()
        guard (1...65535).contains(hubPort), [helper, codex, claude].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") }) else { throw ConnectorSetupError.unavailable }
        let fm = FileManager.default
        let setupLock = Darwin.open(home.appendingPathComponent(".t3-proxy-setup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard setupLock >= 0 else { throw ConnectorSetupError.unavailable }
        defer { Darwin.close(setupLock) }
        guard flock(setupLock, LOCK_EX | LOCK_NB) == 0 else { throw ConnectorSetupError.changed }
        defer { flock(setupLock, LOCK_UN) }
        struct Write { let url: URL; let before: Data?; let after: Data; let mode: Int }
        var writes: [Write] = []
        var links: [(URL, URL)] = []
        func checked(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            // Every parent must be a physical path: appending a missing leaf must not bypass a symlinked home.
            var cursor = url
            while cursor.path.count > home.path.count {
                if (try? fm.attributesOfItem(atPath: cursor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw ConnectorSetupError.conflict(cursor.path)
                }
                cursor.deleteLastPathComponent()
            }
            return url
        }
        func read(_ relative: String) throws -> Data? {
            let url = try checked(relative)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        func stage(_ relative: String, _ after: Data, mode: Int = 0o600) throws {
            let url = try checked(relative), before = try read(relative)
            if before != after { writes.append(.init(url: url, before: before, after: after, mode: mode)) }
        }
        func json(_ data: Data?) throws -> [String: Any] {
            guard let data else { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorSetupError.unavailable }
            return object
        }
        func encoded(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func string(_ value: String) throws -> String { try ConnectorFiles.tomlString(value) }
        let start = "# BEGIN T3 Proxy MCP connections", end = "# END T3 Proxy MCP connections"
        let desired = connections.filter { $0.enabled }
        var sections: [String] = []
        for c in desired where c.targets.contains(.codex) {
            sections.append("[mcp_servers.\(c.serverName)]\ncommand = \(try string(helper))\nargs = [\"connect\", \(try string(c.id.uuidString))]\n")
        }
        let block = start + "\n" + sections.joined(separator: "\n") + end + "\n"
        let codexPath = ".codex-proxy/config.toml"
        let codexBefore = try read(codexPath)
        var codexText = codexBefore.map { String(decoding: $0, as: UTF8.self) } ?? "model_provider = \"cliproxy\"\n[model_providers.cliproxy]\nname = \"CLIProxyAPI\"\nbase_url = \"http://127.0.0.1:\(hubPort)/v1\"\nwire_api = \"responses\"\nenv_key = \"CLIPROXY_API_KEY\"\nrequires_openai_auth = false\n"
        if codexText.contains(start) || codexText.contains(end) {
            guard codexText.components(separatedBy: start).count == 2, codexText.components(separatedBy: end).count == 2,
                  let a = codexText.range(of: start), let b = codexText.range(of: end), a.lowerBound < b.lowerBound else { throw ConnectorSetupError.conflict(codexPath) }
            let suffix = codexText[b.upperBound...]
            let rangeEnd = suffix.hasPrefix("\n") ? codexText.index(after: b.upperBound) : b.upperBound
            codexText.removeSubrange(a.lowerBound..<rangeEnd)
        }
        for c in desired where c.targets.contains(.codex) {
            guard !codexText.contains(c.serverName) else { throw ConnectorSetupError.conflict(codexPath + " (" + c.serverName + ")") }
        }
        if !sections.isEmpty { codexText += (codexText.hasSuffix("\n\n") ? "" : codexText.hasSuffix("\n") ? "\n" : "\n\n") + block }
        try stage(codexPath, Data(codexText.utf8))
        let claudePath = ".claude-proxy/.claude.json"
        var claudeJSON = try json(read(claudePath))
        if claudeJSON["mcpServers"] != nil && !(claudeJSON["mcpServers"] is [String: Any]) { throw ConnectorSetupError.conflict(claudePath) }
        var servers = claudeJSON["mcpServers"] as? [String: Any] ?? [:]
        for (name, value) in servers {
            guard let server = value as? [String: Any], let args = server["args"] as? [String], args.count == 2, args[0] == "connect", let id = UUID(uuidString: args[1]),
                  name == "t3_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                  (server["command"] as? String).map({ URL(fileURLWithPath: $0).lastPathComponent == "T3Connectors" }) == true else { continue }
            servers.removeValue(forKey: name)
        }
        for c in desired where c.targets.contains(.claude) {
            guard servers[c.serverName] == nil else { throw ConnectorSetupError.conflict(claudePath + " (" + c.serverName + ")") }
            servers[c.serverName] = ["command": helper, "args": ["connect", c.id.uuidString]]
        }
        if claudeJSON["mcpServers"] == nil || !NSDictionary(dictionary: claudeJSON["mcpServers"] as? [String: Any] ?? [:]).isEqual(to: servers) {
            claudeJSON["mcpServers"] = servers; try stage(claudePath, encoded(claudeJSON))
        }
        if try read(".claude-proxy/settings.json") == nil {
            try stage(".claude-proxy/settings.json", encoded(["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:\(hubPort)"]]))
        }
        for (folder, binary) in [(".codex-proxy", codex), (".claude-proxy", claude)] {
            let kind = folder == ".codex-proxy" ? "codex" : "claude"
            let launcher = "\(folder)/t3-\(kind)"
            let script = "#!/bin/sh\nexec \(quoted(helper)) launch \(kind) \(quoted(home.appendingPathComponent(folder).path)) \(quoted(binary)) \(hubPort) \"$@\"\n"
            if let existing = try read(launcher), existing != Data(script.utf8) { throw ConnectorSetupError.conflict(home.appendingPathComponent(launcher).path) }
            try stage(launcher, Data(script.utf8), mode: 0o700)
            let shared = kind == "codex" ? ["skills", "plugins", "agents"] : ["skills", "plugins", "agents", "hooks"]
            for name in shared {
                let source = home.appendingPathComponent((kind == "codex" ? ".codex/" : ".claude/") + name)
                let target = home.appendingPathComponent(folder + "/" + name)
                guard fm.fileExists(atPath: source.path) else { continue }
                _ = try checked(folder)
                // Keep all existing customization entries, including intentionally different links.
                if !fm.fileExists(atPath: target.path) && (try? fm.destinationOfSymbolicLink(atPath: target.path)) == nil { links.append((target, source)) }
            }
        }
        let settingsPath = ".t3/userdata/settings.json"
        var settings = try json(read(settingsPath))
        if settings["providerInstances"] != nil && !(settings["providerInstances"] is [String: Any]) { throw ConnectorSetupError.conflict(settingsPath) }
        var instances = settings["providerInstances"] as? [String: Any] ?? [:]
        for (id, driver, label, folder, binary) in [("codex_proxy", "codex", "Codex Proxy", ".codex-proxy", "t3-codex"), ("claude_proxy", "claudeAgent", "Claude Proxy", ".claude-proxy", "t3-claude")] {
            if let value = instances[id] as? [String: Any] {
                let config = value["config"] as? [String: Any] ?? [:]
                let path = (config["homePath"] as? String ?? "").replacingOccurrences(of: "~/", with: home.path + "/")
                guard value["driver"] as? String == driver, path == home.appendingPathComponent(folder).path else { throw ConnectorSetupError.conflict(settingsPath + " (" + id + ")") }
            } else {
                instances[id] = ["driver": driver, "displayName": label, "enabled": true,
                                 "config": ["homePath": home.appendingPathComponent(folder).path, "binaryPath": home.appendingPathComponent(folder + "/" + binary).path]]
            }
        }
        if !(NSDictionary(dictionary: settings["providerInstances"] as? [String: Any] ?? [:]).isEqual(to: instances)) {
            settings["providerInstances"] = instances; try stage(settingsPath, encoded(settings))
        }
        // Preflight is complete before any profile writes. Compare again immediately before replacement.
        // Cancellation ends at this boundary: once committing, finish the prepared writes.
        try Task.checkCancellation()
        var changed: [String] = []
        for write in writes {
            guard (try? Data(contentsOf: write.url)) == write.before else { throw ConnectorSetupError.changed }
            try fm.createDirectory(at: write.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let before = write.before {
                let backup = write.url.appendingPathExtension("t3-backup-" + UUID().uuidString)
                try ConnectorFiles.write(before, to: backup, replacing: false)
            }
            try ConnectorFiles.write(write.after, to: write.url, mode: mode_t(write.mode))
            changed.append(write.url.path)
        }
        for (target, source) in links {
            try fm.createSymbolicLink(at: target, withDestinationURL: source); changed.append(target.path)
        }
        return .init(changed: changed)
    }
}
