import Foundation
import CoreFoundation
import CryptoKit

public enum PluginError: Error, Equatable {
    case invalidID, invalidValue, stale, unsupported, restartRequired, unavailable

    public static func message(_ error: Error) -> String {
        switch error {
        case PluginError.unsupported: "This hub does not provide the Plugins API. Update CLIProxyAPI to use this page."
        case PluginError.restartRequired: "The hub could not finish this action while the plugin is loaded. Restart the hub when convenient, then review the plugin and try again."
        case PluginError.stale: "The plugin or its configuration changed. Reload and review it before trying again."
        case PluginError.invalidValue: "Check the field values. Only the plugin’s supported fields and choices can be saved."
        case ManagementError.locked, ProxyError.unauthorized: "Management access is locked. Check Settings → Connection."
        case ProxyError.unreachable: "Could not reach the hub. Reload to check the result before retrying an action."
        default: "The hub could not complete the request. Reload to check the plugin’s current state before retrying."
        }
    }
}

public enum PluginValue: Sendable, Equatable {
    case text(String), number(Double), bool(Bool)
    public var text: String {
        switch self {
        case .text(let s): s
        case .number(let n): String(n)
        case .bool(let b): b ? "true" : "false"
        }
    }
    var json: any Sendable {
        switch self { case .text(let s): s; case .number(let n): n; case .bool(let b): b }
    }
    init?(_ value: Any?) {
        if let s = value as? String { self = .text(s) }
        else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.doubleValue.isFinite { self = .number(n.doubleValue) }
            else { return nil }
        } else { return nil }
    }
}

public struct HubPlugin: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var enabled: Bool
    public var active: Bool
    public var registered: Bool
    public var status: String { active ? "Active" : enabled ? "Not active" : "Disabled" }
}

public struct PluginList: Sendable {
    public var enabled: Bool
    public var plugins: [HubPlugin]
}

public struct StorePlugin: Sendable, Identifiable, Equatable {
    public var id: String { sourceID + ":" + pluginID }
    public var pluginID: String
    public var sourceID: String
    public var sourceName: String
    public var sourceHost: String
    var sourceFingerprint: String
    public var name: String
    public var description: String
    public var author: String
    public var version: String
    public var installedVersion: String
    public var installed: Bool
    public var updateAvailable: Bool
    public var installIssue: String?
    public var canInstall: Bool { installIssue == nil && (!installed || updateAvailable) }
    public var versionLabel: String { version.isEmpty ? "Latest release" : version }
}

public struct PluginStore: Sendable {
    public var enabled: Bool
    public var plugins: [StorePlugin]
    public var failedSources: Int
}

public struct PluginActionResult: Sendable {
    public var restartRequired: Bool
}

public struct PluginField: Sendable, Identifiable, Equatable {
    public var id: String
    public var type: String
    public var description: String
    public var choices: [String]
    public var secret: Bool
    public var isSet: Bool
    /// Secrets and structured values are never exposed to the UI.
    public var value: PluginValue?
    public var editable: Bool { ["string", "enum", "secret", "password", "boolean", "bool", "integer", "int", "number", "float"].contains(type) }

    public func parse(_ text: String) -> PluginValue? {
        guard editable, text.count <= 10_000 else { return nil }
        let v: PluginValue
        switch type {
        case "boolean", "bool":
            guard text == "true" || text == "false" else { return nil }; v = .bool(text == "true")
        case "integer", "int", "number", "float":
            guard let n = Double(text), n.isFinite, abs(n) <= 9_007_199_254_740_991,
                  !["integer", "int"].contains(type) || n == n.rounded() else { return nil }
            v = .number(n)
        default: v = .text(text)
        }
        guard choices.isEmpty || choices.contains(text) else { return nil }
        return v
    }
}

public struct PluginConfiguration: Sendable {
    public var id: String
    public var revision: String
    public var fields: [PluginField]
}

