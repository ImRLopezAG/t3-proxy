import Foundation

/// The alert kinds the user can switch on and off.
public enum AlertKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case lowQuota, creditExpiring, accountHeld, hubOffline
    case threadNeedsYou, threadFinished, threadFailed, threadLimited
    public var id: Self { self }
    public static let proxyKinds: [AlertKind] = [.lowQuota, .creditExpiring, .accountHeld, .hubOffline]
    public static let t3CodeKinds: [AlertKind] = [.threadNeedsYou, .threadLimited, .threadFinished, .threadFailed]
    /// Off unless the user turns them on.
    public static let defaultOff: Set<AlertKind> = [.threadFinished, .threadFailed]
    public var title: String {
        switch self {
        case .lowQuota: "Quota running low or used up"
        case .creditExpiring: "Banked Codex reset expiring"
        case .accountHeld: "Account in cooldown or error"
        case .hubOffline: "Proxy stopped or came back"
        case .threadNeedsYou: "Thread needs you"
        case .threadFinished: "Thread finished"
        case .threadFailed: "Thread failed"
        case .threadLimited: "Thread stopped by a usage limit"
        }
    }
}

public struct AlertSettings: Codable, Sendable, Equatable {
    public var disabled: Set<AlertKind> = []
    /// Default-off kinds the user turned on. Optional so older saved settings still decode.
    public var enabled: Set<AlertKind>? = nil
    /// Remaining percentage at or below which `lowQuota` fires (0% has its own alert).
    public var threshold: Double = 10
    public init() {}
    private enum CodingKeys: String, CodingKey { case disabled, enabled, threshold }
    /// Kinds this version no longer has (the removed game's alert) are skipped, so saved preferences still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func kinds(_ k: CodingKeys) throws -> Set<AlertKind>? {
            try c.decodeIfPresent([String].self, forKey: k).map { Set($0.compactMap(AlertKind.init(rawValue:))) }
        }
        disabled = try kinds(.disabled) ?? []
        enabled = try kinds(.enabled)
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 10
    }
    public func isOn(_ k: AlertKind) -> Bool {
        AlertKind.defaultOff.contains(k) ? enabled?.contains(k) ?? false : !disabled.contains(k)
    }
    public mutating func set(_ k: AlertKind, on: Bool) {
        if AlertKind.defaultOff.contains(k) {
            var e = enabled ?? []
            if on { e.insert(k) } else { e.remove(k) }
            enabled = e
        } else if on { disabled.remove(k) } else { disabled.insert(k) }
    }
    public static let creditWarning: TimeInterval = 48 * 3600
}

public struct Alert: Sendable, Equatable {
    public var kind: AlertKind
    /// The de-duplication key (contains only hashed account keys).
    public var id: String
    public var title: String
    public var body: String
    /// The T3 Code thread a click should open.
    public var threadID: String?
    public init(kind: AlertKind, id: String, title: String, body: String, threadID: String? = nil) {
        self.kind = kind; self.id = id; self.title = title; self.body = body; self.threadID = threadID
    }
}

extension Account {
    /// A human label that never falls back to a credential filename or account identifier.
    public var quotaLabel: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname.emailHidden
        }
        let plan = quota.planInfo?.plan ?? quota.plan
        let title = plan.flatMap { PlanCache.isPlan($0) ? $0.capitalized : nil }
        return [provider.title, title, "account"].compactMap { $0 }.joined(separator: " ")
    }

    public func quotaLabel(among accounts: [Account]) -> String {
        let peers = accounts.filter { $0.quotaLabel == quotaLabel }.sorted { $0.id < $1.id }
        guard peers.count > 1, let index = peers.firstIndex(where: { $0.id == id }) else { return quotaLabel }
        return "\(quotaLabel) #\(index + 1)"
    }
}

