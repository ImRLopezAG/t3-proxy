import Foundation
import SQLite3
import Testing
@testable import T3ProxyCore

private func makeDB(_ rows: [(ts: Int64, provider: String, model: String, account: String, total: Int64, failed: Int)], wal: Bool = false) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3usage-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("usage.sqlite").path
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    if wal { sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) }
    sqlite3_exec(db, """
        CREATE TABLE requests (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, account_key TEXT,
          auth_type TEXT, input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cached INTEGER NOT NULL,
          cache_read INTEGER NOT NULL, cache_creation INTEGER NOT NULL, total INTEGER NOT NULL, failed INTEGER NOT NULL, latency_ms INTEGER);
        """, nil, nil, nil)
    for (i, r) in rows.enumerated() {
        sqlite3_exec(db, "INSERT INTO requests VALUES ('\(i)', \(r.ts), '\(r.provider)', '\(r.model)', '\(r.account)', 'oauth', \(r.total / 2), \(r.total / 2), 0, 5, 0, 0, \(r.total), \(r.failed), 10)", nil, nil, nil)
    }
    sqlite3_close(db)
    return path
}

private func cal(_ tz: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c }
private func ms(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Int64 {
    Int64(c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970 * 1000)
}

@Test func usageBucketsByLocalDayAcrossDST() throws {
    // US DST ended 2026-11-01 (25-hour day in New York).
    let c = cal("America/New_York")
    let path = makeDB([
        (ms(c, 2026, 10, 31, 23, 59), "claude", "m", "a", 100, 0),
        (ms(c, 2026, 11, 1, 0, 1), "claude", "m", "a", 10, 0),
        (ms(c, 2026, 11, 1, 23, 30), "codex", "x", "b", 20, 1),   // after the repeated 1am hour, still Nov 1
        (ms(c, 2026, 11, 2, 0, 0), "claude", "m", "a", 1, 0),
    ])
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    let days = try SQLiteUsageSource(path: path).daily(days: 3, now: now, calendar: c)
    #expect(days.count == 3)
    #expect(days.map { c.component(.day, from: $0.date) } == [31, 1, 2])
    #expect(days.map { $0.totals.total } == [100, 30, 1])
    #expect(days[1].byProvider[.claude]?.total == 10)
    #expect(days[1].byProvider[.codex]?.total == 20)
    #expect(days[1].totals.failed == 1 && days[1].totals.requests == 2)
    // Same instants in UTC fall on different days.
    let utc = try SQLiteUsageSource(path: path).daily(days: 4, now: now, calendar: cal("UTC"))
    #expect(utc.map { $0.totals.total }.reduce(0, +) == 131)
    #expect(utc[1].totals.total == 0 && utc[2].totals.total == 110)
}

@Test func usageProviderSplitAndBreakdown() throws {
    let c = cal("Asia/Kolkata")   // half-hour offset
    let path = makeDB([
        (ms(c, 2026, 11, 6, 9), "claude", "opus", "k1", 50, 0),
        (ms(c, 2026, 11, 6, 10), "claude", "opus", "k1", 50, 0),
        (ms(c, 2026, 11, 6, 11), "claude", "sonnet", "k2", 30, 0),
        (ms(c, 2026, 11, 6, 12), "Codex", "gpt", "k3", 40, 0),
        (ms(c, 2026, 11, 6, 13), "gemini", "g", "", 7, 0),
        (ms(c, 2026, 11, 6, 0, 10), "claude", "opus", "k1", 1, 0),
        (ms(c, 2026, 11, 5, 23, 50), "claude", "opus", "k1", 1000, 0),   // previous day, outside a 1-day window
    ])
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 20))!
    let src = SQLiteUsageSource(path: path)
    let d = try src.daily(days: 1, now: now, calendar: c)
    #expect(d.count == 1)
    #expect(d[0].byProvider[.claude]?.total == 131)
    #expect(d[0].byProvider[.codex]?.total == 40)
    #expect(d[0].byProvider[.other]?.total == 7)
    #expect(d[0].byProvider[.claude]?.cached == 20)
    let rows = try src.breakdown(day: now, calendar: c)
    #expect(rows.first?.model == "opus" && rows.first?.totals.total == 101 && rows.first?.totals.requests == 3)
    #expect(rows.count == 4)
    #expect(rows.contains { $0.provider == .other && $0.accountKey == "" })
}

