import Foundation
import CoreFoundation

public enum QuotaSource: String, Sendable { case recorded, live }

/// Only this claim is retained; tokens and other identity claims are never decoded.
public struct LiveAccountClaims: Decodable, Sendable, Equatable {
    public var chatgpt_account_id: String?
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            chatgpt_account_id = nil; return
        }
        chatgpt_account_id = try? c.decode(String.self, forKey: .chatgpt_account_id)
    }
    private enum CodingKeys: String, CodingKey { case chatgpt_account_id }
}

public struct LiveCredits: Sendable, Equatable {
    public var balance: Double?
    public var limit: Double?
    public var remaining: Double?
    public var hasCredits: Bool?
    public var unlimited: Bool?
}

public enum LiveQuotaError: Error, Sendable, Equatable {
    case invalidAccount, invalidResponse, responseTooLarge, upstream(Int), invalidCredit
}

/// Closed route set. No caller-provided URL, HTTP method, headers or arbitrary body.
public enum LiveQuotaTarget: CaseIterable, Sendable {
    case claudeUsage, claudeProfile, codexUsage, codexAccounts, codexCredits, codexConsume
    public var provider: Provider {
        self == .claudeUsage || self == .claudeProfile ? .claude : .codex
    }
    public var url: String {
        switch self {
        // Claude omits reset grants unless explicitly requested. Keep spend in this same reading.
        case .claudeUsage: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1"
        case .claudeProfile: "https://api.anthropic.com/api/oauth/profile"
        case .codexUsage: "https://chatgpt.com/backend-api/wham/usage"
        case .codexAccounts: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27"
        case .codexCredits: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        case .codexConsume: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"
        }
    }
    public var method: String { self == .codexConsume ? "POST" : "GET" }
    func headers(accountID: String?) throws -> [String: String] {
        var h = ["Authorization": "Bearer $TOKEN$", "User-Agent": provider == .claude
                 ? "claude-cli/2.1.325 (external, cli)" : "codex-tui/0.149.1"]
        if provider == .claude { h["anthropic-beta"] = "oauth-2025-04-20" }
        if [.codexUsage, .codexCredits, .codexConsume].contains(self) {
            h["Content-Type"] = "application/json"; h["OpenAI-Beta"] = "codex-1"; h["Originator"] = "Codex Desktop"
        }
        if provider == .codex, let accountID {
            guard accountID.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil else {
                throw LiveQuotaError.invalidAccount
            }
            h["Chatgpt-Account-Id"] = accountID
        }
        return h
    }
}

extension ManagementClient {
    /// Reads one fixed target; consume is deliberately unavailable through this read API.
    public func liveQuotaRead(_ target: LiveQuotaTarget, account: Account, key: String, allowDisabledCodex: Bool = false) async throws -> Data {
        guard target != .codexConsume else { throw LiveQuotaError.invalidCredit }
        return try await quotaCall(target, account: account, confirmation: nil, key: key, allowDisabledCodex: allowDisabledCodex)
    }