/// What the rules look at for one account. `label` is shown, never stored.
public struct AlertAccount: Sendable, Equatable {
    public struct Window: Sendable, Equatable { public var remaining: Double; public var resetAt: Date?
        public init(remaining: Double, resetAt: Date?) { self.remaining = remaining; self.resetAt = resetAt } }
    public var key: String
    public var label: String
    public var held: Bool
    public var heldReason: String?
    public var session: Window?
    public var weekly: Window?
    public init(key: String, label: String, held: Bool = false, heldReason: String? = nil, session: Window? = nil, weekly: Window? = nil) {
        self.key = key; self.label = label; self.held = held; self.heldReason = heldReason; self.session = session; self.weekly = weekly
    }
    /// Nil for accounts the rules ignore (disabled, or without quota support).
    public init?(_ a: Account, now: Date) {
        guard !a.disabled, a.provider != .other else { return nil }
        func w(_ k: QuotaWindowKind) -> Window? { a.quota.remaining(k, at: now).map { Window(remaining: $0, resetAt: a.quota.window(k)?.resetAt) } }
        self.init(key: accountHistoryKey(a), label: a.quotaLabel, held: a.held,
                  heldReason: a.heldReason.map(\.emailHidden), session: w(.session), weekly: w(.weekly))
    }
}

public struct AlertSnapshot: Sendable, Equatable {
    public var reachability: Reachability
    /// Nil while the account list is unknown (no key, not loaded yet): account rules keep their state.
    public var accounts: [AlertAccount]?
    /// Credit expiry times per account key, for accounts whose credit list has been read.
    public var credits: [String: [Date]]
    public init(reachability: Reachability, accounts: [AlertAccount]?, credits: [String: [Date]] = [:]) {
        self.reachability = reachability; self.accounts = accounts; self.credits = credits
    }
}

/// Persisted between runs (UserDefaults). Keys hold hashed account keys and times only.
public struct AlertState: Codable, Sendable, Equatable {
    /// De-duplication key → when it fired (or was seen at first launch).
    public var fired: [String: Date] = [:]
    public var accountsSeeded = false
    public var creditsSeeded: [String: Date] = [:]
    public struct WindowInstance: Codable, Sendable, Equatable {
        public var resetAt: Date
        public var seenAt: Date
    }
    public var windows: [String: WindowInstance] = [:]
    public var lastReachability: String?
    public var offlineAlerted = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fired, accountsSeeded, creditsSeeded, windows, lastReachability, offlineAlerted
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fired = try c.decodeIfPresent([String: Date].self, forKey: .fired) ?? [:]
        accountsSeeded = try c.decodeIfPresent(Bool.self, forKey: .accountsSeeded) ?? false
        if let dated = try? c.decode([String: Date].self, forKey: .creditsSeeded) {
            creditsSeeded = dated
        } else {
            // Older installations stored only a set; start their retention clock at migration.
            let legacy = try c.decodeIfPresent(Set<String>.self, forKey: .creditsSeeded) ?? []
            let migratedAt = Date()
            creditsSeeded = Dictionary(uniqueKeysWithValues: legacy.map { ($0, migratedAt) })
        }
        windows = try c.decodeIfPresent([String: WindowInstance].self, forKey: .windows) ?? [:]
        lastReachability = try c.decodeIfPresent(String.self, forKey: .lastReachability)
        offlineAlerted = try c.decodeIfPresent(Bool.self, forKey: .offlineAlerted) ?? false
    }
}

public enum AlertRules {
    /// Quota keys carry their reset period, so they're kept a little longer than a week, then forgotten.
    static let quotaMemory: TimeInterval = 8 * 86400
    static let creditMemory: TimeInterval = 3 * 86400