@Test func usageMissingAndEmpty() throws {
    let src = SQLiteUsageSource(path: "/nonexistent/\(UUID().uuidString)/usage.sqlite")
    #expect(throws: UsageError.missing) { try src.daily(days: 7, now: Date(), calendar: .current) }
    let empty = try SQLiteUsageSource(path: makeDB([])).daily(days: 7, now: Date(), calendar: .current)
    #expect(empty.count == 7 && empty.allSatisfy { $0.totals.requests == 0 })
    // Not a database at all.
    let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).sqlite")
    try Data("hello".utf8).write(to: junk)
    #expect(throws: UsageError.self) { try SQLiteUsageSource(path: junk.path).daily(days: 7, now: Date(), calendar: .current) }
}

@Test func usageReadsWALWhileWriterOpenWithoutCreatingFiles() throws {
    let c = Calendar.current
    let now = Date()
    let path = makeDB([], wal: true)
    let dir = (path as NSString).deletingLastPathComponent
    // Writer stays open with uncheckpointed rows in the WAL.
    var w: OpaquePointer?
    sqlite3_open(path, &w)
    sqlite3_exec(w, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
    sqlite3_exec(w, "INSERT INTO requests VALUES ('w', \(Int64(now.timeIntervalSince1970 * 1000)), 'claude', 'm', 'a', 'oauth', 1, 1, 0, 0, 0, 0, 42, 0, 1)", nil, nil, nil)
    let before = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    let stamps = try usageDirectoryStamps(path)
    let shm = try Data(contentsOf: URL(fileURLWithPath: path + "-shm"))
    let d = try SQLiteUsageSource(path: path).daily(days: 1, now: now, calendar: c)
    #expect(d[0].totals.total == 42)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == before)
    #expect(try usageDirectoryStamps(path) == stamps)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "-shm")) == shm)
    sqlite3_close(w)
    // Writer gone (WAL/SHM removed on close): snapshot read, still no source files created.
    let after = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    let afterStamps = try usageDirectoryStamps(path)
    #expect(try SQLiteUsageSource(path: path).daily(days: 1, now: now, calendar: c)[0].totals.total == 42)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == after)
    #expect(try usageDirectoryStamps(path) == afterStamps)
}

@Test func usageWALWithoutSHMCreatesNoFiles() throws {
    let path = makeDB([], wal: true)
    // A leftover WAL with no -shm: a plain mode=ro open would create -shm here.
    FileManager.default.createFile(atPath: path + "-wal", contents: Data())
    try? FileManager.default.removeItem(atPath: path + "-shm")
    let before = try usageDirectoryStamps(path)
    _ = try SQLiteUsageSource(path: path).daily(days: 1, now: Date(), calendar: .current)
    #expect(try usageDirectoryStamps(path) == before)
}

@Test func recentUsageStaleness() {
    let now = Date()
    var r = RecentUsage(start: now, width: 600, count: 20, byProvider: [:])
    #expect(!r.isStale(hubRecentRequests: 0, now: now))          // nothing to record
    #expect(r.isStale(hubRecentRequests: 3, now: now))           // hub busy, store empty
    r.latestRecord = now.addingTimeInterval(-60)
    #expect(!r.isStale(hubRecentRequests: 3, now: now))
    r.latestRecord = now.addingTimeInterval(-3600)
    #expect(r.isStale(hubRecentRequests: 3, now: now))
}

@Test func usageLevelsAndCompact() {
    #expect(usageLevel(0, max: 100) == 0)
    #expect(usageLevel(1, max: 100) == 1)
    #expect(usageLevel(100, max: 100) == 4)
    #expect(compactTokens(1_234_000_000) == "1.2B")
    #expect(compactTokens(84_000_000) == "84M")
    #expect(compactTokens(950) == "950")
}

@Test func recentBucketsAlignToClock() throws {
    let w: Int64 = 600_000
    let now = Date(timeIntervalSince1970: Double(1_000 * w + 123_456) / 1000)   // inside bucket 1000
    let start = (1_000 - 19) * w
    let path = makeDB([
        (start - 1, "claude", "m", "a", 7, 0),            // just before the window
        (start, "claude", "m", "a", 10, 0),               // first bucket, first ms
        (start + w - 1, "codex", "x", "b", 20, 0),        // first bucket, last ms
        (start + w, "claude", "m", "a", 30, 1),           // second bucket
        (1_000 * w + 100_000, "codex", "x", "b", 40, 0),  // newest bucket
        (1_001 * w, "claude", "m", "a", 99, 0),           // after the window
    ])
    let r = try SQLiteUsageSource(path: path).recent(count: 20, width: 600, now: now)
    #expect(r.start == Date(timeIntervalSince1970: Double(start) / 1000))
    let c = r.tokens(.claude), x = r.tokens(.codex)
    #expect(c.count == 20 && x.count == 20)
    #expect(c[0] == 10 && c[1] == 30 && c.reduce(0, +) == 40)
    #expect(x[0] == 20 && x[19] == 40 && x.reduce(0, +) == 60)
    #expect(r.totals.total == 100 && r.totals.requests == 4 && r.totals.failed == 1)
    #expect(r.totals(.claude).input == 20)
}

@Test func recentEmptyAndMissing() throws {
    let r = try SQLiteUsageSource(path: makeDB([])).recent(count: 20, width: 600, now: Date())
    #expect(r.tokens(.claude) == Array(repeating: 0, count: 20) && r.tokens(.codex) == Array(repeating: 0, count: 20))
    #expect(r.totals.total == 0)
    #expect(throws: UsageError.missing) { try SQLiteUsageSource(path: "/nonexistent/usage.sqlite").recent(count: 20, width: 600, now: Date()) }
}

@Test func tokenRangePlansAreCumulativeAndEndNow() {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Puerto_Rico")!
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 47))!
    let today = TokenRange.today.plan(now: now, calendar: c)
    #expect(today.start == c.startOfDay(for: now))
    #expect(today.start.addingTimeInterval(Double(today.count) * today.width) > now)          // last bucket holds now
    #expect(today.start.addingTimeInterval(Double(today.count - 1) * today.width) <= now)
    let day = TokenRange.last24h.plan(now: now, calendar: c)
    #expect(day.count == 24); #expect(day.start.addingTimeInterval(24 * 3600) > now)
    let week = TokenRange.last7d.plan(now: now, calendar: c)
    #expect(week.start == c.date(byAdding: .day, value: -6, to: c.startOfDay(for: now)))
}

