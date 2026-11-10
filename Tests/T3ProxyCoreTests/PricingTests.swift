import Foundation
import SQLite3
import Testing
@testable import T3ProxyCore

private func totals(input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0, creation: Int64 = 0) -> UsageTotals {
    var t = UsageTotals(); t.input = input; t.output = output; t.cached = cached; t.cacheCreation = creation
    t.total = input + output + cached + creation; t.requests = 1
    return t
}

@Test func priceMatchesExactPrefixAndUnknown() {
    #expect(Pricing.price(for: "claude-opus-5-5")?.input == 4)
    #expect(Pricing.price(for: "CLAUDE-OPUS-5-5")?.input == 4)
    #expect(Pricing.price(for: "claude-opus-5")?.input == 5)
    // Dated snapshot and platform prefixes pick the longest family, not "claude-opus-5".
    #expect(Pricing.price(for: "claude-opus-5-5-20261001")?.input == 4)
    #expect(Pricing.price(for: "anthropic.claude-sonnet-5-5")?.output == 10)
    #expect(Pricing.price(for: "claude-fable-5-1@20261001")?.cacheRead == 0.25)
    #expect(Pricing.price(for: "gpt-6.1-sol")?.cacheRead == 0.10)
    // A newer version or a sibling model must not inherit a price.
    #expect(Pricing.price(for: "claude-opus-5-9") == nil)
    #expect(Pricing.price(for: "gpt-6.1-sol-mini") == nil)
    #expect(Pricing.price(for: "gpt-6-astra") == nil)
    #expect(Pricing.price(for: "gpt-6-luna") == nil)
    #expect(Pricing.price(for: "gpt-6.1-terra") == nil)
    #expect(Pricing.price(for: "") == nil)
}

@Test func costUsesCacheRates() throws {
    // Anthropic: input excludes cache. 1M in × $4 + 1M out × $20 + 10M read × $0.20 + 1M write × $5.
    let opus = try #require(Pricing.cost(totals(input: 1_000_000, output: 1_000_000, cached: 10_000_000, creation: 1_000_000), model: "claude-opus-5-5"))
    #expect(abs(opus - (4 + 20 + 2 + 5)) < 1e-9)
    // OpenAI: input includes cached, so only 1M of 3M input is uncached. 1M × $2 + 2M × $0.10 + 0.5M × $10.
    let sol = try #require(Pricing.cost(totals(input: 3_000_000, output: 500_000, cached: 2_000_000), model: "gpt-6.1-sol"))
    #expect(abs(sol - (2 + 0.2 + 5)) < 1e-9)
    // No published cache-write rate → unknown, not guessed.
    #expect(Pricing.cost(totals(input: 10, creation: 10), model: "gpt-6.1-sol") == nil)
    #expect(Pricing.cost(totals(input: 10), model: "gpt-6-astra") == nil)
}

@Test func moneyFormatting() {
    #expect(formatUSD(12.346) == "$12.35")
    #expect(formatUSD(12.3) == "$12.30")
    #expect(formatUSD(1234.4) == "$1,234")
    #expect(formatUSD(1_234_567.8) == "$1,234,568")
    #expect(formatUSD(0.004) == "<$0.01")
    #expect(formatUSD(0) == "$0")
    #expect(CostEstimate(usd: 3.5).label == "≈ $3.50")
    #expect(CostEstimate(usd: 3.5, unpriced: ["gpt-6-astra"]).label == "≈ $3.50 + 1 unpriced model")
    #expect(CostEstimate(usd: 0, unpriced: ["a", "b"]).label == "— (2 unpriced models)")
}

private struct Row { var ts: Int64, provider: String, model: String, account: String, input: Int64, output: Int64, cached: Int64, cacheRead: Int64, creation: Int64, failed: Int = 0 }

