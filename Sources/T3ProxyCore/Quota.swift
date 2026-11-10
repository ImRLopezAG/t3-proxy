import Foundation

// Recorded quota: the rate-limit headers the hub saw on each account's last real request,
// as returned by `GET /v0/management/auth-files` (`quota` and `model_quotas`). No provider
// calls. Follows Proxy Deck's normalize.ts/pool.ts: Claude reports 0..1 fractions, Codex
// reports percents, windows are named by length, and a reading whose reset has passed is unknown.

/// Allowlist decode of a `quota` / `model_quotas[model]` block. Only quota header values are kept.
public struct QuotaBlock: Decodable, Sendable, Equatable {
    public var observed_at: String?
    public var signals: [String: SignalValue]?
    public init(observed_at: String?, signals: [String: SignalValue]?) { self.observed_at = observed_at; self.signals = signals }

    /// A header value; the hub may send strings, numbers or booleans.
    public struct SignalValue: Decodable, Sendable, Equatable, ExpressibleByStringLiteral {
        public var text: String
        public init(stringLiteral s: String) { text = s }
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self) { text = s }
            else if let n = try? c.decode(Double.self) { text = String(n) }
            else if let b = try? c.decode(Bool.self) { text = String(b) }
            else { text = "" }
        }
    }
}

public enum QuotaWindowKind: String, Sendable, CaseIterable {
    case session, weekly
    public var title: String { self == .session ? "5-hour session" : "Weekly" }
    /// Validity period when no reset time was reported.
    var period: TimeInterval { self == .session ? 5 * 3600 : 7 * 86400 }
}

public struct QuotaWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double?
    public var resetAt: Date?
    /// The window's length as the provider reported it (Codex window minutes/seconds, Claude's 5h/7d groups);
    /// nil when only the id implies it.
    public var duration: TimeInterval?
    /// Only account-level session and weekly windows pool across accounts.
    public var kind: QuotaWindowKind? {
        switch id { case "five-hour": return .session; case "seven-day", "weekly": return .weekly; default: return nil }
    }
    public init(id: String, label: String, usedPercent: Double?, resetAt: Date?, duration: TimeInterval? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetAt = resetAt
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

/// A measured limit the account actually has, including model-scoped and secondary limits.
public struct AccountWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let window: QuotaWindow
    public let duration: TimeInterval?

    init(_ window: QuotaWindow) {
        let id = window.id
        self.window = window; self.id = id
        func contains(_ name: String) -> Bool {
            id.range(of: "(^|-)" + name + "($|-)", options: .regularExpression) != nil
        }
        // The reported length wins; the id only fills in when nothing was reported. "Monthly" has no fixed length
        // (28–31 days), so without a reported length it gets no pace rather than a wrong one.
        if let reported = window.duration { duration = reported }
        else if contains("five-hour") { duration = 5 * 3600 }
        else if contains("seven-day") || contains("weekly") { duration = 7 * 86400 }
        else if let m = id.firstMatch(of: /(?:^|-)(\d+)-(minute|hour|day)$/), let n = Double(m.1), n.isFinite, n > 0 {
            duration = n * (m.2 == "minute" ? 60 : m.2 == "hour" ? 3600 : 86400)
        } else { duration = nil }

        let parts = window.label.components(separatedBy: " · ")
        if id == "five-hour" { title = "5-hour" }
        else if id == "seven-day" || id == "weekly" { title = "Weekly" }
        else if id == "monthly" { title = "Monthly" }
        else if id == "credit-pool" { title = "Credit pool" }
        else if id == "extra-usage" { title = "Extra usage" }
        else if id.hasPrefix("seven-day-") {
            let model = parts.count > 1 ? parts.dropFirst().joined(separator: " · ")
                : window.label.components(separatedBy: "(").dropFirst().joined(separator: "(").trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            let name = model.isEmpty ? String(id.dropFirst("seven-day-".count)).replacingOccurrences(of: "-", with: " ").capitalized : model
            title = name.prefix(1).uppercased() + name.dropFirst() + " weekly"
        } else if parts.count > 1 {
            let limit = parts.last == "5-hour session" ? "5-hour" : parts.last!.lowercased()
            title = parts.dropLast().joined(separator: " · ") + " " + limit
        } else { title = window.label }
    }
}

public struct QuotaReading: Sendable, Equatable {
    public var source: QuotaSource = .recorded
    public var credits: LiveCredits? = nil
    public var availableResetCredits: Int? = nil
    public var planInfo: PlanInfo? = nil
    public var observedAt: Date?
    public var windows: [QuotaWindow]
    public var models: [String: [QuotaWindow]]
    public var plan: String?
    public static let none = QuotaReading(observedAt: nil, windows: [], models: [:], plan: nil)
    public init(observedAt: Date?, windows: [QuotaWindow], models: [String: [QuotaWindow]], plan: String?) {
        self.observedAt = observedAt; self.windows = windows; self.models = models; self.plan = plan
    }

