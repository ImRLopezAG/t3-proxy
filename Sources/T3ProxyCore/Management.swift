import Foundation

/// Input checks that run before any request is sent.
public enum ManagementError: Error, Equatable {
    /// No key stored, or the last key was rejected: nothing is sent until the key changes.
    case locked
    case invalidName
    case invalidPriority
    case nicknameTooLong
    /// The credential is no longer listed by the hub.
    case notFound
    /// The hub answered but reported a failed refresh.
    case refreshFailed
}

public enum CredentialStatus: String, Sendable, Equatable { case healthy, cooling, disabled, error }

/// One `/v8/management/credentials` entry, reduced to what the Accounts pane shows.
public struct Credential: Sendable, Identifiable, Equatable {
    public var id: String { name }
    /// File name on the hub, e.g. `claude-a.json`. Used as the write key.
    public var name: String
    public var provider: Provider
    /// The hub's provider word (e.g. `xai`), for providers without a mark.
    public var providerName: String
    public var nickname: String?
    /// Raw plan word (`pro`, `max 20x`); see `planLabel`.
    public var plan: String?
    /// Organization or workspace name, when known (from the plan cache).
    public var org: String?
    public var priority: Int
    public var disabled: Bool
    public var runtimeOnly: Bool
    public var status: CredentialStatus
    public var reason: String?
    /// Earliest cooldown release.
    public var retryAt: Date?
    public var lastRefresh: Date?
    public var updatedMarker: String?
    public var authIndex: String?
    public var chatgptAccountID: String?
    /// Proxy Deck's opaque account key (plan cache lookups); nil without an auth index.
    public var accountKey: String? { authIndex.map(PlanCache.accountKey) }

    /// Fills plan/org from the cache. The hub's own plan (Codex id_token) wins over the cache.
    public func with(_ info: PlanInfo?) -> Credential {
        guard let info else { return self }
        var c = self
        if c.plan == nil { c.plan = info.plan }
        c.org = info.org
        return c
    }

    public init(name: String, provider: Provider, providerName: String? = nil, nickname: String? = nil, plan: String? = nil,
                priority: Int = 0, disabled: Bool = false, runtimeOnly: Bool = false, status: CredentialStatus = .healthy,
                reason: String? = nil, retryAt: Date? = nil, lastRefresh: Date? = nil) {
        self.name = name; self.provider = provider; self.providerName = providerName ?? provider.rawValue
        self.nickname = nickname; self.plan = plan; self.priority = priority; self.disabled = disabled
        self.runtimeOnly = runtimeOnly; self.status = status; self.reason = reason; self.retryAt = retryAt
        self.lastRefresh = lastRefresh
    }

    /// Nickname, else the file name without `.json`.
    public var label: String { nickname ?? (name.hasSuffix(".json") ? String(name.dropLast(5)) : name) }

    /// "max 20x" -> "Max 20x", "pro" -> "Pro" (Proxy Deck's planParts).
    public var planLabel: String? {
        guard let p = plan?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        var words = p, times: String?
        if let r = p.range(of: #"\s*\d{1,3}x$"#, options: [.regularExpression, .caseInsensitive]) {
            times = p[r].trimmingCharacters(in: .whitespaces).lowercased(); words = String(p[..<r.lowerBound])
        }
        if words.isEmpty { words = "max" }
        let name = words.replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression).capitalized
        return times.map { "\(name) \($0)" } ?? name
    }
}

/// Allowlist decode. `path`, `email`, `label`, `account`, `id`, tokens and quota payloads are never decoded;
/// from `id_token` (already-parsed claims) only `plan_type` and `chatgpt_account_id` are read.
struct CredentialEntry: Decodable {
    var name: String?
    var provider: String?
    var type: String?
    var note: String?
    var plan_type: String?
    var plan: String?
    var id_token: Claims?
    var priority: Double?
    var disabled: Bool?
    var unavailable: Bool?
    var runtime_only: Bool?
    var status: String?
    var status_message: String?
    var cooldowns: [Cooldown]?
    var last_refresh: String?
    var auth_index: String?
    var updated_at: String?
    struct Claims: Decodable { var plan_type: String?; var chatgpt_account_id: String? }
    struct Cooldown: Decodable { var scope: String?; var retry_at: String? }