    fileprivate func quotaCall(_ target: LiveQuotaTarget, account: Account,
                               confirmation: ConfirmedResetCredit?, key: String, allowDisabledCodex: Bool = false) async throws -> Data {
        let disabledReset = target == .codexConsume && confirmation?.routingDisabled == true
        let disabledRead = allowDisabledCodex && [.codexUsage, .codexCredits].contains(target)
        guard (!account.disabled || disabledReset || disabledRead), account.provider == target.provider,
              let index = account.authIndex, !index.isEmpty, index.utf8.count <= 256,
              !index.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LiveQuotaError.invalidAccount
        }
        var body: [String: any Sendable] = ["authIndex": index, "method": target.method, "url": target.url,
                                            "header": try target.headers(accountID: account.chatgptAccountID)]
        if target == .codexConsume {
            guard let confirmation, confirmation.accountIndex == index,
                  confirmation.accountName == account.name, confirmation.routingDisabled == account.disabled, validCreditID(confirmation.creditID) else {
                throw LiveQuotaError.invalidCredit
            }
            let payload = ["credit_id": confirmation.creditID, "redeem_request_id": confirmation.requestID.uuidString.lowercased()]
            body["data"] = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        }
        let raw = try await send("POST", "v0/management/api-call", body, key: key)
        return try quotaBody(raw)
    }

    fileprivate func quotaBody(_ raw: Data) throws -> Data {
        let envelope = try LiveQuotaParser.object(raw)
        guard let code = liveNumber(envelope["status_code"]), code.rounded() == code,
              (100...599).contains(code) else { throw LiveQuotaError.invalidResponse }
        guard (200..<300).contains(code) else { throw LiveQuotaError.upstream(Int(code)) }
        let data: Data
        if let s = envelope["body"] as? String { data = Data(s.utf8) }
        else if let o = envelope["body"] as? [String: Any], JSONSerialization.isValidJSONObject(o) {
            data = try JSONSerialization.data(withJSONObject: o)
        } else { throw LiveQuotaError.invalidResponse }
        _ = try LiveQuotaParser.object(data)
        return data
    }

    fileprivate func clearLiveQuotaCooldown(account: Account, key: String) async throws {
        guard [.codex, .claude].contains(account.provider), !account.disabled, let index = account.authIndex, !index.isEmpty else {
            throw LiveQuotaError.invalidAccount
        }
        try await send("POST", "v0/management/reset-quota", ["auth_index": index], key: key)
    }
}