private enum PluginRules {
    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil && !id.contains("..")
    }
    static func check(_ id: String) throws { guard validID(id) else { throw PluginError.invalidID } }
    static func text(_ value: Any?, max: Int = 200) -> String {
        ManagementRules.cleanNickname(value as? String, max: max) ?? ""
    }
    static func secret(_ name: String, _ type: String, flagged: Bool) -> Bool {
        flagged || ["secret", "password"].contains(type) || name.range(
            of: #"(^|[-_.])(api[-_]?key|secret[-_]?key|key|token|secret|password|passwd|credentials?|session[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|client[-_]?secret|authorization|cookie)$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyError.incompatible }
        return o
    }
    static func entries(_ o: [String: Any]) throws -> [[String: Any]] {
        guard let rows = o["plugins"] as? [[String: Any]], o["plugins_enabled"] is Bool else { throw ProxyError.incompatible }
        return rows
    }
    static func plugin(_ row: [String: Any]) -> HubPlugin? {
        guard let id = row["id"] as? String, validID(id) else { return nil }
        let meta = row["metadata"] as? [String: Any] ?? [:]
        return HubPlugin(id: id, name: text(meta["name"]).nonEmpty ?? id, version: text(meta["version"], max: 64),
                         author: text(meta["author"]), enabled: row["enabled"] as? Bool == true,
                         active: row["effective_enabled"] as? Bool == true, registered: row["registered"] as? Bool == true)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

extension ManagementClient {
    /// Fixed plugin routes use the same loopback session and rejected-key gate as account management.
    private func pluginRequest(_ method: String, _ path: String, _ body: (any Sendable)? = nil,
                               key: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30) async throws -> Data {
        do {
            let data = try await sendJSON(method, "v8/management/" + path, body, key: key, timeout: timeout,
                                      query: query, captureConflict: true)
            let o = try PluginRules.object(data)
            if o["error"] != nil { throw PluginError.unavailable }
            return data
        } catch ManagementConflict.response(let data) {
            let o = try PluginRules.object(data)
            if let error = o["error"] as? String,
               ["plugin_update_requires_restart", "plugin_delete_requires_restart"].contains(error),
               o["restart_required"] as? Bool == true { throw PluginError.restartRequired }
            throw ProxyError.http(409)
        } catch ProxyError.http(404) where method == "GET" && ["plugins", "plugins/store"].contains(path) {
            throw PluginError.unsupported
        }
    }

    public func plugins(key: String) async throws -> PluginList {
        let o = try PluginRules.object(try await pluginRequest("GET", "plugins", key: key))
        let entries = try PluginRules.entries(o)
        var seen = Set<String>()
        return PluginList(enabled: o["plugins_enabled"] as? Bool == true,
                          plugins: entries.compactMap(PluginRules.plugin).filter { seen.insert($0.id).inserted })
    }

    public func pluginStore(key: String) async throws -> PluginStore {
        let o = try PluginRules.object(try await pluginRequest("GET", "plugins/store", key: key))
        let rows = try PluginRules.entries(o)
        var seen = Set<String>()
        let entries = rows.compactMap { row -> StorePlugin? in
            guard let id = row["id"] as? String, let source = row["source_id"] as? String,
                  PluginRules.validID(id), PluginRules.validID(source), seen.insert(source + ":" + id).inserted else { return nil }
            let version = PluginRules.text(row["version"], max: 64)
            let sourceURL = row["source_url"] as? String ?? ""
            var issue: String?
            if !(version.isEmpty && row["install_type"] as? String == "github-release"),
               version.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) == nil {
                issue = "No installable release version"
            }
            if let platforms = row["platforms"] as? [[String: String]], !platforms.isEmpty,
               !platforms.contains(where: { $0["goos"] == "darwin" && $0["goarch"] == "arm64" }) {
                issue = "Not available for Apple silicon Macs"
            }
            if row["auth_required"] as? Bool == true && row["auth_configured"] as? Bool != true {
                issue = "Configure store authentication in the hub first"
            }
            if row["installed"] as? Bool == true, let status = row["install_source_status"] as? String,
               !["matched", "assumed"].contains(status) {
                issue = "Installed plugin’s source does not match this store"
            }
            return StorePlugin(pluginID: id, sourceID: source, sourceName: PluginRules.text(row["source_name"]).nonEmpty ?? source,
                               sourceHost: PluginRules.text(URLComponents(string: sourceURL)?.host),
                               sourceFingerprint: SHA256.hash(data: Data(sourceURL.utf8)).map { String(format: "%02x", $0) }.joined(),
                               name: PluginRules.text(row["name"]).nonEmpty ?? id,
                               description: PluginRules.text(row["description"], max: 800), author: PluginRules.text(row["author"]),
                               version: version, installedVersion: PluginRules.text(row["installed_version"], max: 64),
                               installed: row["installed"] as? Bool == true, updateAvailable: row["update_available"] as? Bool == true,
                               installIssue: issue)
        }
        return PluginStore(enabled: o["plugins_enabled"] as? Bool == true, plugins: entries,
                           failedSources: (o["source_errors"] as? [Any])?.count ?? 0)
    }

    public func installPlugin(_ selected: StorePlugin, key: String) async throws -> PluginActionResult {
        try PluginRules.check(selected.pluginID); try PluginRules.check(selected.sourceID)
        let current = try await pluginStore(key: key)
        guard let plugin = current.plugins.first(where: { $0.id == selected.id }), plugin == selected else { throw PluginError.stale }
        guard plugin.canInstall else { throw PluginError.unavailable }
        let body: [String: String] = plugin.version.isEmpty ? [:] : ["version": plugin.version]
        let data = try await pluginRequest("POST", "plugins/store/\(plugin.pluginID)/install", body,
                                           key: key, query: [.init(name: "source", value: plugin.sourceID)], timeout: 180)
        let o = try PluginRules.object(data)
        guard o["status"] as? String == "installed", o["id"] as? String == plugin.pluginID else { throw ProxyError.incompatible }
        return PluginActionResult(restartRequired: o["restart_required"] as? Bool == true)
    }

    private func checkPlugin(_ selected: HubPlugin, key: String) async throws {
        guard try await plugins(key: key).plugins.first(where: { $0.id == selected.id }) == selected else { throw PluginError.stale }
    }

    public func setPluginEnabled(_ selected: HubPlugin, enabled: Bool, key: String) async throws {
        try PluginRules.check(selected.id)
        try await checkPlugin(selected, key: key)
        _ = try await pluginRequest("PUT", "config/plugins/configs/\(selected.id)/enabled", enabled, key: key)
    }

    public func removePlugin(_ selected: HubPlugin, key: String) async throws -> PluginActionResult {
        try PluginRules.check(selected.id)
        try await checkPlugin(selected, key: key)
        let o = try PluginRules.object(try await pluginRequest("DELETE", "plugins/\(selected.id)", key: key))
        guard o["status"] as? String == "deleted", o["id"] as? String == selected.id else { throw ProxyError.incompatible }
        return PluginActionResult(restartRequired: o["restart_required"] as? Bool == true)
    }

    public func pluginConfiguration(id: String, key: String) async throws -> PluginConfiguration {
        try PluginRules.check(id)
        let list = try PluginRules.object(try await pluginRequest("GET", "plugins", key: key))
        guard let entry = try PluginRules.entries(list).first(where: { $0["id"] as? String == id }) else { throw PluginError.stale }
        let data = try await send("GET", "v8/management/config", nil, key: key)
        let config = try PluginRules.object(data)
        let plugins = config["plugins"] as? [String: Any] ?? [:]
        let configs = plugins["configs"] as? [String: Any] ?? [:]
        let stored = configs[id] as? [String: Any] ?? [:]
        let meta = entry["metadata"] as? [String: Any] ?? [:]
        let own = entry["config_fields"] as? [[String: Any]] ?? []
        let declarations = own.isEmpty ? meta["config_fields"] as? [[String: Any]] ?? [] : own
        var seen = Set<String>()
        let fields = declarations.prefix(100).compactMap { f -> PluginField? in
            guard let name = f["name"] as? String, PluginRules.validID(name), !["enabled", "priority"].contains(name),
                  seen.insert(name).inserted else { return nil }
            let type = (f["type"] as? String ?? "string").lowercased()
            let secret = PluginRules.secret(name, type, flagged: f["secret"] as? Bool == true)
            return PluginField(id: name, type: type, description: PluginRules.text(f["description"], max: 500),
                               choices: Array((f["enum_values"] as? [String] ?? []).prefix(100)), secret: secret,
                               isSet: stored[name] != nil,
                               value: secret ? nil : PluginValue(stored[name] ?? f["default"]))
        }
        return PluginConfiguration(id: id, revision: ConfigSummary.revision(data), fields: fields)
    }

    public func savePluginConfiguration(_ selected: PluginConfiguration, changes: [String: PluginValue], key: String) async throws {
        try PluginRules.check(selected.id)
        guard !changes.isEmpty else { throw PluginError.invalidValue }
        for (name, value) in changes {
            guard let field = selected.fields.first(where: { $0.id == name }), field.parse(value.text) == value else { throw PluginError.invalidValue }
        }
        let current = try await pluginConfiguration(id: selected.id, key: key)
        guard current.revision == selected.revision, current.fields == selected.fields else { throw PluginError.stale }
        _ = try await pluginRequest("PATCH", "config/plugins/configs/\(selected.id)", changes.mapValues(\.json), key: key)
    }
}