private func makeDB(_ rows: [Row]) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3pricing-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("usage.sqlite").path
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    sqlite3_exec(db, """
        CREATE TABLE requests (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, account_key TEXT,
          auth_type TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cached INTEGER NOT NULL,
          cache_read INTEGER NOT NULL, cache_creation INTEGER NOT NULL, total INTEGER NOT NULL, failed INTEGER NOT NULL, latency_ms INTEGER NOT NULL);
        """, nil, nil, nil)
    for (i, r) in rows.enumerated() {
        // Mirrors Proxy Deck: Claude total = input + output + cache_read + cache_creation; Codex input already holds cached.
        let total = r.provider == "codex" ? r.input + r.output : r.input + r.output + r.cacheRead + r.creation
        sqlite3_exec(db, "INSERT INTO requests VALUES ('\(i)', \(r.ts), '\(r.provider)', '\(r.model)', '\(r.account)', 'oauth', \(r.input), \(r.output), 0, \(r.cached), \(r.cacheRead), \(r.creation), \(total), \(r.failed), 10)", nil, nil, nil)
    }
    sqlite3_close(db)
    return path
}

@Test func dayDetailAggregatesProvidersModelsAndCost() throws {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    let day = c.date(from: DateComponents(year: 2026, month: 11, day: 6))!
    let ms = { (h: Int) in Int64(day.addingTimeInterval(Double(h) * 3600).timeIntervalSince1970 * 1000) }
    let path = makeDB([
        // Two accounts on the same Claude model merge into one model row.
        Row(ts: ms(1), provider: "claude", model: "claude-opus-5-5", account: "a", input: 1_000_000, output: 0, cached: 0, cacheRead: 0, creation: 0),
        Row(ts: ms(2), provider: "claude", model: "claude-opus-5-5", account: "b", input: 0, output: 1_000_000, cached: 5_000_000, cacheRead: 5_000_000, creation: 1_000_000),
        Row(ts: ms(3), provider: "codex", model: "gpt-6.1-sol", account: "c", input: 2_000_000, output: 100_000, cached: 1_000_000, cacheRead: 1_000_000, creation: 0),
        Row(ts: ms(4), provider: "codex", model: "gpt-6-astra", account: "c", input: 500_000, output: 0, cached: 0, cacheRead: 0, creation: 0, failed: 1),
        Row(ts: ms(30), provider: "claude", model: "claude-opus-5-5", account: "a", input: 9_999_999, output: 0, cached: 0, cacheRead: 0, creation: 0),   // next day
    ])
    let d = try SQLiteUsageSource(path: path).dayDetail(day: day.addingTimeInterval(3600 * 12), calendar: c)
    #expect(d.date == day)
    #expect(d.rows.count == 4)
    #expect(d.models.map(\.model) == ["claude-opus-5-5", "gpt-6.1-sol", "gpt-6-astra"])
    let opus = try #require(d.models.first)
    #expect(opus.totals.requests == 2 && opus.totals.input == 1_000_000 && opus.totals.cached == 5_000_000 && opus.totals.cacheCreation == 1_000_000)
    // 1M × $4 + 1M × $20 + 5M × $0.20 + 1M × $5 = $30
    #expect(abs((opus.cost ?? 0) - 30) < 1e-9)
    #expect(abs((d.costByProvider[.claude]?.usd ?? 0) - 30) < 1e-9)
    // Codex: Sol = 1M uncached × $2 + 1M cached × $0.10 + 0.1M × $10 = $3.10; Astra is counted, not costed.
    let codex = try #require(d.costByProvider[.codex])
    #expect(abs(codex.usd - 3.1) < 1e-9)
    #expect(codex.unpriced == ["gpt-6-astra"])
    #expect(d.byProvider[.codex]?.requests == 2 && d.byProvider[.codex]?.failed == 1)
    #expect(d.totals.requests == 4)
    #expect(abs(d.cost.usd - 33.1) < 1e-9)
    #expect(d.cost.label == "≈ $33.10 + 1 unpriced model")
    #expect(d.models.first { $0.model == "gpt-6-astra" }?.cost == nil)
}

@Test func dayDetailEmptyAndMissing() throws {
    let d = try SQLiteUsageSource(path: makeDB([])).dayDetail(day: Date())
    #expect(d.models.isEmpty && d.cost == CostEstimate() && d.totals.requests == 0)
    #expect(throws: UsageError.missing) { try SQLiteUsageSource(path: "/nonexistent/\(UUID().uuidString).sqlite").dayDetail(day: Date()) }
}
