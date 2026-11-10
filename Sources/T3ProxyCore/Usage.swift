import Foundation
import SQLite3

/// Token sums for one group of requests.
public struct UsageTotals: Sendable, Equatable {
    public var total: Int64 = 0, input: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0, cached: Int64 = 0, cacheCreation: Int64 = 0
    public var requests: Int = 0, failed: Int = 0
    public init() {}
    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var r = a
        r.total += b.total; r.input += b.input; r.output += b.output; r.reasoning += b.reasoning
        r.cached += b.cached; r.cacheCreation += b.cacheCreation; r.requests += b.requests; r.failed += b.failed
        return r
    }
}

/// One local calendar day. `date` is that day's local midnight.
public struct UsageDay: Sendable, Equatable, Identifiable {
    public var date: Date
    public var byProvider: [Provider: UsageTotals] = [:]
    public var id: Date { date }
    public init(date: Date, byProvider: [Provider: UsageTotals] = [:]) { self.date = date; self.byProvider = byProvider }
    public var totals: UsageTotals { byProvider.values.reduce(UsageTotals(), +) }
    public func tokens(_ p: Provider?) -> Int64 { p.map { byProvider[$0]?.total ?? 0 } ?? totals.total }
}

/// One (provider, model, account key) group within a day.
public struct UsageBreakdownRow: Sendable, Equatable, Identifiable {
    public var provider: Provider, model: String, accountKey: String
    public var totals: UsageTotals
    public var id: String { "\(provider.rawValue)|\(model)|\(accountKey)" }
}

extension UsageBreakdownRow {
    /// API-equivalent list price, nil when the model is unpriced.
    public var estimatedCost: Double? { Pricing.cost(totals, model: model) }
}

/// One model's share of a day (accounts merged).
public struct UsageModelRow: Sendable, Equatable, Identifiable {
    public var provider: Provider, model: String, totals: UsageTotals
    public var cost: Double?
    public var id: String { "\(provider.rawValue)|\(model)" }
    public init(provider: Provider, model: String, totals: UsageTotals, cost: Double? = nil) {
        self.provider = provider; self.model = model; self.totals = totals; self.cost = cost
    }
}

/// A day grouped for the hover card and the Day section: per provider and per model, with estimated cost.
public struct UsageDayDetail: Sendable, Equatable {
    public var date: Date
    public var rows: [UsageBreakdownRow]
    /// Largest first.
    public var models: [UsageModelRow]
    public var byProvider: [Provider: UsageTotals]
    public var costByProvider: [Provider: CostEstimate]
    public var totals: UsageTotals { byProvider.values.reduce(UsageTotals(), +) }
    public var cost: CostEstimate { costByProvider.values.reduce(CostEstimate(), +) }

    /// Costs are summed per model (price × tokens is linear), so merging accounts first changes nothing.
    public init(date: Date, rows: [UsageBreakdownRow]) {
        self.date = date; self.rows = rows
        var m: [String: UsageModelRow] = [:]
        for r in rows {
            let key = "\(r.provider.rawValue)|\(r.model)"
            m[key, default: UsageModelRow(provider: r.provider, model: r.model, totals: UsageTotals())].totals = (m[key]?.totals ?? UsageTotals()) + r.totals
        }
        var bp: [Provider: UsageTotals] = [:], cp: [Provider: CostEstimate] = [:]
        models = m.values.map { var x = $0; x.cost = Pricing.cost(x.totals, model: x.model); return x }
            .sorted { ($0.totals.total, $0.id) > ($1.totals.total, $1.id) }
        for x in models {
            bp[x.provider] = (bp[x.provider] ?? UsageTotals()) + x.totals
            var c = cp[x.provider] ?? CostEstimate()
            if x.totals.total > 0 || x.totals.requests > 0 { c.add(x.cost, model: x.model) }
            cp[x.provider] = c
        }
        byProvider = bp; costByProvider = cp
    }
}

extension UsageSource {
    /// One local day with per-provider and per-model totals and estimated cost.
    public func dayDetail(day: Date, calendar: Calendar = .current) throws(UsageError) -> UsageDayDetail {
        UsageDayDetail(date: calendar.startOfDay(for: day), rows: try breakdown(day: day, calendar: calendar))
    }
}

public enum UsageError: Error, Equatable { case missing, unreadable(String) }

