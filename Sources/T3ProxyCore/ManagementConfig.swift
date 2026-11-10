import Foundation
import CryptoKit

/// Config and AI-provider reads, ported from Proxy Deck (config.summary/config.get/config.patch/providers.models).
/// Decoding is allowlisted: secret fields are either never decoded, reduced to "set or not",
/// or masked inside the decoder so only the masked text is kept.
public enum ConfigError: Error, Equatable {
    /// The hub's config changed since it was read (Proxy Deck's 409).
    case stale
    case invalidChannel
    case invalidValue(ConfigSetting)
    case nothingChanged
}

/// A value of an editable setting.
public enum ConfigValue: Sendable, Hashable {
    case bool(Bool), int(Int), text(String)
    var json: any Sendable {
        switch self { case .bool(let b): b; case .int(let i): i; case .text(let t): t }
    }
}

public enum ConfigKind: Sendable, Equatable {
    case bool
    case int(ClosedRange<Int>)
    case choice([String])
    /// Like 30m or 1h.
    case duration
}

/// The settings T3 Proxy may change: Proxy Deck's SETTINGS allowlist minus proxy-url (shown masked, so it
/// can't be edited safely). Management, remote management, the key, auth-dir, host, port and TLS are never writable.
public enum ConfigSetting: String, CaseIterable, Sendable, Identifiable {
    case commercialMode = "server.commercial-mode"
    case plugins = "plugins.enabled"
    case passthroughHeaders = "requests.passthrough-headers"
    case keepalive = "requests.nonstream-keepalive-interval"
    case strategy = "routing.strategy"
    case forceModelPrefix = "routing.force-model-prefix"
    case sessionAffinity = "routing.session-affinity"
    case sessionAffinityTTL = "routing.session-affinity-ttl"
    case requestRetry = "routing.retry.request-retry"
    case maxRetryInterval = "routing.retry.max-retry-interval"
    case maxRetryCredentials = "routing.retry.max-retry-credentials"
    case disableCooling = "routing.cooldown.disable-cooling"
    case saveCooldownStatus = "routing.cooldown.save-cooldown-status"
    case transientErrorCooldown = "routing.cooldown.transient-error-cooldown-seconds"
    case debug = "observability.logs.debug"
    case loggingToFile = "observability.logs.logging-to-file"
    case requestLog = "observability.logs.request-log"
    case errorLogsMaxFiles = "observability.logs.error-logs-max-files"
    case logsMaxTotalSizeMB = "observability.logs.logs-max-total-size-mb"
    case usageStatistics = "observability.usage.usage-statistics-enabled"
    case switchProject = "quota-exceeded.switch-project"
    case switchPreviewModel = "quota-exceeded.switch-preview-model"

    public var id: String { rawValue }
    public var path: [String] { rawValue.split(separator: ".").map(String.init) }

    public static let strategies = ["round-robin", "weighted-round-robin", "fill-first"]

    public var kind: ConfigKind {
        switch self {
        case .keepalive: .int(0...3600)
        case .strategy: .choice(Self.strategies)
        case .sessionAffinityTTL: .duration
        case .requestRetry: .int(0...100)
        case .maxRetryInterval, .transientErrorCooldown: .int(0...86_400)
        case .maxRetryCredentials: .int(0...1000)
        case .errorLogsMaxFiles: .int(0...10_000)
        case .logsMaxTotalSizeMB: .int(0...1_000_000)
        default: .bool
        }
    }

    public var title: String {
        switch self {
        case .commercialMode: "Commercial mode"
        case .plugins: "Plugins"
        case .passthroughHeaders: "Pass through upstream headers"
        case .keepalive: "Non-stream keepalive (s)"
        case .strategy: "Strategy"
        case .forceModelPrefix: "Require model prefix"
        case .sessionAffinity: "Session affinity"
        case .sessionAffinityTTL: "Session affinity TTL"
        case .requestRetry: "Request retry"
        case .maxRetryInterval: "Max retry interval (s)"
        case .maxRetryCredentials: "Max credentials per retry"
        case .disableCooling: "Disable cooldowns"
        case .saveCooldownStatus: "Remember cooldowns across restarts"
        case .transientErrorCooldown: "Transient error cooldown (s)"
        case .debug: "Debug logging"
        case .loggingToFile: "Log to file"
        case .requestLog: "Request log"
        case .errorLogsMaxFiles: "Error log files kept"
        case .logsMaxTotalSizeMB: "Max total log size (MB)"
        case .usageStatistics: "Usage statistics"
        case .switchProject: "Switch project"
        case .switchPreviewModel: "Switch to preview model"
        }
    }

