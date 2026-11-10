import Foundation
import CryptoKit

/// Request-level lock shared by every management request (polling, Settings, writes).
/// After a 401/403 the rejected key is never sent again, even after remove and re-entry,
/// until a different key is saved: each failure counts toward the hub's 30-minute loopback ban.
/// Only SHA-256 digests are kept, in memory.
public final class AuthGate: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected: Set<Data> = []
    public init() {}
    private static func digest(_ k: String) -> Data { Data(SHA256.hash(data: Data(k.utf8))) }
    public func permits(_ key: String) -> Bool { !key.isEmpty && lock.withLock { !rejected.contains(Self.digest(key)) } }
    public func reject(_ key: String) { _ = lock.withLock { rejected.insert(Self.digest(key)) } }
}

/// Hub status text can quote upstream errors (headers, token-bearing URLs), so only a fixed
/// category is shown, as Proxy Deck's classifyHubMessage() does.
public func classifyHubMessage(_ raw: String?) -> String {
    let m = raw ?? ""
    func has(_ p: String) -> Bool { m.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
    if has(#"\b401\b|unauthori[sz]ed|invalid_grant|expired|revoked|refresh"#) { return "Sign-in expired or was revoked" }
    if has(#"\b429\b|rate.?limit|usage limit|quota"#) { return "Rate limited by the provider" }
    if has(#"timeout|timed out|deadline"#) { return "Provider requests timed out" }
    if has(#"\b5\d\d\b|overloaded|service unavailable"#) { return "Provider server error" }
    return "The hub reported an error"
}

public enum Provider: String, Sendable, CaseIterable { case claude, codex, other
    public init(raw: String) { self = Provider(rawValue: raw.lowercased()) ?? .other }
    public var title: String { self == .claude ? "Claude" : self == .codex ? "Codex" : "Other" }
}

/// Allowlist decode of one `/v0/management/auth-files` entry. Fields such as
/// `path`, `quota_probe` and `id` are deliberately not decoded.
public struct AuthFileEntry: Decodable, Sendable, Equatable {
    public var name: String?
    public var provider: String?
    public var type: String?
    public var status: String?
    public var status_message: String?
    public var disabled: Bool?
    public var unavailable: Bool?
    public var next_retry_after: String?
    public var recent_requests: [Bucket]?
    public var note: String?
    public var quota: QuotaBlock?
    public var model_quotas: [String: QuotaBlock]?
    public var auth_index: String?
    public var id_token: LiveAccountClaims?
    public struct Bucket: Decodable, Sendable, Equatable {
        public var success: Int64?
        public var failed: Int64?
    }
}
struct AuthFilesEnvelope: Decodable { var files: [AuthFileEntry] }

public struct Account: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var provider: Provider
    /// The hub's provider word (`xai`, `kimi`, …), for marks of providers without quota support.
    public var providerName: String
    public var held: Bool
    public var heldReason: String?
    public var releaseAt: Date?
    public var requests: [Int64]   // oldest first, one per proxy bucket
    public var disabled: Bool
    /// The credential's `note`, cleaned for display.
    public var nickname: String?
    public var quota: QuotaReading
    public var authIndex: String?
    public var chatgptAccountID: String?

    public init(name: String, provider: Provider, held: Bool = false, heldReason: String? = nil,
                releaseAt: Date? = nil, requests: [Int64] = [], disabled: Bool = false,
                nickname: String? = nil, quota: QuotaReading = .none,
                authIndex: String? = nil, chatgptAccountID: String? = nil) {
        self.name = name; self.provider = provider; self.providerName = provider.rawValue; self.held = held
        self.heldReason = heldReason; self.releaseAt = releaseAt; self.requests = requests
        self.disabled = disabled; self.nickname = nickname; self.quota = quota
        self.authIndex = authIndex; self.chatgptAccountID = chatgptAccountID
    }

    public init(_ e: AuthFileEntry) {
        let raw = e.provider ?? e.type ?? ""
        var display = e.name ?? "unnamed"
        if display.hasSuffix(".json") { display.removeLast(5) }
        let status = (e.status ?? "").lowercased()
        let isDisabled = e.disabled == true || status == "disabled"
        let isHeld = isDisabled || e.unavailable == true || status == "error"
        let message = e.status_message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(name: display, provider: Provider(raw: raw), held: isHeld,
                  heldReason: !isHeld ? nil : isDisabled ? "Disabled" : message.isEmpty ? "Unavailable" : classifyHubMessage(message),
                  releaseAt: e.next_retry_after.flatMap(Account.parseDate),
                  requests: (e.recent_requests ?? []).map { ($0.success ?? 0) + ($0.failed ?? 0) },
                  disabled: isDisabled, nickname: Account.nickname(e.note),
                  quota: QuotaReading(provider: Provider(raw: raw), quota: e.quota, models: e.model_quotas))
        let word = raw.lowercased()
        authIndex = e.auth_index
        chatgptAccountID = e.id_token?.chatgpt_account_id
        providerName = word.range(of: #"^[a-z0-9-]{1,32}$"#, options: .regularExpression) != nil ? word : "other"
    }

    /// Control and bidi characters dropped, spaces collapsed, at most 60 characters.
    static func nickname(_ v: String?) -> String? {
        guard let v else { return nil }
        let kept = String(String.UnicodeScalarView(v.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x200B...0x200F).contains($0.value)
                && !(0x2028...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }))
        let s = String(kept.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// The proxy keeps 20 buckets of 10 minutes each.
public let requestWindowLabel = "last 3h 20m"

public struct ProviderSummary: Sendable, Equatable {
    public var provider: Provider
    public var active: Int
    public var held: Int
    public var requests: [Int64]
    public var total: Int64 { requests.reduce(0, +) }
}

public func summarize(_ accounts: [Account], _ provider: Provider) -> ProviderSummary {
    let mine = accounts.filter { $0.provider == provider }
    var series = [Int64](repeating: 0, count: mine.map(\.requests.count).max() ?? 0)
    for a in mine {
        // Align to the newest bucket if lengths ever differ.
        let offset = series.count - a.requests.count
        for (i, v) in a.requests.enumerated() { series[i + offset] += v }
    }
    return ProviderSummary(provider: provider, active: mine.filter { !$0.held }.count,
                           held: mine.filter(\.held).count, requests: series)
}

public enum Reachability: Sendable, Equatable { case unknown, live, offline }

public enum ManagementState: Sendable, Equatable {
    case noKey
    /// 401/403. Polling stops: every failure counts toward a 30-minute loopback ban.
    case rejected
    case connected
    case failed(String)
}

public func compact(_ n: Int64) -> String {
    let d = Double(n)
    func fmt(_ v: Double, _ s: String) -> String {
        (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)).replacingOccurrences(of: ".0", with: "") + s
    }
    if d >= 1e9 { return fmt(d / 1e9, "B") }
    if d >= 1e6 { return fmt(d / 1e6, "M") }
    if d >= 1e3 { return fmt(d / 1e3, "K") }
    return String(n)
}