/// Where token history comes from. Today: Proxy Deck's database, read-only. Later: T3 Proxy's own.
public protocol UsageSource: Sendable {
    func accountSummary(provider: Provider, accountKey: String, windowStart: Date?, now: Date, calendar: Calendar) throws(UsageError) -> AccountUsageSummary
    /// Last 1...30 local calendar days, including today; grouped before crossing the source boundary.
    func rangeDetail(days: Int, now: Date, calendar: Calendar) throws(UsageError) -> UsageRangeDetail
    /// Every local day of the last `days` days ending today (empty days included), oldest first.
    func daily(days: Int, now: Date, calendar: Calendar) throws(UsageError) -> [UsageDay]
    /// One local day grouped by provider, model and account key, largest first.
    func breakdown(day: Date, calendar: Calendar) throws(UsageError) -> [UsageBreakdownRow]
    /// Token totals per provider in `count` buckets of `width` seconds, aligned to the clock (epoch multiples of
    /// `width`); the newest bucket is the one containing `now`. Oldest first; empty buckets are zero.
    func recent(count: Int, width: TimeInterval, now: Date) throws(UsageError) -> RecentUsage
    /// Token totals per provider in `count` buckets of `width` seconds starting at `start`.
    func series(start: Date, width: TimeInterval, count: Int) throws(UsageError) -> RecentUsage
    /// Estimated cost per provider for requests in [start, end).
    func costs(start: Date, end: Date) throws(UsageError) -> [Provider: CostEstimate]
}

extension UsageSource {
    public func costs(start: Date, end: Date) throws(UsageError) -> [Provider: CostEstimate] {
        throw .unreadable("This usage source does not price requests.")
    }
}

/// The panel's headline period. Cumulative ranges ("Today") only grow while you work; the old
/// rolling 3h 20m window shrank as earlier usage slid out of it.
public enum TokenRange: String, CaseIterable, Sendable, Identifiable {
    case today, last24h, last7d
    public var id: Self { self }
    public var title: String {
        switch self { case .today: "Today"; case .last24h: "24 hours"; case .last7d: "7 days" }
    }
    /// Label under the left end of the sparklines.
    public var startLabel: String {
        switch self { case .today: "Midnight"; case .last24h: "24h ago"; case .last7d: "7 days ago" }
    }
    /// Buckets for `series(start:width:count:)`; the last bucket contains `now`.
    public func plan(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, width: TimeInterval, count: Int) {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let width: TimeInterval = 1800
            return (start, width, max(1, Int((now.timeIntervalSince(start) / width).rounded(.down)) + 1))
        case .last24h:
            let width: TimeInterval = 3600
            let hour = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / width).rounded(.down) * width)
            return (hour.addingTimeInterval(-23 * width), width, 24)
        case .last7d:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-6 * 86400)
            let width: TimeInterval = 3 * 3600
            return (start, width, max(1, Int((now.timeIntervalSince(start) / width).rounded(.down)) + 1))
        }
    }
}

/// Clock-aligned recent buckets. `start` is the oldest bucket's start.
public struct RecentUsage: Sendable, Equatable {
    public var start: Date, width: TimeInterval, count: Int
    public var byProvider: [Provider: [UsageTotals]]
    /// Newest record in the whole store, to tell "nothing happened" from "recording stopped".
    public var latestRecord: Date?
    /// Estimated API-list cost of the same period per provider (priced per model); nil when not computed.
    public var cost: [Provider: CostEstimate]? = nil
    public var totalCost: CostEstimate? { cost.map { $0.values.reduce(CostEstimate(), +) } }
    public init(start: Date, width: TimeInterval, count: Int, byProvider: [Provider: [UsageTotals]]) {
        self.start = start; self.width = width; self.count = count; self.byProvider = byProvider
    }
    public func tokens(_ p: Provider) -> [Int64] { byProvider[p]?.map(\.total) ?? Array(repeating: 0, count: count) }
    public func totals(_ p: Provider) -> UsageTotals { byProvider[p]?.reduce(UsageTotals(), +) ?? UsageTotals() }
    /// All providers summed over the whole window.
    public var totals: UsageTotals { byProvider.values.flatMap { $0 }.reduce(UsageTotals(), +) }

    /// The recorder is behind when the hub served requests in the last 20 minutes but nothing was
    /// recorded in that time; the totals would then undercount while looking current.
    public func isStale(hubRecentRequests: Int64, now: Date = Date()) -> Bool {
        guard hubRecentRequests > 0 else { return false }
        guard let last = latestRecord else { return true }
        return now.timeIntervalSince(last) > 20 * 60
    }
}