    public init(provider: Provider, quota: QuotaBlock?, models: [String: QuotaBlock]?) {
        func parse(_ b: QuotaBlock) -> [QuotaWindow] {
            switch provider {
            case .claude: return parseClaudeSignals(b.signals ?? [:])
            case .codex: return parseCodexSignals(b.signals ?? [:], observed: b.observed_at.flatMap(parseHubDate))
            case .other: return []
            }
        }
        let m = (models ?? [:]).compactMapValues { b -> [QuotaWindow]? in let w = parse(b); return w.isEmpty ? nil : w }
        let plan = provider == .codex ? lower(quota?.signals ?? [:])["x-codex-plan-type"].flatMap { $0.isEmpty ? nil : $0 } : nil
        self.init(observedAt: quota?.observed_at.flatMap(parseHubDate), windows: quota.map(parse) ?? [], models: m, plan: plan)
    }

    /// Remaining 0...100 for a window kind, or nil when unknown: no reading, no observation time,
    /// a reset that has passed, or (without a reset) a full period since the observation.
    public func remaining(_ kind: QuotaWindowKind, at now: Date) -> Double? {
        guard let w = window(kind), let used = w.usedPercent, let obs = observedAt, obs <= now else { return nil }
        if let r = w.resetAt { if r <= now { return nil } } else if now >= obs.addingTimeInterval(kind.period) { return nil }
        return min(100, max(0, 100 - used))
    }
    public func window(_ kind: QuotaWindowKind) -> QuotaWindow? { windows.first { $0.kind == kind } }