private func liveNumber(_ v: Any?) -> Double? {
    if let n = v as? NSNumber {
        guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return finiteNumber(n.stringValue)
    }
    return (v as? String).flatMap(finiteNumber)
}
private func liveBool(_ v: Any?) -> Bool? {
    guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
private func livePercent(_ v: Any?) -> Double? { liveNumber(v).map { min(100, max(0, $0)) } }
private func liveDate(_ v: Any?) -> Date? {
    let d: Date?
    if let s = v as? String { d = parseHubTime(s) }
    else { d = liveNumber(v).flatMap { parseHubTime(String($0)) } }
    // Avoid dates outside a useful provider lifetime (2000...2100).
    return d.flatMap { (946_684_800...4_102_444_800).contains($0.timeIntervalSince1970) ? $0 : nil }
}
private func liveLabel(_ v: Any?) -> String? {
    guard let s = v as? String, !s.contains("@") else { return nil }
    return ManagementRules.cleanNickname(s, max: 64)
}
private func slug(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
private func allowedPlan(_ v: Any?) -> String? {
    guard let s = v as? String else { return nil }
    let p = s.lowercased().replacingOccurrences(of: "_", with: " ")
    return PlanCache.isPlan(p) ? p : nil
}

public enum LiveQuotaParser {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes else { throw LiveQuotaError.responseTooLarge }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LiveQuotaError.invalidResponse
        }
        return o
    }

    public static func usage(_ data: Data, provider: Provider, now: Date = Date()) throws -> QuotaReading {
        let o = try object(data)
        var q = QuotaReading(observedAt: now, windows: [], models: [:], plan: nil)
        q.source = .live
        switch provider {
        case .claude:
            q.claudeResets = claudeResets(o["cedar_ember"])
            q.availableResetCredits = q.claudeResets?.remaining(at: now)
            for (key, id, title) in [("five_hour", "five-hour", "5-hour session"), ("seven_day", "seven-day", "Weekly"),
                                      ("seven_day_opus", "seven-day-opus", "Weekly · Opus"),
                                      ("seven_day_sonnet", "seven-day-sonnet", "Weekly · Sonnet"),
                                      ("seven_day_oauth_apps", "seven-day-oauth-apps", "Weekly · OAuth apps"),
                                      ("seven_day_cowork", "seven-day-cowork", "Weekly · Cowork")] {
                if let w = o[key] as? [String: Any] {
                    q.windows.append(.init(id: id, label: title, usedPercent: livePercent(w["utilization"]), resetAt: liveDate(w["resets_at"])))
                }
            }
            for l in o["limits"] as? [[String: Any]] ?? [] where l["kind"] as? String == "weekly_scoped" {
                let scope = l["scope"] as? [String: Any]
                guard let model = scope?["model"] as? [String: Any], let name = liveLabel(model["display_name"]), !slug(name).isEmpty else { continue }
                let id = "seven-day-" + slug(name)
                if !q.windows.contains(where: { $0.id == id }) {
                    q.windows.append(.init(id: id, label: "Weekly · " + name, usedPercent: livePercent(l["percent"]), resetAt: liveDate(l["resets_at"])))
                }
            }
            if let pool = o["iguana_necktie"] as? [String: Any] {
                q.credits = LiveCredits(balance: nil, limit: liveNumber(pool["limit_dollars"]), remaining: liveNumber(pool["remaining_dollars"]))
                q.windows.append(.init(id: "credit-pool", label: "Credit pool", usedPercent: livePercent(pool["utilization"]), resetAt: liveDate(pool["resets_at"])))
            }
            if let extra = o["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool != false {
                q.windows.append(.init(id: "extra-usage", label: "Extra usage", usedPercent: livePercent(extra["utilization"]), resetAt: liveDate(extra["resets_at"])))
                if q.credits == nil {
                    let limit = liveNumber(extra["monthly_limit"]), used = liveNumber(extra["used_credits"])
                    q.credits = LiveCredits(balance: used, limit: limit, remaining: limit.flatMap { l in used.map { max(0, l - $0) } })
                }
            }
        case .codex:
            q.windows = codexWindows(o["rate_limit"], prefix: nil, now: now)
                + codexWindows(o["code_review_rate_limit"], prefix: "Code review", now: now)
            for e in o["additional_rate_limits"] as? [[String: Any]] ?? [] {
                let name = liveLabel(e["limit_name"]) ?? liveLabel(e["metered_feature"]) ?? "Additional limit"
                q.windows += codexWindows(e["rate_limit"], prefix: name, now: now)
            }
            if let c = o["credits"] as? [String: Any] {
                q.credits = LiveCredits(balance: liveNumber(c["balance"]), hasCredits: c["has_credits"] as? Bool, unlimited: c["unlimited"] as? Bool)
            }
            if let c = o["rate_limit_reset_credits"] as? [String: Any], let n = liveNumber(c["available_count"]), n >= 0 {
                q.availableResetCredits = Int(n.rounded(.down))
            }
            q.plan = allowedPlan(o["plan_type"])
        case .other: throw LiveQuotaError.invalidAccount
        }
        return q
    }

    private static func codexWindows(_ value: Any?, prefix: String?, now: Date) -> [QuotaWindow] {
        guard let l = value as? [String: Any] else { return [] }
        return ["primary_window", "secondary_window"].compactMap { slot in
            guard let w = l[slot] as? [String: Any] else { return nil }
            let seconds = liveNumber(w["limit_window_seconds"])
            if let seconds, seconds <= 0 { return nil }
            let id: String, title: String
            switch seconds {
            case 18000: (id, title) = ("five-hour", "5-hour session")
            case 604800: (id, title) = ("weekly", "Weekly")
            case .some(let n) where (28 * 86400...31 * 86400).contains(n): (id, title) = ("monthly", "Monthly")
            case .some(let n): (id, title) = ("\(Int(n / 60))-minute", "\(Int(n / 60))-minute")
            case nil: (id, title) = (slot == "primary_window" ? "primary" : "secondary", slot == "primary_window" ? "Primary window" : "Secondary window")
            }
            let after = liveNumber(w["reset_after_seconds"])
            let reset = liveDate(w["reset_at"]) ?? after.flatMap { a in
                a >= 0 && a <= 366 * 86400 ? liveDate(now.addingTimeInterval(a).timeIntervalSince1970) : nil
            }
            return QuotaWindow(id: prefix.map { slug($0) + "-" + id } ?? id,
                               label: prefix.map { $0 + " · " + title } ?? title,
                               usedPercent: livePercent(w["used_percent"]), resetAt: reset, duration: seconds)
        }
    }

    public static func plan(_ data: Data, provider: Provider, accountID: String? = nil) throws -> PlanInfo {
        let o = try object(data)
        if provider == .claude {
            let org = o["organization"] as? [String: Any] ?? [:], account = o["account"] as? [String: Any] ?? [:]
            let type = (org["organization_type"] as? String ?? "").lowercased()
            var plan: String?
            switch type {
            case "claude_team": plan = (org["seat_tier"] as? String ?? "").lowercased().contains("premium") ? "team premium" : "team"
            case "claude_enterprise": plan = "enterprise"
            case "claude_pro": plan = "pro"
            case "claude_max": plan = "max"
            case "": plan = account["has_claude_max"] as? Bool == true ? "max" : account["has_claude_pro"] as? Bool == true ? "pro" : nil
            default: break
            }
            if plan == "max", let tier = org["rate_limit_tier"] as? String,
               let match = tier.lowercased().firstMatch(of: /max_([1-9]\d?)x/) { plan = "max \(match.1)x" }
            return PlanInfo(plan: allowedPlan(plan), org: ["claude_team", "claude_enterprise"].contains(type) ? PlanCache.cleanOrg(org["name"] as? String) : nil,
                            orgID: PlanCache.orgFingerprint(org["uuid"] as? String))
        }
        guard provider == .codex, let accountID, let all = o["accounts"] as? [String: Any],
              let entry = all[accountID] as? [String: Any], let a = entry["account"] as? [String: Any] else { return PlanInfo(plan: nil, org: nil) }
        return PlanInfo(plan: allowedPlan(a["plan_type"]), org: a["structure"] as? String == "workspace" ? PlanCache.cleanOrg(a["name"] as? String) : nil)
    }
}