/// Reads snapshots of a `requests` table (Proxy Deck schema, `ts` in epoch milliseconds).
/// Never writes, checkpoints, or creates sidecars beside the source database.
public struct SQLiteUsageSource: UsageSource {
    public let path: String
    public init(path: String) { self.path = path; _ = UsageSnapshots.shared }

    /// Proxy Deck's store (its launch agent writes it; we only read).
    public static let proxyDeckPath = NSHomeDirectory() + "/.t3/scratch/2026-10-29-search-a-thread-on-t3-6ad5e6d1/.data/usage.sqlite"

    static let sums = """
        COUNT(*), COALESCE(SUM(failed),0), COALESCE(SUM(total),0), COALESCE(SUM(input),0), COALESCE(SUM(output),0),
        COALESCE(SUM(reasoning),0), COALESCE(SUM(CASE WHEN cache_read > 0 THEN cache_read ELSE cached END),0), COALESCE(SUM(cache_creation),0)
        """

    public func daily(days: Int, now: Date = Date(), calendar: Calendar = .current) throws(UsageError) -> [UsageDay] {
        let today = calendar.startOfDay(for: now)
        // days + 1 midnights: boundaries[i] ..< boundaries[i+1] is day i. Built with the calendar so DST days are 23/25h.
        var bounds: [Date] = []
        for i in stride(from: days - 1, through: -1, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            bounds.append(calendar.startOfDay(for: d))
        }
        var out = bounds.dropLast().map { UsageDay(date: $0) }
        let ms = bounds.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        let connection = try open()
        let db = connection.db
        defer { connection.close() }
        // Local-day index computed in SQL by a function bound to these boundaries, so GROUP BY is per local day.
        let box = Unmanaged.passRetained(Bounds(ms))
        defer { box.release() }
        sqlite3_create_function_v2(db, "t3_day", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, box.toOpaque(), { ctx, _, argv in
            let b = Unmanaged<Bounds>.fromOpaque(sqlite3_user_data(ctx)!).takeUnretainedValue()
            sqlite3_result_int64(ctx, Int64(b.index(sqlite3_value_int64(argv![0]!))))
        }, nil, nil, nil)
        let sql = "SELECT t3_day(ts) AS d, provider, \(Self.sums) FROM requests WHERE ts >= ?1 AND ts < ?2 GROUP BY d, provider"
        try query(db, sql, [ms.first ?? 0, ms.last ?? 0]) { s in
            let d = Int(sqlite3_column_int64(s, 0))
            guard out.indices.contains(d) else { return }
            let p = Provider(raw: text(s, 1))
            out[d].byProvider[p] = (out[d].byProvider[p] ?? UsageTotals()) + totals(s, from: 2)
        }
        return out
    }