    public func accountWindows() -> [AccountWindow] {
        func rank(_ w: AccountWindow) -> Int {
            if w.id == "five-hour" { return 0 }
            if w.id == "seven-day" || w.id == "weekly" { return 1 }
            return w.duration == 7 * 86400 ? 2 : 3
        }
        return windows.filter { $0.usedPercent != nil }.map(AccountWindow.init).enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    public func remaining(_ w: AccountWindow, at now: Date) -> Double? {
        guard let used = w.window.usedPercent, used.isFinite, let obs = observedAt, obs <= now else { return nil }
        if let reset = w.window.resetAt { if reset <= now { return nil } }
        else if let duration = w.duration, now >= obs.addingTimeInterval(duration) { return nil }
        return min(100, max(0, 100 - used))
    }
}

private func lower(_ s: [String: QuotaBlock.SignalValue]) -> [String: String] {
    Dictionary(s.map { ($0.key.lowercased(), $0.value.text.trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { a, _ in a })
}

/// Epoch seconds, epoch milliseconds or an ISO date; nonpositive is "none".
func parseHubTime(_ v: String?) -> Date? {
    guard let v, !v.isEmpty else { return nil }
    if let n = finiteNumber(v) { return n <= 0 ? nil : Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
    return parseHubDate(v)
}

/// ISO 8601 with any number of fractional digits (the hub sends microseconds).
public func parseHubDate(_ s: String) -> Date? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: trimmed)
}

/// Hub signals are strings; "nan", "inf" or "1e300" parse as Double but trap when converted to Int.
func finiteNumber(_ v: String) -> Double? {
    guard let d = Double(v), d.isFinite, abs(d) < 1e15 else { return nil }
    return d
}

private func windowName(minutes: Double) -> (String, String) {
    let m = Int(minutes)   // finite and < 1e15 * 1440 via finiteNumber
    if m == 300 { return ("five-hour", "5-hour session") }
    if m == 10080 { return ("weekly", "Weekly") }
    if m >= 28 * 1440 && m <= 31 * 1440 { return ("monthly", "Monthly") }
    if m % 1440 == 0 { return ("\(m / 1440)-day", "\(m / 1440)-day") }
    if m % 60 == 0 { return ("\(m / 60)-hour", "\(m / 60)-hour") }
    return ("\(m)-minute", "\(m)-minute")
}

private let claudePrefix = "anthropic-ratelimit-unified-"

/// `Anthropic-Ratelimit-Unified-<group>-Utilization` (0..1) and `-Reset` (epoch seconds).
func parseClaudeSignals(_ raw: [String: QuotaBlock.SignalValue]) -> [QuotaWindow] {
    let s = lower(raw)
    var groups = Set<String>()
    for k in s.keys where k.hasPrefix(claudePrefix) {
        let rest = k.dropFirst(claudePrefix.count)
        for suffix in ["-utilization", "-reset"] where rest.hasSuffix(suffix) && rest.count > suffix.count {
            groups.insert(String(rest.dropLast(suffix.count)))
        }
    }
    return groups.sorted().map { g in
        let id: String, label: String
        if g == "overage" { (id, label) = ("extra-usage", "Extra usage") }
        else if let m = g.wholeMatch(of: /(\d+)([hd])(?:_(.+))?/), let n = finiteNumber(String(m.1)) {
            let minutes = n * (m.2 == "h" ? 60 : 1440)
            var base = windowName(minutes: minutes)
            if Int(minutes) == 10080 { base.0 = "seven-day" }
            if let extra = m.3 { (id, label) = ("\(base.0)-\(extra.lowercased())", "\(base.1) (\(extra))") } else { (id, label) = base }
        } else { (id, label) = (g, g.capitalized) }
        let util = s[claudePrefix + g + "-utilization"].flatMap(finiteNumber)
        let minutes = g.wholeMatch(of: /(\d+)([hd])(?:_.+)?/).flatMap { m in finiteNumber(String(m.1)).map { $0 * (m.2 == "h" ? 60 : 1440) } }
        return QuotaWindow(id: id, label: label, usedPercent: util.map { $0 * 100 }, resetAt: parseHubTime(s[claudePrefix + g + "-reset"]),
                           duration: minutes.map { $0 * 60 })
    }
}

/// `X-Codex-{Primary,Secondary}-*`. Slots are named by window length: primary can be weekly.
func parseCodexSignals(_ raw: [String: QuotaBlock.SignalValue], observed: Date?) -> [QuotaWindow] {
    let s = lower(raw)
    return ["primary", "secondary"].compactMap { slot in
        let p = "x-codex-\(slot)-"
        let used = s[p + "used-percent"].flatMap(finiteNumber)
        let minutes = s[p + "window-minutes"].flatMap(finiteNumber)
        let resetAt = parseHubTime(s[p + "reset-at"])
        let after = s[p + "reset-after-seconds"].flatMap(finiteNumber)
        if used == nil && minutes == nil && resetAt == nil && after == nil { return nil }
        // A zero-length window is a slot the plan doesn't have.
        if let minutes, minutes <= 0 { return nil }
        let name = minutes.map { windowName(minutes: $0) } ?? (slot, slot == "primary" ? "Primary window" : "Secondary window")
        let reset = resetAt ?? (after.flatMap { a in observed.map { $0.addingTimeInterval(a) } })
        return QuotaWindow(id: name.0, label: name.1, usedPercent: used, resetAt: reset, duration: minutes.map { $0 * 60 })
    }
}

/// One provider's pooled reading for one window kind.
public struct QuotaPool: Sendable, Equatable {
    /// Percentage points of the measured pool restored at the next reset, assuming no further use.
    public var resetGainPercent: Double? = nil
    public var provider: Provider
    public var kind: QuotaWindowKind
    /// Pooled remaining 0...100, or nil when no eligible account has a current reading.
    public var remaining: Double?
    /// Eligible (not disabled) accounts of this provider.
    public var accounts: Int
    public var measured: Int
    public var unknown: Int { accounts - measured }
    /// Soonest reset among the measured accounts.
    public var resetAt: Date?
    public init(provider: Provider, kind: QuotaWindowKind, remaining: Double?, accounts: Int, measured: Int, resetAt: Date?) {
        self.provider = provider; self.kind = kind; self.remaining = remaining
        self.accounts = accounts; self.measured = measured; self.resetAt = resetAt
    }
}

/// Proxy Deck's rule (README "Charts and forecasts"): each account contributes up to 100
/// percentage points, unweighted (plan sizes are not inferred); disabled accounts are excluded;
/// unknown or expired readings are excluded from the known total and counted separately.
/// pooled = Σ remainingᵢ / (measured × 100).
public func pooledQuota(_ accounts: [Account], _ provider: Provider, _ kind: QuotaWindowKind, now: Date = Date()) -> QuotaPool {
    let eligible = accounts.filter { $0.provider == provider && !$0.disabled }
    var total = 0.0, measured = 0
    var reset: Date?
    for a in eligible {
        guard let r = a.quota.remaining(kind, at: now) else { continue }
        total += r; measured += 1
        if let d = a.quota.window(kind)?.resetAt { reset = min(reset ?? d, d) }
    }
    var result = QuotaPool(provider: provider, kind: kind, remaining: measured == 0 ? nil : total / Double(measured),
                     accounts: eligible.count, measured: measured, resetAt: reset)
    if let reset, measured > 0 {
        result.resetGainPercent = eligible.reduce(0) { sum, a in
            guard a.quota.window(kind)?.resetAt == reset, let remaining = a.quota.remaining(kind, at: now) else { return sum }
            return sum + (100 - remaining) / Double(measured)
        }
    }
    return result
}

/// "4h 24m", "2d 3h", "12m".
public func shortDuration(until date: Date, from now: Date = Date()) -> String {
    let s = max(0, Int(date.timeIntervalSince(now)))
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(m, 1))m"
}