public enum ClaudeResetKind: String, Sendable, CaseIterable {
    case fable, weekly, session, full, other
    public var title: String {
        switch self {
        case .fable: "Fable reset"
        case .weekly: "Weekly reset"
        case .session: "5-hour reset"
        case .full: "Full reset"
        case .other: "Reset"
        }
    }
}

/// Claude grants stay separate from Codex credits and their redemption flow.
public struct ClaudeResetGrant: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ClaudeResetKind
    public let resetsLeft: Int
    public let startsAt: Date?
    public let expiresAt: Date?
    public let paused: Bool
    public let usableNow: Bool
    public let givesBackWeekly: Bool
    public let clears: [String]

    public func isUnexpired(at now: Date) -> Bool {
        resetsLeft > 0 && expiresAt.map { $0 > now } != false && startsAt.map { $0 <= now } != false
    }
}

public struct ClaudeResetStatus: Sendable, Equatable {
    public let eligible: Bool
    public let grants: [ClaudeResetGrant]
    public let cooldownUntil: Date?
    public func canUse(_ grant: ClaudeResetGrant, at now: Date) -> Bool {
        eligible && cooldownUntil.map { $0 <= now } != false && grants.contains(grant)
            && grant.isUnexpired(at: now) && !grant.paused && grant.usableNow
    }
    public func remaining(at now: Date) -> Int {
        grants.filter { $0.isUnexpired(at: now) }.reduce(0) { $0 + $1.resetsLeft }
    }
}

extension LiveQuotaParser {
    /// Schema verified against Claude CLI 2.1.325 and live OAuth usage responses.
    /// Missing or malformed grants are unknown, never an invented zero balance.
    private static func claudeResets(_ value: Any?) -> ClaudeResetStatus? {
        guard let status = value as? [String: Any], let eligible = liveBool(status["eligible"]),
              let raw = status["grants"] as? [[String: Any]], raw.count <= 1000 else { return nil }
        var seen = Set<String>(), grants: [ClaudeResetGrant] = []
        for g in raw {
            guard let id = g["id"] as? String, validCreditID(id), seen.insert(id).inserted,
                  let n = liveNumber(g["resets_left"]), n >= 0, n <= 1_000_000, n.rounded() == n,
                  let clears = g["clears"] as? [String], clears.count <= 64,
                  clears.allSatisfy({ $0.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil }) else { return nil }
            let start = liveDate(g["starts_at"]), expiry = liveDate(g["ends_at"])
            if let v = g["starts_at"], !(v is NSNull), start == nil { return nil }
            if let v = g["ends_at"], !(v is NSNull), expiry == nil { return nil }
            let givesBack = liveBool(g["gives_back_weekly"]) ?? false
            let kind: ClaudeResetKind
            // Claude's CLI classifies gives_back_weekly grants as Fable even when type is "full".
            if givesBack { kind = .fable }
            else if let type = g["type"] as? String {
                kind = ClaudeResetKind(rawValue: type).flatMap { $0 == .fable ? nil : $0 } ?? .other
            } else {
                let session = clears.contains("five_hour"), weekly = clears.contains { $0 != "five_hour" }
                kind = session && weekly ? .full : session ? .session : weekly ? .weekly : .other
            }
            let label = (g["label"] as? String).flatMap { $0.contains("@") ? nil : ManagementRules.cleanNickname($0, max: 160) }
            grants.append(ClaudeResetGrant(id: id, title: label ?? kind.title, kind: kind, resetsLeft: Int(n),
                                          startsAt: start, expiresAt: expiry, paused: liveBool(g["paused"]) ?? (g["paused"] != nil),
                                          usableNow: liveBool(g["usable_now"]) ?? false, givesBackWeekly: givesBack, clears: clears))
        }
        let cooldown = liveDate(status["cooldown_until"])
        if let value = status["cooldown_until"], !(value is NSNull), cooldown == nil { return nil }
        // Claude's CLI selects the first usable grant of each kind in provider order.
        return ClaudeResetStatus(eligible: eligible, grants: grants, cooldownUntil: cooldown)
    }
}