    /// Pure rule engine: (previous state, current snapshot, now) → alerts to post and the next state.
    /// Every condition fires once per de-duplication key. On the very first run, conditions that already
    /// hold are recorded as seen without alerting; after that the persisted state does the same across launches.
    public static func evaluate(_ previous: AlertState, _ s: AlertSnapshot, settings: AlertSettings, now: Date) -> (alerts: [Alert], state: AlertState) {
        var state = previous
        var out: [Alert] = []
        state.creditsSeeded = state.creditsSeeded.filter { now.timeIntervalSince($0.value) < 14 * 86400 }
        state.windows = state.windows.filter { now.timeIntervalSince($0.value.seenAt) < quotaMemory }

        // Hub reachability: edge-triggered, ignoring "unknown" (still checking).
        if s.reachability != .unknown {
            let cur = s.reachability == .live ? "live" : "offline"
            if cur == "offline", state.lastReachability == "live" {
                if settings.isOn(.hubOffline) {
                    out.append(Alert(kind: .hubOffline, id: "hub|offline", title: "Proxy isn't responding",
                                     body: "T3 Proxy can't reach the proxy hub. Requests through it will fail until it's back."))
                    state.offlineAlerted = true
                }
            } else if cur == "live", state.offlineAlerted {
                state.offlineAlerted = false
                if settings.isOn(.hubOffline) {
                    out.append(Alert(kind: .hubOffline, id: "hub|online", title: "Proxy is back", body: "The proxy hub is responding again."))
                }
            }
            state.lastReachability = cur
        }

        var fresh: [(key: String, alert: Alert?)] = []
        if let accounts = s.accounts {
            var heldActive = Set<String>()
            for a in accounts {
                for (kind, w) in [(QuotaWindowKind.session, a.session), (.weekly, a.weekly)] {
                    guard let w else { continue }
                    let windowKey = "\(a.key)|\(kind.rawValue)"
                    let period: String
                    if let reset = w.resetAt {
                        let tolerance: TimeInterval = kind == .session ? 15 * 60 : 2 * 3600
                        let canonical: Date
                        if let known = state.windows[windowKey], abs(known.resetAt.timeIntervalSince(reset)) <= tolerance {
                            canonical = known.resetAt
                        } else { canonical = reset }
                        state.windows[windowKey] = .init(resetAt: canonical, seenAt: now)
                        period = String(Int((canonical.timeIntervalSince1970 / 600).rounded()))
                    } else { period = "none" }
                    let base = "|\(a.key)|\(kind.rawValue)|\(period)"
                    let resets = w.resetAt.map { " Resets in \(shortDuration(until: $0, from: now))." } ?? ""
                    if w.remaining <= 0 {
                        fresh.append(("zero" + base, Alert(kind: .lowQuota, id: "zero" + base, title: "\(a.label) is out of \(kind == .session ? "5-hour" : "weekly") quota",
                                                          body: "Its \(kind.title.lowercased()) limit is used up.\(resets)")))
                        fresh.append(("low" + base, nil))   // no "low" after "used up" in the same period
                    } else if w.remaining <= settings.threshold {
                        fresh.append(("low" + base, Alert(kind: .lowQuota, id: "low" + base, title: "\(a.label) is low on \(kind == .session ? "5-hour" : "weekly") quota",
                                                         body: "\(Int(w.remaining.rounded()))% of its \(kind.title.lowercased()) limit left.\(resets)")))
                    }
                }
                if a.held {
                    let key = "held|\(a.key)"
                    heldActive.insert(key)
                    fresh.append((key, Alert(kind: .accountHeld, id: key, title: "\(a.label) is on hold",
                                             body: (a.heldReason ?? "The proxy stopped using it for now.") + ".")))
                }
            }
            // Held is edge-triggered: once the account recovers it may alert again next time.
            for k in state.fired.keys where k.hasPrefix("held|") && !heldActive.contains(k) { state.fired[k] = nil }
            if !state.accountsSeeded {
                for f in fresh { state.fired[f.key] = now }
                fresh = []
                state.accountsSeeded = true
            }
        }

        for (key, expiries) in s.credits {
            let label = s.accounts?.first { $0.key == key }?.label ?? "A Codex account"
            var items: [(String, Alert?)] = []
            for e in expiries where e > now && e.timeIntervalSince(now) <= AlertSettings.creditWarning {
                let id = "credit|\(key)|\(Int(e.timeIntervalSince1970 / 60))"
                items.append((id, Alert(kind: .creditExpiring, id: id, title: "A banked reset on \(label) expires soon",
                                        body: "It expires in \(shortDuration(until: e, from: now)). Use it in T3 Proxy before then, or it's lost.")))
            }
            if state.creditsSeeded[key] == nil { for i in items { state.fired[i.0] = now } } else { fresh += items }
            state.creditsSeeded[key] = now
        }

        for f in fresh where state.fired[f.key] == nil {
            state.fired[f.key] = now
            if let a = f.alert, settings.isOn(a.kind) { out.append(a) }
        }

        state.fired = state.fired.filter { k, at in
            let age = now.timeIntervalSince(at)
            if k.hasPrefix("credit|") { return age < creditMemory }
            if k.hasPrefix("low|") || k.hasPrefix("zero|") { return age < quotaMemory }
            return true
        }
        if state.creditsSeeded.count > 200 {
            let newest = state.creditsSeeded.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }.prefix(200)
            state.creditsSeeded = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return (out, state)
    }
}