    // Tolerate type drift in optional fields: one odd value must not fail the whole list.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        func b(_ k: CodingKeys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: k) }
        name = s(.name); provider = s(.provider); type = s(.type); note = s(.note)
        plan_type = s(.plan_type); plan = s(.plan); status = s(.status); status_message = s(.status_message)
        last_refresh = s(.last_refresh); auth_index = s(.auth_index); updated_at = s(.updated_at)
        id_token = try? c.decodeIfPresent(Claims.self, forKey: .id_token)
        priority = (try? c.decodeIfPresent(Double.self, forKey: .priority)) ?? s(.priority).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        disabled = b(.disabled); unavailable = b(.unavailable); runtime_only = b(.runtime_only)
        cooldowns = try? c.decodeIfPresent([Cooldown].self, forKey: .cooldowns)
    }
    enum CodingKeys: String, CodingKey {
        case name, provider, type, note, plan_type, plan, id_token, priority, disabled, unavailable, runtime_only
        case status, status_message, cooldowns, last_refresh, auth_index, updated_at
    }
}
struct CredentialsEnvelope: Decodable { var files: [CredentialEntry] }

public enum ManagementRules {
    public static let priorityRange = -100...100
    public static let nicknameMax = 60
    private static let safeName = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,199}$"#)

    /// Proxy Deck's fileName(): SAFE_NAME, no "..", ends with ".json", at least 6 characters.
    public static func isValidFileName(_ n: String) -> Bool {
        n.utf16.count >= 6 && n.hasSuffix(".json") && !n.contains("..")
            && safeName.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }
    static func isSafeName(_ n: String) -> Bool {
        !n.contains("..") && safeName.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }

    /// Proxy Deck's nicknameOf(): control/bidi characters dropped, whitespace collapsed, trimmed. Empty -> nil.
    public static func cleanNickname(_ v: String?, max: Int = .max) -> String? {
        guard let v else { return nil }
        let stripped = String(String.UnicodeScalarView(v.unicodeScalars.filter { u in
            let x = u.value
            return !(x <= 0x1f || (0x7f...0x9f).contains(x) || (0x200b...0x200f).contains(x)
                     || (0x2028...0x202e).contains(x) || (0x2066...0x2069).contains(x))
        }))
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let capped = String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }
}