@Test func seriesSumsFromRangeStart() throws {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    let midnight = c.startOfDay(for: now)
    let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
    let path = makeDB([(ms(midnight.addingTimeInterval(-60)), "claude", "m", "a", 1000, 0),     // yesterday: excluded
                       (ms(midnight), "claude", "m", "a", 10, 0),
                       (ms(now.addingTimeInterval(-5)), "codex", "m", "b", 7, 0)])
    let p = TokenRange.today.plan(now: now, calendar: c)
    let r = try SQLiteUsageSource(path: path).series(start: p.start, width: p.width, count: p.count)
    #expect(r.totals(.claude).total == 10); #expect(r.totals(.codex).total == 7); #expect(r.totals.total == 17)
}

@Test func usageRangeCostsAreBoundedAndGroupedByAccount() throws {
    let c = cal("America/New_York")
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    let path = makeDB([
        (ms(c, 2026, 11, 6, 0), "claude", "claude-sonnet-5-5", "a", 1000, 0),
        (ms(c, 2026, 11, 1, 23), "claude", "unpriced", "a", 100, 0),
        (ms(c, 2026, 10, 31, 0), "codex", "unpriced", "b", 10, 0),
        (ms(c, 2026, 10, 30, 23, 59), "claude", "unpriced", "a", 20, 0),
        (ms(c, 2026, 10, 8, 0), "codex", "unpriced", "b", 30, 0),
        (ms(c, 2026, 10, 7, 23, 59), "claude", "unpriced", "a", 50, 0),
        (ms(c, 2026, 11, 7, 0), "claude", "unpriced", "a", 999, 0),
    ])
    let source: any UsageSource = SQLiteUsageSource(path: path)
    let today = try source.rangeDetail(days: 1, now: now, calendar: c)
    let week = try source.rangeDetail(days: 7, now: now, calendar: c)
    let month = try source.rangeDetail(days: 30, now: now, calendar: c)
    #expect(today.totals.total == 1000)
    #expect(week.totals.total == 1110 && week.totals.requests == 3)
    #expect(month.totals.total == 1160 && month.totals.requests == 5)
    #expect(week.accounts.count == 2)
    #expect(week.accounts.first?.totals.total == 1100)
    #expect(week.cost.usd == today.cost.usd)
    #expect(today.cost.usd > 0)
    #expect(week.cost.unpriced == ["unpriced"])
    #expect(week.filtered(provider: .codex).totals.total == 10)
    #expect(try source.rangeDetail(days: 365, now: now, calendar: c) == month)
}