/// Prepared by fresh reads of the same credential's grants and OAuth organization.
public struct ClaudeResetConfirmation: Sendable, Equatable {
    public let grant: ClaudeResetGrant
    public let requestID: UUID
    fileprivate let organization: UUID
    fileprivate let accountIndex: String
    fileprivate let accountName: String
    fileprivate let keyEpoch: Int
    public func confirm() -> ConfirmedClaudeReset { ConfirmedClaudeReset(value: self) }
}

public struct ConfirmedClaudeReset: Sendable {
    fileprivate let value: ClaudeResetConfirmation
    public var requestID: UUID { value.requestID }
}

public enum ClaudeResetResult: String, Sendable {
    case reset, alreadyUsed = "already_used", notLimited = "not_limited", cooldown, ineligible, unavailable, unconfirmed
}

extension ManagementClient {
    fileprivate func claimClaudeReset(account: Account, confirmed: ConfirmedClaudeReset, key: String) async throws -> Data {
        let c = confirmed.value
        guard account.provider == .claude, !account.disabled, account.authIndex == c.accountIndex,
              account.name == c.accountName else { throw LiveQuotaError.invalidCredit }
        let url = "https://api.anthropic.com/api/organizations/\(c.organization.uuidString.lowercased())/reset_rate_limits"
        var headers = try LiveQuotaTarget.claudeUsage.headers(accountID: nil)
        headers["Content-Type"] = "application/json"
        let payload = ["program": "cedar_ember", "grant_id": c.grant.id, "request_id": c.requestID.uuidString.lowercased()]
        let body: [String: any Sendable] = ["authIndex": c.accountIndex, "method": "POST", "url": url, "header": headers,
            "data": String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)]
        return try quotaBody(await send("POST", "v0/management/api-call", body, key: key))
    }
}

private func validCreditID(_ id: String) -> Bool {
    id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil
}

public struct ResetCredit: Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String
    public let title: String
    public let expiresAt: Date?
    public let grantedAt: Date?
    // No public initializer: credits must come from the validated list.
    fileprivate init(id: String, title: String, expiresAt: Date?, grantedAt: Date?) {
        self.id = id; status = "available"; self.title = title; self.expiresAt = expiresAt; self.grantedAt = grantedAt
    }
}

extension LiveQuotaParser {
    public static func resetCredits(_ data: Data, now: Date = Date()) throws -> [ResetCredit] {
        let o = try object(data)
        guard let list = o["credits"] as? [Any] else { throw LiveQuotaError.invalidResponse }
        var seen = Set<String>()
        return list.compactMap { value -> ResetCredit? in
            guard let c = value as? [String: Any], let id = c["id"] as? String, validCreditID(id),
                  c["status"] as? String == "available", seen.insert(id).inserted else { return nil }
            let expiry = liveDate(c["expires_at"])
            // A malformed explicit expiry cannot become a never-expiring grant.
            if let v = c["expires_at"], !(v is NSNull), expiry == nil { return nil }
            if let expiry, expiry <= now { return nil }
            return ResetCredit(id: id, title: liveLabel(c["title"]) ?? "Rate limit reset", expiresAt: expiry, grantedAt: liveDate(c["granted_at"]))
        }.sorted { a, b in
            let x = a.expiresAt ?? .distantFuture, y = b.expiresAt ?? .distantFuture
            return x == y ? a.id < b.id : x < y
        }
    }
}