    public func breakdown(day: Date, calendar: Calendar = .current) throws(UsageError) -> [UsageBreakdownRow] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try breakdown(start: start, end: end)
    }

    public func rangeDetail(days: Int, now: Date = Date(), calendar: Calendar = .current) throws(UsageError) -> UsageRangeDetail {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - min(30, max(1, days)), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return UsageRangeDetail(rows: []) }
        return UsageRangeDetail(rows: try breakdown(start: start, end: end))
    }

    public func accountSummary(provider: Provider, accountKey: String, windowStart: Date?,
                               now: Date = Date(), calendar: Calendar = .current) throws(UsageError) -> AccountUsageSummary {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<30).compactMap { calendar.date(byAdding: .day, value: $0 - 29, to: today) }
        guard let first = dates.first, let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw .unreadable("Cannot determine local day boundaries.")
        }
        let bounds = (dates + [end]).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        var result = AccountUsageAccumulator(dates: dates, provider: provider, hasWindow: windowStart != nil)
        let connection = try open()
        let db = connection.db
        defer { connection.close() }
        let box = Unmanaged.passRetained(Bounds(bounds))
        defer { box.release() }
        sqlite3_create_function_v2(db, "t3_day", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, box.toOpaque(), { ctx, _, argv in
            let b = Unmanaged<Bounds>.fromOpaque(sqlite3_user_data(ctx)!).takeUnretainedValue()
            sqlite3_result_int64(ctx, Int64(b.index(sqlite3_value_int64(argv![0]!))))
        }, nil, nil, nil)
        let sql = """
            SELECT t3_day(ts) AS d, COALESCE(model,''), ts >= ?3 AS in_window, \(Self.sums)
            FROM requests WHERE ts >= ?1 AND ts <= ?2 AND
              (CASE WHEN lower(provider) IN ('claude','codex') THEN lower(provider) ELSE 'other' END) = ?4
              AND account_key = ?5
            GROUP BY d, 2, in_window
            """
        let start = min(first, windowStart ?? first)
        let args = [Int64(ceil(start.timeIntervalSince1970 * 1000)), Int64(floor(now.timeIntervalSince1970 * 1000)),
                    Int64(ceil((windowStart ?? now).timeIntervalSince1970 * 1000))]
        try query(db, sql, args, strings: [provider.rawValue, accountKey]) { s in
            result.add(day: Int(sqlite3_column_int64(s, 0)), inWindow: sqlite3_column_int64(s, 2) != 0,
                       model: text(s, 1), totals: totals(s, from: 3))
        }
        return result.summary
    }

    /// Estimated cost per provider for requests in [start, end), summed per model.
    public func costs(start: Date, end: Date) throws(UsageError) -> [Provider: CostEstimate] {
        var out: [Provider: CostEstimate] = [:]
        for row in try breakdown(start: start, end: end) where row.totals.total > 0 || row.totals.requests > 0 {
            out[row.provider, default: CostEstimate()].add(row.estimatedCost, model: row.model)
        }
        return out
    }

    private func breakdown(start: Date, end: Date) throws(UsageError) -> [UsageBreakdownRow] {
        let connection = try open()
        let db = connection.db
        defer { connection.close() }
        let sql = "SELECT provider, COALESCE(model,''), COALESCE(account_key,''), \(Self.sums) FROM requests WHERE ts >= ?1 AND ts < ?2 GROUP BY 1, 2, 3"
        var rows: [String: UsageBreakdownRow] = [:]   // providers outside claude/codex fold into "other"
        try query(db, sql, [Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000)]) { s in
            let r = UsageBreakdownRow(provider: Provider(raw: text(s, 0)), model: text(s, 1), accountKey: text(s, 2), totals: totals(s, from: 3))
            rows[r.id] = rows[r.id].map { var x = $0; x.totals = x.totals + r.totals; return x } ?? r
        }
        return rows.values.sorted { ($0.totals.total, $0.totals.requests, $0.id) > ($1.totals.total, $1.totals.requests, $1.id) }
    }

    public func recent(count: Int, width: TimeInterval = 600, now: Date = Date()) throws(UsageError) -> RecentUsage {
        let w = Int64(width * 1000), nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        return try series(startMs: (nowMs / w + 1 - Int64(count)) * w, widthMs: w, count: count)
    }

    public func series(start: Date, width: TimeInterval, count: Int) throws(UsageError) -> RecentUsage {
        try series(startMs: Int64((start.timeIntervalSince1970 * 1000).rounded(.down)), widthMs: Int64(width * 1000), count: count)
    }

    private func series(startMs start: Int64, widthMs w: Int64, count: Int) throws(UsageError) -> RecentUsage {
        let width = Double(w) / 1000
        var out = RecentUsage(start: Date(timeIntervalSince1970: Double(start) / 1000), width: width, count: count, byProvider: [:])
        let connection = try open()
        let db = connection.db
        defer { connection.close() }
        let sql = "SELECT (ts - ?1) / ?3 AS b, provider, \(Self.sums) FROM requests WHERE ts >= ?1 AND ts < ?2 GROUP BY b, provider"
        try query(db, sql, [start, start + Int64(count) * w, w]) { s in
            let b = Int(sqlite3_column_int64(s, 0))
            guard b >= 0, b < count else { return }
            let p = Provider(raw: text(s, 1))
            var series = out.byProvider[p] ?? Array(repeating: UsageTotals(), count: count)
            series[b] = series[b] + totals(s, from: 2)
            out.byProvider[p] = series
        }
        try query(db, "SELECT MAX(ts) FROM requests", []) { s in
            if sqlite3_column_type(s, 0) != SQLITE_NULL { out.latestRecord = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)) / 1000) }
        }
        return out
    }

    // MARK: SQLite

    private struct Connection {
        let db: OpaquePointer
        let snapshot: UsageSnapshot?
        func close() { sqlite3_close_v2(db); withExtendedLifetime(snapshot) {} }
    }

    private func open() throws(UsageError) -> Connection {
        guard FileManager.default.isReadableFile(atPath: path) else { throw .missing }
        for attempt in 0..<2 {
            let snapshot = try UsageSnapshots.shared.snapshot(path: path, fresh: attempt > 0)
            do {
                return try checkedOpen(snapshot.file.path, snapshot: snapshot)
            } catch {
                guard Self.isCorruption(error) else { throw error }
            }
        }
        // Last resort: immutable only reads the original main file and NEVER opens its sidecars.
        return try checkedOpen(path, snapshot: nil, immutable: true)
    }

    private static func isCorruption(_ error: UsageError) -> Bool {
        guard case .unreadable(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("malformed") || lower.contains("corrupt") || lower.contains("not a database")
    }

    private func checkedOpen(_ file: String, snapshot: UsageSnapshot?, immutable: Bool = false) throws(UsageError) -> Connection {
        var comps = URLComponents(); comps.scheme = "file"; comps.path = file
        comps.queryItems = [URLQueryItem(name: "mode", value: immutable ? "ro" : "rw")] + (immutable ? [URLQueryItem(name: "immutable", value: "1")] : [])
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(comps.string ?? file, &handle, (immutable ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle); throw .unreadable(message)
        }
        sqlite3_busy_timeout(db, 2000)
        do {
            var healthy = false
            // A bounded check catches a torn main/WAL copy before any result escapes to the caller.
            try query(db, "PRAGMA quick_check(1)", []) { healthy = text($0, 0) == "ok" }
            guard healthy else { throw UsageError.unreadable("malformed usage database snapshot") }
            try query(db, "SELECT \(Self.sums) FROM (SELECT * FROM requests LIMIT 1)", []) { _ in }
            return Connection(db: db, snapshot: snapshot)
        } catch let error as UsageError { sqlite3_close_v2(db); throw error }
        catch { sqlite3_close_v2(db); throw .unreadable(error.localizedDescription) }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [Int64], strings: [String] = [], _ row: (OpaquePointer) -> Void) throws(UsageError) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw .unreadable(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), a) }
        for (i, value) in strings.enumerated() {
            _ = value.withCString { sqlite3_bind_text(s, Int32(args.count + i + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { row(s); continue }
            if rc == SQLITE_DONE { return }
            throw .unreadable(String(cString: sqlite3_errmsg(db)))
        }
    }
    private func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private func totals(_ s: OpaquePointer, from i: Int32) -> UsageTotals {
        var t = UsageTotals()
        t.requests = Int(sqlite3_column_int64(s, i)); t.failed = Int(sqlite3_column_int64(s, i + 1))
        t.total = sqlite3_column_int64(s, i + 2); t.input = sqlite3_column_int64(s, i + 3); t.output = sqlite3_column_int64(s, i + 4)
        t.reasoning = sqlite3_column_int64(s, i + 5); t.cached = sqlite3_column_int64(s, i + 6); t.cacheCreation = sqlite3_column_int64(s, i + 7)
        return t
    }
}

/// A lease keeps an old snapshot alive until its last SQLite connection closes.
final class UsageSnapshot: Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent("usage.sqlite") }
    init(directory: URL) { self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class UsageSnapshots: @unchecked Sendable {
    static let shared = UsageSnapshots()
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
    }
    private struct Entry {
        let snapshot: UsageSnapshot
        let created: Date
        let stamps: [Stamp?]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let root: URL
    private let now: @Sendable () -> Date
    static let sizeLimit: UInt64 = 512 * 1024 * 1024
    init(root: URL = FileManager.default.temporaryDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.now = now
        // Initialized when UsageModel creates its first source at launch. Remove abandoned copies.
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where directory.lastPathComponent.hasPrefix("T3Proxy-usage-") {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == 2
    }
    private func stamp(_ path: String) throws -> Stamp? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return Stamp(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: attrs[.modificationDate] as? Date ?? .distantPast)
        } catch where Self.isMissing(error) { return nil }
    }
    func snapshot(path: String, fresh: Bool = false) throws(UsageError) -> UsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        do {
            let stamps = try [stamp(path), stamp(path + "-wal")]
            guard stamps[0] != nil else { throw UsageError.missing }
            guard stamps.compactMap({ $0 }).reduce(UInt64(0), { $0 + min($1.size, Self.sizeLimit + 1) }) <= Self.sizeLimit else {
                throw UsageError.unreadable("usage database too large")
            }
            let date = now()
            // Refresh only after BOTH 30 seconds have elapsed and the source changed.
            if !fresh, let entry = entries[path], date.timeIntervalSince(entry.created) < 30 || entry.stamps == stamps {
                return entry.snapshot
            }
            let directory = root.appendingPathComponent("T3Proxy-usage-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let snapshot = UsageSnapshot(directory: directory)
            try copyBounded(path, to: snapshot.file)
            // The WAL may disappear between stat and open. A main-only snapshot is still safe;
            // SQLite validation below decides whether a fresh copy/immutable fallback is needed.
            do { try copyBounded(path + "-wal", to: directory.appendingPathComponent("usage.sqlite-wal")) }
            catch where Self.isMissing(error) { }
            let entry = Entry(snapshot: snapshot, created: date, stamps: stamps)
            entries[path] = entry
            return snapshot
        } catch let error as UsageError { throw error }
        catch { throw .unreadable(error.localizedDescription) }
    }
    private func copyBounded(_ source: String, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        defer { try? input.close() }
        // Stream a bounded number of bytes, even if a writer grows the WAL during the copy.
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UsageError.unreadable("Could not create usage snapshot")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            copied += UInt64(data.count)
            guard copied <= Self.sizeLimit else { throw UsageError.unreadable("usage database too large") }
            try output.write(contentsOf: data)
        }
    }
}