    /// Proxy Deck's help strings.
    public var help: String? {
        switch self {
        case .commercialMode: "Lowers per-request memory use for high-concurrency deployments."
        case .plugins: "Load plugins from the plugins directory."
        case .keepalive: "0 turns it off."
        case .sessionAffinity: "Keep a session on the same credential."
        case .sessionAffinityTTL: "Like 30m or 1h."
        case .maxRetryCredentials, .logsMaxTotalSizeMB: "0 means no limit."
        case .requestLog: "Writes request and response bodies to disk."
        case .loggingToFile: "The Logs page needs this on."
        default: nil
        }
    }

    /// The value if it is valid for this setting (Proxy Deck's settingValue()).
    public func validated(_ v: ConfigValue) -> ConfigValue? {
        switch (kind, v) {
        case (.bool, .bool): v
        case (.int(let r), .int(let i)): r.contains(i) ? v : nil
        case (.choice(let c), .text(let t)): c.contains(t) ? v : nil
        case (.duration, .text(let t)): t.range(of: #"^[0-9]{1,6}(ms|s|m|h)$"#, options: .regularExpression) != nil ? v : nil
        default: nil
        }
    }

    /// Proxy Deck's buildSettingsPatch(): one nested merge patch, values validated.
    public static func patch(_ changes: [ConfigSetting: ConfigValue]) throws -> [String: any Sendable] {
        var tree: [String: Any] = [:]
        func put(_ node: inout [String: Any], _ path: ArraySlice<String>, _ v: any Sendable) {
            guard let k = path.first else { return }
            if path.count == 1 { node[k] = v; return }
            var child = node[k] as? [String: Any] ?? [:]
            put(&child, path.dropFirst(), v)
            node[k] = child
        }
        for (s, v) in changes {
            guard let ok = s.validated(v) else { throw ConfigError.invalidValue(s) }
            put(&tree, s.path[...], ok.json)
        }
        func seal(_ n: [String: Any]) -> [String: any Sendable] {
            n.mapValues { v -> any Sendable in (v as? [String: Any]).map(seal) ?? (v as! any Sendable) }
        }
        return seal(tree)
    }
}

public enum ConfigMask {
    public static let mask = "••••"
    /// Proxy Deck's maskKey(): keeps an sk-/rk-/pk- prefix and the last 4 characters of keys 12+ long.
    public static func key(_ s: String) -> String {
        let prefix = ["sk-", "rk-", "pk-"].first { s.hasPrefix($0) } ?? ""
        return s.count >= 12 ? "\(prefix)…\(s.suffix(4))" : mask
    }
    /// Proxy Deck's maskUrl(): user:pass masked, a query naming key/token/secret/sig masked.
    public static func url(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"^([a-zA-Z][a-zA-Z0-9+.-]*://)([^@/\s]+)@"#, with: "$1\(mask)@", options: .regularExpression)
        if let q = out.firstIndex(of: "?"), out[q...].range(of: "key|token|secret|sig", options: [.regularExpression, .caseInsensitive]) != nil {
            out = String(out[..<q]) + "?" + mask
        }
        return out
    }
}

// MARK: - Lenient allowlist decoding

/// One odd value must not fail the whole read: wrong types decode as nil.
struct L<T: Decodable>: Decodable {
    var v: T?
    init(from d: Decoder) throws { v = try? d.singleValueContainer().decode(T.self) }
}
/// A secret slot reduced to "non-empty or not"; the value is dropped inside the decoder.
struct Presence: Decodable {
    var set: Bool
    init(from d: Decoder) throws {
        let s = try? d.singleValueContainer().decode(String.self)
        set = !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
/// A URL masked inside the decoder.
struct MaskedURL: Decodable {
    var v: String?
    init(from d: Decoder) throws { v = (try? d.singleValueContainer().decode(String.self)).map(ConfigMask.url) }
}
/// An API key masked inside the decoder.
struct MaskedKey: Decodable {
    var v: String?
    init(from d: Decoder) throws {
        v = (try? d.singleValueContainer().decode(String.self)).flatMap { $0.isEmpty ? nil : ConfigMask.key($0) }
    }
}
/// Header values: "$Header" copies are shown, anything else masked.
struct MaskedHeader: Decodable {
    var v: String?
    init(from d: Decoder) throws {
        v = (try? d.singleValueContainer().decode(String.self)).map { $0.hasPrefix("$") ? $0 : ConfigMask.mask }
    }
}

struct ConfigDoc: Decodable {
    struct Access: Decodable { var apiKeys: L<[Presence]>?; enum CodingKeys: String, CodingKey { case apiKeys = "api-keys" } }
    struct Management: Decodable {
        var allowRemote: L<Bool>?, disablePanel: L<Bool>?, secretKey: Presence?
        enum CodingKeys: String, CodingKey { case allowRemote = "allow-remote", disablePanel = "disable-control-panel", secretKey = "secret-key" }
    }
    struct TLS: Decodable { var enable: L<Bool>? }
    struct Server: Decodable {
        var host: L<String>?, port: L<Int>?, commercialMode: L<Bool>?, tls: L<TLS>?
        enum CodingKeys: String, CodingKey { case host, port, tls, commercialMode = "commercial-mode" }
    }
    struct Requests: Decodable {
        var proxyURL: MaskedURL?, passthrough: L<Bool>?, keepalive: L<Int>?
        enum CodingKeys: String, CodingKey { case proxyURL = "proxy-url", passthrough = "passthrough-headers", keepalive = "nonstream-keepalive-interval" }
    }
    struct Retry: Decodable {
        var requestRetry: L<Int>?, maxInterval: L<Int>?, maxCredentials: L<Int>?
        enum CodingKeys: String, CodingKey { case requestRetry = "request-retry", maxInterval = "max-retry-interval", maxCredentials = "max-retry-credentials" }
    }
    struct Cooldown: Decodable {
        var disable: L<Bool>?, save: L<Bool>?, transient: L<Int>?
        enum CodingKeys: String, CodingKey { case disable = "disable-cooling", save = "save-cooldown-status", transient = "transient-error-cooldown-seconds" }
    }
    struct Routing: Decodable {
        var strategy: L<String>?, forcePrefix: L<Bool>?, affinity: L<Bool>?, affinityTTL: L<String>?, retry: L<Retry>?, cooldown: L<Cooldown>?
        enum CodingKeys: String, CodingKey {
            case strategy, retry, cooldown, forcePrefix = "force-model-prefix", affinity = "session-affinity", affinityTTL = "session-affinity-ttl"
        }
    }
    struct Logs: Decodable {
        var debug: L<Bool>?, toFile: L<Bool>?, requestLog: L<Bool>?, maxFiles: L<Int>?, maxSize: L<Int>?
        enum CodingKeys: String, CodingKey {
            case debug, toFile = "logging-to-file", requestLog = "request-log", maxFiles = "error-logs-max-files", maxSize = "logs-max-total-size-mb"
        }
    }
    struct Usage: Decodable { var enabled: L<Bool>?; enum CodingKeys: String, CodingKey { case enabled = "usage-statistics-enabled" } }
    struct Observability: Decodable { var logs: L<Logs>?, usage: L<Usage>? }
    struct Quota: Decodable {
        var project: L<Bool>?, preview: L<Bool>?
        enum CodingKeys: String, CodingKey { case project = "switch-project", preview = "switch-preview-model" }
    }
    struct Plugins: Decodable { var enabled: L<Bool>? }
    /// `api-keys` is a provider -> groups map in v8 and a flat client-key list before v8.
    enum APIKeys: Decodable {
        case groups([String: L<[Group]>]), flat([Presence]), none
        init(from d: Decoder) throws {
            if let g = try? d.singleValueContainer().decode([String: L<[Group]>].self) { self = .groups(g) }
            else if let f = try? d.singleValueContainer().decode([Presence].self) { self = .flat(f) }
            else { self = .none }
        }
    }

    var access: L<Access>?
    var management: L<Management>?
    var server: L<Server>?
    var requests: L<Requests>?
    var routing: L<Routing>?
    var observability: L<Observability>?
    var quota: L<Quota>?
    var plugins: L<Plugins>?
    var apiKeys: APIKeys?
    enum CodingKeys: String, CodingKey {
        case access, management, server, requests, routing, observability, plugins
        case quota = "quota-exceeded", apiKeys = "api-keys"
    }
}

struct Group: Decodable {
    struct Model: Decodable { var name: L<String>?, alias: L<String>? }
    struct Key: Decodable {
        var apiKey: MaskedKey?, weight: L<Double>?, proxyURL: MaskedURL?
        enum CodingKeys: String, CodingKey { case apiKey = "api-key", weight, proxyURL = "proxy-url" }
    }
    var name: L<String>?, baseURL: MaskedURL?, prefix: L<String>?, proxyURL: MaskedURL?
    var headers: L<[String: MaskedHeader]>?
    var models: L<[L<Model>]>?
    var excluded: L<[L<String>]>?
    var keys: L<[L<Key>]>?, entries: L<[L<Key>]>?
    var disabled: L<Bool>?
    enum CodingKeys: String, CodingKey {
        case name, prefix, headers, models, keys, disabled
        case baseURL = "base-url", proxyURL = "proxy-url", excluded = "excluded-models", entries = "api-key-entries"
    }
}

// MARK: - Public projections

public struct ProviderKeyView: Sendable, Equatable, Hashable {
    public var masked: String
    public var weight: Double?
    public var proxyURL: String?
}
public struct ProviderGroupView: Sendable, Equatable, Identifiable {
    public var id: String { "\(provider)#\(index)" }
    public var provider: String
    public var index: Int
    public var name: String
    public var baseURL: String
    public var prefix: String
    public var proxyURL: String?
    /// Header name and masked value.
    public var headers: [String: String]
    public var models: [(name: String, alias: String)]
    public var excludedModels: [String]
    public var keys: [ProviderKeyView]
    public var disabled: Bool
    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.baseURL == b.baseURL && a.keys == b.keys && a.headers == b.headers
            && a.models.map(\.name) == b.models.map(\.name) && a.models.map(\.alias) == b.models.map(\.alias)
            && a.excludedModels == b.excludedModels && a.disabled == b.disabled && a.prefix == b.prefix && a.proxyURL == b.proxyURL
    }
}

public struct ConfigSummary: Sendable, Equatable {
    /// Revision of this read; a write is refused when the hub's config no longer matches it.
    public var revision: String
    public var routingStrategy: String?
    public var forceModelPrefix: Bool?
    public var sessionAffinity: Bool?
    public var sessionAffinityTTL: String?
    public var requestRetry: Int?
    public var maxRetryInterval: Int?
    public var maxRetryCredentials: Int?
    public var disableCooling: Bool?
    public var saveCooldownStatus: Bool?
    public var transientErrorCooldown: Int?
    public var debug: Bool?
    public var loggingToFile: Bool?
    public var requestLog: Bool?
    public var errorLogsMaxFiles: Int?
    public var logsMaxTotalSizeMB: Int?
    public var usageStatistics: Bool?
    public var switchProject: Bool?
    public var switchPreviewModel: Bool?
    public var host: String?
    public var port: Int?
    public var tls: Bool?
    public var commercialMode: Bool?
    public var passthroughHeaders: Bool?
    public var keepaliveInterval: Int?
    /// Masked; nil when unset.
    public var proxyURL: String?
    public var pluginsEnabled: Bool?
    public var allowRemote: Bool?
    public var panelDisabled: Bool?
    public var managementKeySet: Bool
    public var clientKeys: Int
    public var providers: [ProviderGroupView]