/// Prepare when presenting the button; retain the store for the interaction and reuse on retry.
@MainActor public final class ResetCreditConfirmationStore {
    private var requests: [String: [String: UUID]] = [:]
    public init() {}
    public func prepare(credit: ResetCredit, account: Account, allowDisabled: Bool = false) throws -> ResetCreditConfirmation {
        guard (!account.disabled || allowDisabled), account.provider == .codex, let index = account.authIndex, !index.isEmpty,
              validCreditID(credit.id) else { throw LiveQuotaError.invalidCredit }
        let scope = index + "\u{0}" + account.name
        let request = requests[scope]?[credit.id] ?? UUID()
        requests[scope, default: [:]][credit.id] = request
        return ResetCreditConfirmation(routingDisabled: account.disabled, accountIndex: index, accountName: account.name, creditID: credit.id, requestID: request)
    }
}
public struct ResetCreditConfirmation: Sendable {
    fileprivate let routingDisabled: Bool
    fileprivate let accountIndex: String
    fileprivate let accountName: String
    fileprivate let creditID: String
    public let requestID: UUID
    /// Invoke only after the user's deliberate confirmation. Refresh never calls this.
    public func confirm() -> ConfirmedResetCredit {
        ConfirmedResetCredit(routingDisabled: routingDisabled, accountIndex: accountIndex, accountName: accountName, creditID: creditID, requestID: requestID)
    }
}
public struct ConfirmedResetCredit: Sendable {
    /// Present a fresh deliberate confirmation after routing changes, keeping the uncertain request pinned.
    public func prepareRetry(account: Account) throws -> ResetCreditConfirmation {
        guard account.provider == .codex, account.authIndex == accountIndex, account.name == accountName else {
            throw LiveQuotaError.invalidCredit
        }
        return ResetCreditConfirmation(routingDisabled: account.disabled, accountIndex: accountIndex,
                                       accountName: accountName, creditID: creditID, requestID: requestID)
    }
    fileprivate let routingDisabled: Bool
    fileprivate let accountIndex: String
    fileprivate let accountName: String
    fileprivate let creditID: String
    public let requestID: UUID
}
public enum ResetCreditResult: Sendable, Equatable {
    case reset(windows: Int), alreadyRedeemed, nothingToReset, noCredit, failed
}

/// Retain one instance per launch. All outbound calls use Monitor.management and its AuthGate.
@MainActor public final class LiveQuotaService {
    private let monitor: Monitor
    private let clock: @Sendable () -> Date
    private var cache: [String: QuotaReading] = [:]
    private var lastRead: [String: Date] = [:]
    /// Last profile read attempt and whether it succeeded: re-read every 6 hours, or 15 minutes after a failure.
    private var planRead: [String: (at: Date, ok: Bool)] = [:]
    private var pending: [String: Task<QuotaReading?, Never>] = [:]
    private var generations: [String: Int] = [:]
    private var accountPlans: [String: PlanInfo] = [:]
    public private(set) var plans: [String: PlanInfo] = [:]
    /// A successful claim remains a success even if clearing the separate hub cooldown fails.
    public private(set) var cooldownClearFailed = Set<String>()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(monitor: Monitor, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.monitor = monitor; self.clock = clock
    }
    private func identity(_ a: Account) -> String { a.provider.rawValue + ":" + (a.authIndex ?? "") + ":" + (a.chatgptAccountID ?? "") }