private struct UsageFileStamp: Equatable {
    let size: UInt64
    let modified: Date
}
private func usageDirectoryStamps(_ path: String) throws -> [String: UsageFileStamp] {
    let dir = (path as NSString).deletingLastPathComponent
    return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: dir).map { name in
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/" + name)
        return (name, UsageFileStamp(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                     modified: attrs[.modificationDate] as? Date ?? .distantPast))
    })
}

@Test func usageRefusesOversizedDatabase() throws {
    let path = makeDB([])
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try file.truncate(atOffset: 512 * 1024 * 1024 + 1)
    try file.close()
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    #expect(throws: UsageError.unreadable("usage database too large")) {
        try SQLiteUsageSource(path: path).daily(days: 1)
    }
}

private final class UsageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func date() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

@Test func usageSnapshotsReuseThenReplaceAndCleanUp() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("snapshot-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let stale = root.appendingPathComponent("T3Proxy-usage-abandoned")
    try fm.createDirectory(at: stale, withIntermediateDirectories: false)
    let clock = UsageTestClock()
    let cache = UsageSnapshots(root: root, now: { clock.date() })
    #expect(!fm.fileExists(atPath: stale.path))
    let path = makeDB([])
    var first: UsageSnapshot? = try cache.snapshot(path: path)
    let oldDirectory = try #require(first?.directory)
    #expect(try fm.attributesOfItem(atPath: oldDirectory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try cache.snapshot(path: path).directory == oldDirectory)
    // A source change alone does not cause a copy within the minimum reuse window.
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: path)
    clock.advance(29)
    #expect(try cache.snapshot(path: path).directory == oldDirectory)
    clock.advance(2)
    let replacement = try cache.snapshot(path: path)
    #expect(replacement.directory != oldDirectory)
    #expect(fm.fileExists(atPath: oldDirectory.path)) // leased by a still-open reader
    first = nil
    #expect(!fm.fileExists(atPath: oldDirectory.path))
    clock.advance(100)
    #expect(try cache.snapshot(path: path).directory == replacement.directory) // unchanged: keep it
}

