import Foundation
import CryptoKit

/// One observed reading of an account's 5-hour or weekly window. Keyed by an opaque hash, never a name.
public struct QuotaSample: Codable, Sendable, Equatable {
    public var key: String
    public var kind: String          // QuotaWindowKind.rawValue
    public var remaining: Double     // 0...100
    public var resetAt: Date?
    public var observedAt: Date
    public init(key: String, kind: QuotaWindowKind, remaining: Double, resetAt: Date?, observedAt: Date) {
        self.key = key; self.kind = kind.rawValue; self.remaining = remaining; self.resetAt = resetAt; self.observedAt = observedAt
    }
    public var windowKind: QuotaWindowKind? { QuotaWindowKind(rawValue: kind) }
}

/// Stable, non-identifying key for an account: provider plus a hash of its auth index (or name if it has none).
/// Credential names contain emails, so the raw value never leaves this function.
public func accountHistoryKey(_ a: Account) -> String {
    let source = a.authIndex.flatMap { $0.isEmpty ? nil : "idx:" + $0 } ?? "name:" + a.name
    let hex = SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return a.provider.rawValue + ":" + hex
}

/// Known 5-hour and weekly readings in the current account list.
public func quotaSamples(from accounts: [Account]) -> [QuotaSample] {
    accounts.flatMap { a -> [QuotaSample] in
        guard a.provider != .other, let seen = a.quota.observedAt else { return [] }
        let key = accountHistoryKey(a)
        return QuotaWindowKind.allCases.compactMap { kind in
            guard let w = a.quota.window(kind), let used = w.usedPercent, used.isFinite else { return nil }
            return QuotaSample(key: key, kind: kind, remaining: min(100, max(0, 100 - used)), resetAt: w.resetAt, observedAt: seen)
        }
    }
}

/// Quota samples kept for forecasts: 35 days, capped, oldest dropped first.
public struct QuotaHistory: Codable, Sendable, Equatable {
    public static let retention: TimeInterval = 35 * 86400
    public static let maximumSamples = 40_000
    /// Allow a little clock skew between the hub and this Mac.
    static let futureSlack: TimeInterval = 5 * 60
    /// An unchanged reading is stored again only after this long (keeps the file small between 60 s polls).
    static let unchangedInterval: TimeInterval = 30 * 60

    public var version = 1
    public private(set) var samples: [QuotaSample] = []
    public init(samples: [QuotaSample] = []) { self.samples = samples.sorted { $0.observedAt < $1.observedAt } }

    /// Adds new readings; returns how many were stored.
    @discardableResult
    public mutating func record(_ new: [QuotaSample], now: Date = Date()) -> Int {
        var latest: [String: QuotaSample] = [:]
        for s in samples { latest[s.key + "|" + s.kind] = s }
        var added = 0
        for s in new.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard s.remaining.isFinite, s.windowKind != nil,
                  s.observedAt <= now.addingTimeInterval(Self.futureSlack),
                  s.observedAt >= now.addingTimeInterval(-Self.retention) else { continue }
            let id = s.key + "|" + s.kind
            if let last = latest[id] {
                if s.observedAt <= last.observedAt { continue }
                if last.remaining == s.remaining, last.resetAt == s.resetAt,
                   s.observedAt.timeIntervalSince(last.observedAt) < Self.unchangedInterval { continue }
            }
            samples.append(s); latest[id] = s; added += 1
        }
        if added > 0 { samples.sort { $0.observedAt < $1.observedAt } }
        prune(now: now)
        return added
    }

    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.observedAt < cutoff }
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }
}

/// Reads and writes Application Support/T3 Proxy/quota-history.json. Writes are atomic and serialized off the main thread.
public actor QuotaHistoryStore {
    public nonisolated let url: URL
    public init(url: URL = QuotaHistoryStore.defaultURL) { self.url = url }
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("T3 Proxy", isDirectory: true).appendingPathComponent("quota-history.json")
    }
    public func load(now: Date = Date()) -> QuotaHistory {
        guard let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024,
              var h = try? Self.decoder.decode(QuotaHistory.self, from: data) else { return QuotaHistory() }
        h.prune(now: now)
        return h
    }
    public func save(_ h: QuotaHistory) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(h).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