private final class Bounds {
    let ms: [Int64]
    init(_ ms: [Int64]) { self.ms = ms }
    /// Index i with ms[i] <= t < ms[i+1], or -1.
    func index(_ t: Int64) -> Int {
        guard let f = ms.first, let l = ms.last, t >= f, t < l else { return -1 }
        var lo = 0, hi = ms.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if ms[m] <= t { lo = m } else { hi = m } }
        return lo
    }
}

/// GitHub-style intensity 0...4 relative to the busiest day (square-root scaled so quiet days still show).
public func usageLevel(_ v: Int64, max m: Int64) -> Int {
    guard v > 0, m > 0 else { return 0 }
    return min(4, max(1, Int((sqrt(Double(v) / Double(m)) * 4).rounded(.up))))
}

/// Compact token count: 1.2B, 84M, 950K.
public func compactTokens(_ v: Int64) -> String {
    let d = Double(v)
    for (s, u) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where d >= s {
        let x = d / s
        return (x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)).replacingOccurrences(of: ".0", with: "") + u
    }
    return "\(v)"
}

/// Per-account aggregation across models, retaining the unpriced-model caveat.
public struct UsageAccountCost: Sendable, Equatable, Identifiable {
    public var provider: Provider
    public var accountKey: String
    public var totals = UsageTotals()
    public var cost = CostEstimate()
    public var id: String { "\(provider.rawValue)|\(accountKey)" }
}