@Test func usageRetriesCorruptSnapshotWithoutTouchingSource() throws {
    let path = makeDB([])
    let before = try usageDirectoryStamps(path)
    var bad: UsageSnapshot? = try UsageSnapshots.shared.snapshot(path: path)
    let old = try #require(bad?.directory)
    try Data("not a database".utf8).write(to: try #require(bad?.file))
    bad = nil
    let result = try SQLiteUsageSource(path: path).daily(days: 1)
    #expect(result.count == 1 && result[0].totals.requests == 0)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(try usageDirectoryStamps(path) == before)
}

@Test func usageSidecarsVanishBetweenReadsWithoutBeingRecreated() throws {
    let path = makeDB([], wal: true)
    FileManager.default.createFile(atPath: path + "-wal", contents: Data())
    FileManager.default.createFile(atPath: path + "-shm", contents: Data(repeating: 0, count: 32768))
    let source = SQLiteUsageSource(path: path)
    let before = try usageDirectoryStamps(path)
    _ = try source.daily(days: 1)
    #expect(try usageDirectoryStamps(path) == before)
    try FileManager.default.removeItem(atPath: path + "-wal")
    try FileManager.default.removeItem(atPath: path + "-shm")
    let vanished = try usageDirectoryStamps(path)
    _ = try source.daily(days: 1)
    _ = try UsageSnapshots.shared.snapshot(path: path, fresh: true)
    _ = try source.recent(count: 20)
    #expect(try usageDirectoryStamps(path) == vanished)
}

@Test func usageFallsBackToImmutableMainAfterTwoMalformedWALCopies() throws {
    let path = makeDB([], wal: true)
    var writer: OpaquePointer?
    #expect(sqlite3_open(path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    // Keep a malformed schema confined to the WAL. The checkpointed main file remains valid.
    #expect(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0; PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK)
    try malformWALSchema(path + "-wal")
    // Prove this fixture really fails through SQLite with its WAL, rather than silently
    // ignoring an invalid WAL checksum and returning the checkpointed main file.
    let snapshot = try UsageSnapshots.shared.snapshot(path: path)
    var copied: OpaquePointer?
    _ = sqlite3_open(snapshot.file.path, &copied)
    #expect(sqlite3_exec(copied, "SELECT COUNT(*) FROM requests", nil, nil, nil) != SQLITE_OK)
    #expect(String(cString: sqlite3_errmsg(copied)).contains("malformed"))
    sqlite3_close(copied)
    let stamps = try usageDirectoryStamps(path)
    let shm = try Data(contentsOf: URL(fileURLWithPath: path + "-shm"))
    let result = try SQLiteUsageSource(path: path).daily(days: 1)
    #expect(result.count == 1 && result[0].totals.requests == 0)
    #expect(try usageDirectoryStamps(path) == stamps)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "-shm")) == shm)
}

/// Preserve valid WAL checksums while making the page-one schema unparsable. Apple SQLite
/// disables writable_schema, so build this corruption fixture at the file-format boundary.
private func malformWALSchema(_ path: String) throws {
    var wal = try Data(contentsOf: URL(fileURLWithPath: path))
    func word(_ offset: Int, little: Bool = false) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, i in
            result | (UInt32(wal[offset + i]) << (little ? i * 8 : (3 - i) * 8))
        }
    }
    func store(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { wal[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
    }
    let little = word(0) == 0x377f0682
    let pageSize = Int(word(8))
    var s0 = word(24), s1 = word(28)
    var mutated = false
    for frame in stride(from: 32, to: wal.count, by: 24 + pageSize) {
        let payload = (frame + 24)..<(frame + 24 + pageSize)
        if word(frame) == 1, let range = wal.range(of: Data("CREATE TABLE requests".utf8), in: payload) {
            wal.replaceSubrange(range, with: Data("BROKEN TABLE requests".utf8))
            mutated = true
        }
        for range in [frame..<(frame + 8), payload] {
            for offset in stride(from: range.lowerBound, to: range.upperBound, by: 8) {
                s0 = s0 &+ word(offset, little: little) &+ s1
                s1 = s1 &+ word(offset + 4, little: little) &+ s0
            }
        }
        store(s0, at: frame + 16); store(s1, at: frame + 20)
    }
    #expect(mutated)
    try wal.write(to: URL(fileURLWithPath: path))
}

@Test func accountSummaryFiltersAccountAndProviderAndPadsDays() throws {
    let c = cal("America/New_York")
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    let start = c.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    let path = makeDB([
        (ms(c, 2026, 10, 4, 0), "claude", "claude-opus-5-5", "a", 100, 0),
        (ms(c, 2026, 11, 1, 1), "claude", "claude-opus-5-5", "a", 200, 0),
        (ms(c, 2026, 11, 1, 23), "claude", "claude-opus-5-5", "a", 400, 1),
        (ms(c, 2026, 11, 2, 10), "claude", "unpriced", "a", 600, 0),
        (ms(c, 2026, 11, 2, 11), "claude", "claude-opus-5-5", "a", 800, 0),
        (ms(c, 2026, 11, 2, 10), "claude", "claude-opus-5-5", "b", 10000, 0),
        (ms(c, 2026, 11, 2, 10), "codex", "gpt-6.1-sol", "a", 20000, 0),
        (ms(c, 2026, 11, 2, 13), "claude", "claude-opus-5-5", "a", 40000, 0),
        (ms(c, 2026, 10, 3, 23), "claude", "claude-opus-5-5", "a", 50000, 0),
    ])
    defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
    let source: any UsageSource = SQLiteUsageSource(path: path)
    let s = try source.accountSummary(provider: .claude, accountKey: "a", windowStart: start, now: now, calendar: c)
    #expect(s.days.count == 30)
    #expect(s.days.first?.date == c.date(from: DateComponents(year: 2026, month: 10, day: 4)))
    #expect(s.days.last?.date == c.startOfDay(for: now))
    #expect(s.days.filter { $0.totals.requests == 0 }.count == 27)
    #expect(s.days.suffix(2).map(\.totals.total) == [600, 1400])
    #expect(s.today.total == 1400 && s.today.requests == 2)
    #expect(s.last30.total == 2100 && s.last30.requests == 5)
    #expect(s.window?.total == 1800 && s.window?.failed == 1)
    #expect(s.models.map(\.model) == ["claude-opus-5-5", "unpriced"])
    #expect(s.models.map(\.totals.total) == [1500, 600])
    #expect(s.last30Cost.unpriced == ["unpriced"] && s.windowCost?.unpriced == ["unpriced"])
    // 750 input, 750 output and 4 × 5 cache-read tokens at $4/$20/$0.20 per million.
    #expect(abs(s.last30Cost.usd - 0.018004) < 1e-10)
    #expect(abs(s.todayCost.usd - 0.009601) < 1e-10)
    #expect(s.days.reduce(CostEstimate(), { $0 + $1.cost }) == s.last30Cost)
    let noWindow = try source.accountSummary(provider: .claude, accountKey: "a", windowStart: nil, now: now, calendar: c)
    #expect(noWindow.window == nil && noWindow.windowCost == nil)
    let empty = try source.accountSummary(provider: .claude, accountKey: "missing' OR 1=1 --", windowStart: now, now: now, calendar: c)
    #expect(empty.last30.requests == 0 && empty.days.count == 30 && empty.window?.requests == 0)
}

@Test func accountSummaryWindowCanPrecedeLast30() throws {
    let c = cal("UTC")
    let path = makeDB([(ms(c, 2026, 9, 1, 1), "claude", "claude-opus-5-5", "a", 100, 0)])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    let start = c.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    let s = try SQLiteUsageSource(path: path).accountSummary(provider: .claude, accountKey: "a", windowStart: start, now: now, calendar: c)
    #expect(s.window?.total == 100 && s.last30.total == 0 && s.models.isEmpty)
    #expect(s.days.count == 30 && s.days.allSatisfy { $0.totals == UsageTotals() && $0.cost == CostEstimate() })
}

@Test func accountUsageKeyMatchesRecorder() {
    #expect(Account(name: "sample", provider: .claude, authIndex: "sample-index").usageKey == PlanCache.accountKey("sample-index"))
    #expect(Account(name: "sample", provider: .claude).usageKey == nil)
    #expect(Account(name: "sample", provider: .claude, authIndex: "").usageKey == nil)
}

@Test func accountSummaryPricesEachModelsFullPeriod() throws {
    let c = cal("UTC")
    let path = makeDB([
        (ms(c, 2026, 11, 1, 10), "codex", "gpt-6.1-sol", "a", 100, 0),
        (ms(c, 2026, 11, 2, 10), "codex", "gpt-6.1-sol", "a", 100, 0),
    ])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "UPDATE requests SET cache_creation=10 WHERE id='1'", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    let start = c.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    let s = try SQLiteUsageSource(path: path).accountSummary(provider: .codex, accountKey: "a", windowStart: start, now: now, calendar: c)
    #expect(s.days[28].cost.usd > 0)
    #expect(s.last30Cost == CostEstimate(unpriced: ["gpt-6.1-sol"]))
    #expect(s.windowCost == CostEstimate(unpriced: ["gpt-6.1-sol"]))
    #expect(s.models.first?.cost == nil)
}

@Test func rangeCostsArePricedPerModelAndBoundedByThePeriod() throws {
    let c = cal("UTC")
    let path = makeDB([
        (ms(c, 2026, 11, 2, 9), "claude", "claude-opus-5-5", "a", 1_000_000, 0),
        (ms(c, 2026, 11, 2, 10), "claude", "claude-opus-5-5", "b", 1_000_000, 0),
        (ms(c, 2026, 11, 2, 11), "codex", "unpriced-model", "a", 500, 0),
        (ms(c, 2026, 11, 1, 23), "claude", "claude-opus-5-5", "a", 9_000_000, 0),   // before the period
    ])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let start = c.date(from: DateComponents(year: 2026, month: 11, day: 2))!
    let costs = try SQLiteUsageSource(path: path).costs(start: start, end: start.addingTimeInterval(86400))
    let single = Pricing.cost({ var u = UsageTotals(); u.total = 1_000_000; u.input = 500_000; u.output = 500_000; u.reasoning = 5; u.requests = 10; return u }(), model: "claude-opus-5-5")
    if let single { #expect(abs((costs[.claude]?.usd ?? 0) - 2 * single) < 0.0001) } else { #expect(costs[.claude]?.unpriced == ["claude-opus-5-5"]) }
    #expect(costs[.codex]?.unpriced == ["unpriced-model"])
}

@Test func accountSummaryDispatchesThroughTheProtocol() throws {
    // Regression: the panel holds `any UsageSource`; the call must reach SQLite's implementation, not the fallback.
    let c = cal("UTC")
    let path = makeDB([(ms(c, 2026, 11, 2, 10), "claude", "claude-opus-5-5", "a", 100, 0)])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let source: any UsageSource = SQLiteUsageSource(path: path)
    let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    let s = try source.accountSummary(provider: .claude, accountKey: "a", windowStart: nil, now: now, calendar: c)
    #expect(s.last30.total == 100)
    #expect(try source.costs(start: now.addingTimeInterval(-86400), end: now)[.claude] != nil)
}

@Test func claudeRowsSavedWithoutACacheWriteSplitGetItFromTheRemainder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("usage.sqlite").path
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    let now = Date(timeIntervalSince1970: 1_794_312_000), ts = Int64(now.timeIntervalSince1970 * 1000) - 1000
    sqlite3_exec(db, """
        CREATE TABLE requests (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, account_key TEXT,
          auth_type TEXT, input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cached INTEGER NOT NULL,
          cache_read INTEGER NOT NULL, cache_creation INTEGER NOT NULL, total INTEGER NOT NULL, failed INTEGER NOT NULL, latency_ms INTEGER);
        INSERT INTO requests VALUES ('a', \(ts), 'claude', 'claude-opus-5-5', 'k', 'oauth', 0, 1000000, 0, 10000000, 10000000, 0, 12000000, 0, 1);
        INSERT INTO requests VALUES ('b', \(ts), 'claude', 'claude-opus-5-5', 'k', 'oauth', 0, 0, 0, 0, 0, 7, 7, 0, 1);
        INSERT INTO requests VALUES ('c', \(ts), 'codex', 'gpt-6.1-sol', 'k', 'oauth', 1000000, 0, 0, 500000, 500000, 0, 1000000, 0, 1);
        """, nil, nil, nil)
    sqlite3_close(db)
    let detail = try SQLiteUsageSource(path: path).rangeDetail(days: 1, now: now)
    // 'a' hides 1M written tokens in its total; 'b' already has its split and is not counted twice.
    #expect(detail.totals.cacheCreation == 1_000_007)
    // $20 out + $2 read + $5 written (at the 5-minute rate), plus Codex's $1 uncached + $0.05 read.
    #expect(abs(detail.cost.usd - (20 + 2 + 5 + 1 + 0.05 + 7 * 5 / 1_000_000)) < 1e-6)
    #expect(detail.cost.unpriced.isEmpty)
}