    /// The plan learned from this credential's own profile read, and when it was read. Keyed by provider,
    /// auth index and ChatGPT account id, so it can't belong to another or replaced credential.
    public func verifiedPlan(provider: Provider, authIndex: String, chatgptAccountID: String?) -> (plan: String, readAt: Date)? {
        let id = provider.rawValue + ":" + authIndex + ":" + (chatgptAccountID ?? "")
        guard !authIndex.isEmpty, let plan = accountPlans[id]?.plan, let read = planRead[id], read.ok else { return nil }
        return (plan, read.at)
    }
    private func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
    private func read(_ target: LiveQuotaTarget, account: Account) async throws -> Data {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        if target == .claudeUsage || target == .codexUsage { lastRead[identity(account)] = clock() }
        return try await monitor.management { try await $0.liveQuotaRead(target, account: account, key: $1, allowDisabledCodex: account.provider == .codex) }
    }

    /// Map keyed by Account.id; failed reads retain the last good live reading (or are omitted).
    public func refresh(_ accounts: [Account], includeDisabledCodex: Bool = false) async -> [String: QuotaReading] {
        await withTaskGroup(of: (String, QuotaReading?).self) { group in
            for a in accounts where (!a.disabled || includeDisabledCodex && a.provider == .codex) && a.provider != .other && a.authIndex?.isEmpty == false {
                group.addTask { (a.id, await self.refreshAccount(a)) }
            }
            var result: [String: QuotaReading] = [:]
            for await (id, reading) in group { if let reading { result[id] = reading } }
            return result
        }
    }
    private func refreshAccount(_ a: Account) async -> QuotaReading? {
        let id = identity(a)
        if let task = pending[id] { return await task.value }
        let now = clock()
        if let last = lastRead[id], now.timeIntervalSince(last) < 60 { return cache[id] }
        lastRead[id] = now // failed requests are throttled too
        let generation = generations[id, default: 0]
        let task = Task { @MainActor () -> QuotaReading? in
            do {
                let data = try await read(a.provider == .claude ? .claudeUsage : .codexUsage, account: a)
                var q = try LiveQuotaParser.usage(data, provider: a.provider, now: clock())
                let now = clock()
                let due: Bool = {
                    guard let last = planRead[id] else { return true }
                    return now.timeIntervalSince(last.at) >= (last.ok ? 6 * 3600 : 15 * 60)
                }()
                if due {
                    var ok = false
                    if let data = try? await read(a.provider == .claude ? .claudeProfile : .codexAccounts, account: a),
                       var plan = try? LiveQuotaParser.plan(data, provider: a.provider, accountID: a.chatgptAccountID) {
                        plan.observedAt = now
                        accountPlans[id] = plan; ok = true
                        // Keeps the organization fingerprint fresh for the T3 Code limits shim's local-login match
                        // now that Proxy Deck no longer records it (only the fingerprint is stored, never the uuid).
                        if a.provider == .claude, let index = a.authIndex, !index.isEmpty {
                            let key = PlanCache.accountKey(index), info = plan
                            Task.detached(priority: .utility) { PlanCache.record(key: key, info) }
                        }
                    }
                    planRead[id] = (now, ok)
                }
                guard generations[id, default: 0] == generation else { return cache[id] }
                // The plan in the current usage answer wins; the profile fills in the plan if missing, and the org.
                let profile = accountPlans[id]
                q.plan = q.plan ?? profile?.plan
                q.planInfo = (q.plan == nil && profile?.org == nil) ? nil : PlanInfo(plan: q.plan, org: profile?.org)
                plans[a.id] = q.planInfo
                cache[id] = q
                return q
            } catch { return cache[id] }
        }
        pending[id] = task
        let result = await task.value
        pending[id] = nil
        return result
    }

    public func resetCredits(_ account: Account) async throws -> [ResetCredit] {
        guard account.provider == .codex else { throw LiveQuotaError.invalidAccount }
        return try LiveQuotaParser.resetCredits(await read(.codexCredits, account: account), now: clock())
    }