    /// Current value of an editable setting; nil when the hub didn't report it.
    public func value(_ s: ConfigSetting) -> ConfigValue? {
        func b(_ v: Bool?) -> ConfigValue? { v.map(ConfigValue.bool) }
        func i(_ v: Int?) -> ConfigValue? { v.map(ConfigValue.int) }
        switch s {
        case .commercialMode: return b(commercialMode)
        case .plugins: return b(pluginsEnabled)
        case .passthroughHeaders: return b(passthroughHeaders)
        case .keepalive: return i(keepaliveInterval)
        case .strategy: return routingStrategy.map(ConfigValue.text)
        case .forceModelPrefix: return b(forceModelPrefix)
        case .sessionAffinity: return b(sessionAffinity)
        case .sessionAffinityTTL: return sessionAffinityTTL.map(ConfigValue.text)
        case .requestRetry: return i(requestRetry)
        case .maxRetryInterval: return i(maxRetryInterval)
        case .maxRetryCredentials: return i(maxRetryCredentials)
        case .disableCooling: return b(disableCooling)
        case .saveCooldownStatus: return b(saveCooldownStatus)
        case .transientErrorCooldown: return i(transientErrorCooldown)
        case .debug: return b(debug)
        case .loggingToFile: return b(loggingToFile)
        case .requestLog: return b(requestLog)
        case .errorLogsMaxFiles: return i(errorLogsMaxFiles)
        case .logsMaxTotalSizeMB: return i(logsMaxTotalSizeMB)
        case .usageStatistics: return b(usageStatistics)
        case .switchProject: return b(switchProject)
        case .switchPreviewModel: return b(switchPreviewModel)
        }
    }
}

/// Built-in channels with model definitions: Proxy Deck's KEY_PROVIDERS minus openai-compatibility and
/// interactions (the live 8.0.55 hub answers 400 for it).
public let modelChannels = ["claude", "codex", "gemini", "vertex", "xai", "meta"]

public struct ModelDefinition: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var context: Int?
}

extension ConfigSummary {
    init(data: Data) throws {
        guard let d = try? JSONDecoder().decode(ConfigDoc.self, from: data) else { throw ProxyError.incompatible }
        let r = d.routing?.v, logs = d.observability?.v?.logs?.v, mg = d.management?.v, sv = d.server?.v, rq = d.requests?.v
        let strategy = r?.strategy?.v?.trimmingCharacters(in: .whitespaces)
        var clientKeys = d.access?.v?.apiKeys?.v?.filter(\.set).count ?? 0
        var providers: [ProviderGroupView] = []
        switch d.apiKeys {
        case .flat(let f)?: if clientKeys == 0 { clientKeys = f.filter(\.set).count }
        case .groups(let g)?:
            for (p, list) in g.sorted(by: { $0.key < $1.key }) where p.range(of: #"^[a-z0-9-]{1,40}$"#, options: .regularExpression) != nil {
                for (i, grp) in (list.v ?? []).enumerated() { providers.append(.init(provider: p, index: i, grp)) }
            }
        default: break
        }
        let proxy = rq?.proxyURL?.v
        self.init(revision: Self.revision(data),
                  routingStrategy: strategy.flatMap { $0.range(of: #"^[a-z-]{1,32}$"#, options: .regularExpression) != nil ? $0 : nil },
                  forceModelPrefix: r?.forcePrefix?.v, sessionAffinity: r?.affinity?.v, sessionAffinityTTL: r?.affinityTTL?.v,
                  requestRetry: r?.retry?.v?.requestRetry?.v, maxRetryInterval: r?.retry?.v?.maxInterval?.v,
                  maxRetryCredentials: r?.retry?.v?.maxCredentials?.v,
                  disableCooling: r?.cooldown?.v?.disable?.v, saveCooldownStatus: r?.cooldown?.v?.save?.v,
                  transientErrorCooldown: r?.cooldown?.v?.transient?.v,
                  debug: logs?.debug?.v, loggingToFile: logs?.toFile?.v, requestLog: logs?.requestLog?.v,
                  errorLogsMaxFiles: logs?.maxFiles?.v, logsMaxTotalSizeMB: logs?.maxSize?.v,
                  usageStatistics: d.observability?.v?.usage?.v?.enabled?.v,
                  switchProject: d.quota?.v?.project?.v, switchPreviewModel: d.quota?.v?.preview?.v,
                  host: sv?.host?.v, port: sv?.port?.v, tls: sv?.tls?.v?.enable?.v, commercialMode: sv?.commercialMode?.v,
                  passthroughHeaders: rq?.passthrough?.v, keepaliveInterval: rq?.keepalive?.v,
                  proxyURL: (proxy?.isEmpty ?? true) ? nil : proxy,
                  pluginsEnabled: d.plugins?.v?.enabled?.v, allowRemote: mg?.allowRemote?.v, panelDisabled: mg?.disablePanel?.v,
                  managementKeySet: mg?.secretKey?.set ?? false, clientKeys: clientKeys, providers: providers)
    }

    /// Hash of the hub's exact answer. The hub serialises deterministically, so an unchanged config
    /// gives the same revision, and the raw body never has to be kept or fully decoded.
    static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension ProviderGroupView {
    init(provider: String, index: Int, _ g: Group) {
        let keys = (g.keys?.v ?? g.entries?.v ?? []).compactMap(\.v).compactMap { k -> ProviderKeyView? in
            guard let m = k.apiKey?.v else { return nil }
            return .init(masked: m, weight: k.weight?.v, proxyURL: k.proxyURL?.v)
        }
        self.init(provider: provider, index: index, name: g.name?.v ?? "", baseURL: g.baseURL?.v ?? "", prefix: g.prefix?.v ?? "",
                  proxyURL: g.proxyURL?.v, headers: (g.headers?.v ?? [:]).compactMapValues(\.v),
                  models: (g.models?.v ?? []).compactMap { m in m.v?.name?.v.map { ($0, m.v?.alias?.v ?? "") } },
                  excludedModels: (g.excluded?.v ?? []).compactMap(\.v), keys: keys, disabled: g.disabled?.v ?? false)
    }
}

extension ManagementClient {
    public func configSummary(key: String) async throws -> ConfigSummary {
        try ConfigSummary(data: try await send("GET", "v8/management/config", nil, key: key))
    }

    /// Re-reads the config and refuses when it changed since `revision` (Proxy Deck's checkRev), drops values
    /// equal to the current ones, then sends one nested merge patch of allowlisted, validated settings.
    public func applySettings(_ changes: [ConfigSetting: ConfigValue], revision: String, key: String) async throws {
        _ = try ConfigSetting.patch(changes) // validate before any request
        let current = try await send("GET", "v8/management/config", nil, key: key)
        guard ConfigSummary.revision(current) == revision else { throw ConfigError.stale }
        let summary = try ConfigSummary(data: current)
        let real = changes.filter { summary.value($0.key) != $0.value }
        guard !real.isEmpty else { throw ConfigError.nothingChanged }
        try await send("PATCH", "v8/management/config", try ConfigSetting.patch(real), key: key)
    }

    /// Proxy Deck's projectModels(): ids checked, at most 1000.
    public func modelDefinitions(channel: String, key: String) async throws -> [ModelDefinition] {
        guard modelChannels.contains(channel) else { throw ConfigError.invalidChannel }
        let data = try await send("GET", "v8/management/routing/model-definitions/\(channel)", nil, key: key)
        struct M: Decodable {
            var id: L<String>?, display_name: L<String>?, context_length: L<Double>?, inputTokenLimit: L<Double>?
        }
        struct Env: Decodable { var models: [L<M>] }
        guard let env = try? JSONDecoder().decode(Env.self, from: data) else { throw ProxyError.incompatible }
        return env.models.prefix(1000).compactMap(\.v).compactMap { m in
            guard let id = m.id?.v, id.range(of: #"^[A-Za-z0-9._:/@-]{1,120}$"#, options: .regularExpression) != nil else { return nil }
            let name = m.display_name?.v.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.count > 120 ? nil : $0 } ?? id
            let ctx = [m.context_length?.v, m.inputTokenLimit?.v].compactMap { $0 }.first { $0 > 0 && $0 < 1e12 }
            return ModelDefinition(id: id, name: name, context: ctx.map { Int($0) })
        }
    }
}