public struct UsageRangeDetail: Sendable, Equatable {
    public var accounts: [UsageAccountCost]
    public var totals: UsageTotals { accounts.reduce(UsageTotals()) { $0 + $1.totals } }
    public var cost: CostEstimate { accounts.reduce(CostEstimate()) { $0 + $1.cost } }
    public init(rows: [UsageBreakdownRow]) {
        var grouped: [String: UsageAccountCost] = [:]
        for row in rows {
            let key = "\(row.provider.rawValue)|\(row.accountKey)"
            var account = grouped[key] ?? UsageAccountCost(provider: row.provider, accountKey: row.accountKey)
            account.totals = account.totals + row.totals
            if row.totals.total > 0 || row.totals.requests > 0 { account.cost.add(row.estimatedCost, model: row.model) }
            grouped[key] = account
        }
        accounts = grouped.values.sorted { ($0.totals.total, $0.id) > ($1.totals.total, $1.id) }
    }
    public func filtered(provider: Provider?) -> Self {
        var result = self
        if let provider { result.accounts = accounts.filter { $0.provider == provider } }
        return result
    }
}

extension UsageSource {
    public func rangeDetail(days: Int, now: Date = Date(), calendar: Calendar = .current) throws(UsageError) -> UsageRangeDetail {
        // Fallback for alternate sources; the SQLite implementation uses one grouped query.
        var rows: [UsageBreakdownRow] = []
        for offset in 0..<min(30, max(1, days)) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) {
                rows += try breakdown(day: day, calendar: calendar)
            }
        }
        return UsageRangeDetail(rows: rows)
    }
}