extension Credential {
    init?(_ e: CredentialEntry) {
        guard let name = e.name, ManagementRules.isSafeName(name) else { return nil }
        let raw = (e.provider ?? e.type ?? "unknown").lowercased()
        let st = (e.status ?? "").lowercased()
        let message = e.status_message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = message.flatMap { $0.isEmpty ? nil : classifyHubMessage($0) }
        let retry = (e.cooldowns ?? []).filter { $0.scope == "model" || $0.scope == "credential" }
            .compactMap { $0.retry_at.flatMap(Account.parseDate) }.min()
        let status: CredentialStatus, reason: String?
        if e.disabled == true || st == "disabled" { status = .disabled; reason = "Disabled in the hub" }
        else if st == "error" { status = .error; reason = note ?? "Error" }
        else if e.unavailable == true { status = .error; reason = note ?? "Paused by the hub" }
        else if retry != nil { status = .cooling; reason = "Cooling down after recent errors" }
        else { status = .healthy; reason = nil }
        let plan = e.plan_type ?? e.plan ?? e.id_token?.plan_type
        let p = e.priority.flatMap { $0.isFinite && abs($0) <= 1_000_000 && $0 == $0.rounded() && ManagementRules.priorityRange.contains(Int($0)) ? Int($0) : nil } ?? 0
        self.init(name: name, provider: Provider(raw: raw),
                  providerName: raw.range(of: #"^[a-z0-9-]{1,32}$"#, options: .regularExpression) != nil ? raw : "unknown",
                  nickname: ManagementRules.cleanNickname(e.note, max: ManagementRules.nicknameMax),
                  plan: plan.flatMap { $0.range(of: #"^[A-Za-z0-9 _-]{1,32}$"#, options: .regularExpression) != nil ? $0 : nil },
                  priority: p, disabled: status == .disabled, runtimeOnly: e.runtime_only == true,
                  status: status, reason: reason, retryAt: retry, lastRefresh: e.last_refresh.flatMap(Account.parseDate))
        updatedMarker = e.updated_at.flatMap { $0.count <= 64 && Account.parseDate($0) != nil ? $0 : nil }
        authIndex = e.auth_index
        chatgptAccountID = e.id_token?.chatgpt_account_id
    }
}

/// Fixed v8 credential routes on loopback. There is no generic method or path.
/// Callers must go through `Monitor.management(_:)`, which owns the key and the rejected-key lock.
public struct ManagementClient: Sendable {
    public let endpoint: ProxyEndpoint
    let session: URLSession
    /// Checked before every request, including the second step of a cooldown reset.
    public var gate = AuthGate()

    public init(endpoint: ProxyEndpoint = .configured(), protocolClasses: [AnyClass]? = nil) {
        self.endpoint = endpoint
        session = loopbackSession(timeout: 30, protocolClasses: protocolClasses)
    }

    public func credentials(key: String) async throws -> [Credential] {
        try await entries(key: key).compactMap(Credential.init).sorted { $0.name < $1.name }
    }

    public func setNickname(_ nickname: String, name: String, key: String) async throws {
        try checkName(name)
        guard nickname.utf16.count <= 400 else { throw ManagementError.nicknameTooLong }
        let clean = ManagementRules.cleanNickname(nickname) ?? ""
        guard clean.unicodeScalars.count <= ManagementRules.nicknameMax else { throw ManagementError.nicknameTooLong }
        try await send("PATCH", "v8/management/credentials/fields", ["name": name, "note": clean], key: key)
    }

    public func setPriority(_ priority: Int, name: String, key: String) async throws {
        try checkName(name)
        guard ManagementRules.priorityRange.contains(priority) else { throw ManagementError.invalidPriority }
        try await send("PATCH", "v8/management/credentials/fields", ["name": name, "priority": priority], key: key)
    }

    public func setDisabled(_ disabled: Bool, name: String, key: String) async throws {
        try checkName(name)
        try await send("PATCH", "v8/management/credentials/status", ["name": name, "disabled": disabled], key: key)
    }

    /// Looks up the credential's current `auth_index` (as Proxy Deck does), then resets its cooldown.
    public func resetCooldown(name: String, key: String) async throws {
        try checkName(name)
        guard let index = try await entries(key: key).first(where: { $0.name == name })?.auth_index, !index.isEmpty
        else { throw ManagementError.notFound }
        try await send("POST", "v8/management/routing/cooldown/reset", ["auth_index": index], key: key)
    }

    public func refresh(name: String, key: String) async throws {
        try checkName(name)
        let data = try await send("POST", "v8/management/credentials/refresh", ["name": name], key: key, timeout: 300)
        struct R: Decodable { var ok: Bool?; var results: [Item]?; struct Item: Decodable { var success: Bool? } }
        if let r = try? JSONDecoder().decode(R.self, from: data),
           r.ok == false || (r.results ?? []).contains(where: { $0.success == false }) { throw ManagementError.refreshFailed }
    }

    // MARK: -

    func checkName(_ n: String) throws { guard ManagementRules.isValidFileName(n) else { throw ManagementError.invalidName } }

    func entries(key: String) async throws -> [CredentialEntry] {
        let data = try await send("GET", "v8/management/credentials", nil, key: key)
        guard let env = try? JSONDecoder().decode(CredentialsEnvelope.self, from: data) else { throw ProxyError.incompatible }
        return env.files
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ body: [String: any Sendable]?, key: String,
                      timeout: TimeInterval = 30) async throws -> Data {
        guard gate.permits(key) else { throw ManagementError.locked }
        var r = URLRequest(url: endpoint.base.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw ProxyError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard (200..<300).contains(code) else { throw ProxyError.http(code) }
        return data
    }
}