    /// Reads only. A confirmation is bound to this account, organization, grant and management-key epoch.
    public func prepareClaudeReset(account: Account, grantID: String) async throws -> ClaudeResetConfirmation {
        guard account.provider == .claude, !account.disabled, let index = account.authIndex, !index.isEmpty else {
            throw LiveQuotaError.invalidAccount
        }
        guard grantID.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil else { throw LiveQuotaError.invalidCredit }
        let keyEpoch = monitor.keyEpoch
        let usage = try await read(.claudeUsage, account: account)
        let profile = try await read(.claudeProfile, account: account)
        let now = clock()
        guard monitor.keyEpoch == keyEpoch else { throw CancellationError() }
        guard let status = try LiveQuotaParser.usage(usage, provider: .claude, now: now).claudeResets,
              let grant = status.grants.first(where: { $0.id == grantID }), status.canUse(grant, at: now),
              let org = try LiveQuotaParser.object(profile)["organization"] as? [String: Any],
              let id = org["uuid"] as? String, let uuid = UUID(uuidString: id) else { throw LiveQuotaError.invalidCredit }
        return ClaudeResetConfirmation(grant: grant, requestID: UUID(), organization: uuid,
                                       accountIndex: index, accountName: account.name, keyEpoch: keyEpoch)
    }

    /// Never retried automatically. Keep `confirmed` when the response is uncertain.
    public func consumeClaudeReset(account: Account, confirmed: ConfirmedClaudeReset,
                                   revalidate: @MainActor @Sendable () -> Bool = { true }) async throws -> ClaudeResetResult {
        let c = confirmed.value
        guard account.provider == .claude, !account.disabled, account.authIndex == c.accountIndex,
              account.name == c.accountName else { throw LiveQuotaError.invalidCredit }
        await acquire(); defer { release() }
        try Task.checkCancellation()
        guard monitor.keyEpoch == c.keyEpoch, revalidate() else { throw CancellationError() }
        let data = try await monitor.management { try await $0.claimClaudeReset(account: account, confirmed: confirmed, key: $1) }
        let body = try LiveQuotaParser.object(data)
        let result: ClaudeResetResult
        if ["stamp_indeterminate", "reset_unconfirmed"].contains(body["reason"] as? String ?? "") {
            result = .unconfirmed
        } else { result = (body["result"] as? String).flatMap(ClaudeResetResult.init(rawValue:)) ?? .unconfirmed }
        if result == .reset || result == .alreadyUsed {
            await afterSuccess(account)
        } else if result != .unconfirmed {
            let id = identity(account)
            generations[id, default: 0] += 1; cache[id] = nil; lastRead[id] = nil
        }
        return result
    }

    /// No automatic retry. The caller retains the confirmed value to retry the same request.
    public func consume(account: Account, confirmed credit: ConfirmedResetCredit,
                        revalidate: @MainActor @Sendable () -> Bool = { true }) async throws -> ResetCreditResult {
        guard account.provider == .codex, account.disabled == credit.routingDisabled else { throw LiveQuotaError.invalidAccount }
        let keyEpoch = monitor.keyEpoch
        await acquire(); defer { release() }
        try Task.checkCancellation()
        // Stay on the main actor from this check through dispatch: no suspension can stale the intent.
        guard monitor.keyEpoch == keyEpoch, revalidate() else { throw CancellationError() }
        let data = try await monitor.management { client, key in
            try await client.quotaCall(.codexConsume, account: account, confirmation: credit, key: key)
        }
        let body = try LiveQuotaParser.object(data)
        let result: ResetCreditResult
        switch body["code"] as? String {
        case "reset":
            let n = liveNumber(body["windows_reset"])
            result = .reset(windows: n.flatMap { $0 >= 0 && $0 <= 100 && $0.rounded() == $0 ? Int($0) : nil } ?? 0)
        case "already_redeemed": result = .alreadyRedeemed
        case "nothing_to_reset": result = .nothingToReset
        case "no_credit": result = .noCredit
        default: result = .failed
        }
        if case .reset = result { await afterSuccess(account) }
        else if result == .alreadyRedeemed { await afterSuccess(account) }
        return result
    }
    private func afterSuccess(_ account: Account) async {
        let id = identity(account)
        generations[id, default: 0] += 1
        cache[id] = nil; lastRead[id] = nil
        // A reset of a paused subscription must not change its routing or local cooldown state.
        guard !account.disabled else { cooldownClearFailed.remove(account.id); return }
        do {
            try await monitor.management { try await $0.clearLiveQuotaCooldown(account: account, key: $1) }
            cooldownClearFailed.remove(account.id)
        } catch { cooldownClearFailed.insert(account.id) }
    }
}
