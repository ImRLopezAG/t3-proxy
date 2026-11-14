import Foundation

/// One reported limit across subscriptions. Each account has equal weight; plan sizes are never guessed.
public struct QuotaLane: Identifiable, Sendable {
    public struct Entry: Identifiable, Sendable {
        public var id: String { account.id }
        public let account: Account
        public let window: AccountWindow
        public let remaining: Double?
    }
    public let id: String
    public let title: String
    public let entries: [Entry]
    public var measured: Int { entries.filter { $0.remaining != nil }.count }
    public var remaining: Double? {
        let values = entries.compactMap(\.remaining)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    public var resetAt: Date? {
        entries.filter { $0.remaining != nil }.compactMap { $0.window.window.resetAt }.min()
    }
    public var resetGainPercent: Double? {
        guard let resetAt, measured > 0 else { return nil }
        return entries.reduce(0) { sum, entry in
            guard entry.window.window.resetAt == resetAt, let remaining = entry.remaining else { return sum }
            return sum + (100 - remaining) / Double(measured)
        }
    }
}

/// Recomputed at render time so an open panel turns expired readings into unknowns without inventing a refill.
public func quotaLanes(_ accounts: [Account], provider: Provider, now: Date) -> [QuotaLane] {
    var groups: [String: [QuotaLane.Entry]] = [:]
    let eligible = accounts.filter { $0.provider == provider && !$0.disabled }.sorted {
        ($0.quotaLabel(among: accounts), $0.id) < ($1.quotaLabel(among: accounts), $1.id)
    }
    for account in eligible {
        for window in account.quota.windows.map(AccountWindow.init) {
            let id = window.window.kind?.rawValue ?? window.id
            // Providers can use either weekly id; one account contributes once to a lane.
            guard groups[id]?.contains(where: { $0.id == account.id }) != true else { continue }
            groups[id, default: []].append(.init(account: account, window: window,
                                               remaining: account.quota.remaining(window, at: now)))
        }
    }
    return groups.map { id, entries in
        let title = id == QuotaWindowKind.session.rawValue ? "Session"
            : id == QuotaWindowKind.weekly.rawValue ? "Weekly" : entries[0].window.window.label
        return QuotaLane(id: id, title: title, entries: entries)
    }.sorted {
        func rank(_ id: String) -> Int { id == QuotaWindowKind.session.rawValue ? 0 : id == QuotaWindowKind.weekly.rawValue ? 1 : 2 }
        return (rank($0.id), $0.title, $0.id) < (rank($1.id), $1.title, $1.id)
    }
}
