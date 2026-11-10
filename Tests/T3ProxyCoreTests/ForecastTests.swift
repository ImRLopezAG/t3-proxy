import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct ForecastTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ key: String, _ remaining: Double, minutesAgo: Double, reset: Date?, kind: QuotaWindowKind = .weekly) -> QuotaSample {
        QuotaSample(key: key, kind: kind, remaining: remaining, resetAt: reset, observedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func ratePerAccount() throws {
        let r = now.addingTimeInterval(86400)
        let s = [sample("a", 60, minutesAgo: 120, reset: r), sample("a", 50, minutesAgo: 0, reset: r)]
        let rates = try #require(Forecast.burnRates(s, members: ["a"], kind: .weekly, now: now))
        #expect(abs(rates["a"]! - 5) < 1e-9)   // 10 points over 2 h
    }

    @Test func notEnoughData() {
        let r = now.addingTimeInterval(86400)
        // One reading.
        #expect(Forecast.pool([sample("a", 50, minutesAgo: 0, reset: r)], members: ["a"], kind: .weekly, now: now) == nil)
        // Span shorter than half the 3 h burn window.
        #expect(Forecast.pool([sample("a", 60, minutesAgo: 60, reset: r), sample("a", 50, minutesAgo: 0, reset: r)],
                              members: ["a"], kind: .weekly, now: now) == nil)
        // A member without any history refuses the whole pool.
        let ok = [sample("a", 60, minutesAgo: 120, reset: r), sample("a", 50, minutesAgo: 0, reset: r)]
        #expect(Forecast.pool(ok, members: ["a", "b"], kind: .weekly, now: now) == nil)
        // No reset time reported.
        #expect(Forecast.pool([sample("a", 60, minutesAgo: 120, reset: nil), sample("a", 50, minutesAgo: 0, reset: nil)],
                              members: ["a"], kind: .weekly, now: now) == nil)
        #expect(Forecast.pool([], members: [], kind: .weekly, now: now) == nil)
    }

    @Test func resetBoundarySplitsInstances() {
        // The earlier readings belong to the previous window instance: only one reading of the current one.
        let old = now.addingTimeInterval(-3600), new = now.addingTimeInterval(5 * 3600)
        let s = [sample("a", 10, minutesAgo: 170, reset: old, kind: .session), sample("a", 5, minutesAgo: 70, reset: old, kind: .session),
                 sample("a", 100, minutesAgo: 0, reset: new, kind: .session)]
        #expect(Forecast.burnRates(s, members: ["a"], kind: .session, now: now) == nil)
        // Small jitter in the reported reset (< 10 min) is the same instance.
        let j = [sample("a", 90, minutesAgo: 40, reset: new.addingTimeInterval(-120), kind: .session),
                 sample("a", 80, minutesAgo: 0, reset: new, kind: .session)]
        #expect(Forecast.burnRates(j, members: ["a"], kind: .session, now: now) != nil)
    }

    @Test func pooledRunsOutOrLasts() throws {
        let r = now.addingTimeInterval(24 * 3600)
        // a: 50 → 40 over 2 h (5/h) → empty in 8 h; b: 30 → 20 (5/h) → empty in 4 h. Pool empty at +8 h.
        let s = [sample("a", 50, minutesAgo: 120, reset: r), sample("a", 40, minutesAgo: 0, reset: r),
                 sample("b", 30, minutesAgo: 120, reset: r.addingTimeInterval(3600)), sample("b", 20, minutesAgo: 0, reset: r.addingTimeInterval(3600))]
        let f = try #require(Forecast.pool(s, members: ["a", "b"], kind: .weekly, now: now))
        #expect(f == .runsOut(now.addingTimeInterval(8 * 3600)))
        // Reset before the pool empties → lasts until the soonest reset.
        let soon = now.addingTimeInterval(2 * 3600)
        let s2 = s.map { var x = $0; x.resetAt = soon; return x }
        #expect(Forecast.pool(s2, members: ["a", "b"], kind: .weekly, now: now) == .lastsUntilReset(soon))
        // No consumption → lasts.
        let flat = [sample("a", 50, minutesAgo: 120, reset: r), sample("a", 50, minutesAgo: 0, reset: r)]
        #expect(Forecast.pool(flat, members: ["a"], kind: .weekly, now: now) == .lastsUntilReset(r))
        // Expired latest reading → nil.
        let past = [sample("a", 50, minutesAgo: 200, reset: now.addingTimeInterval(-60)), sample("a", 40, minutesAgo: 30, reset: now.addingTimeInterval(-60))]
        #expect(Forecast.pool(past, members: ["a"], kind: .weekly, now: now) == nil)
    }

    @Test func everyEnabledMemberNeedsCurrentWindowEvidence() {
        let reset = now.addingTimeInterval(86400)
        var a = Account(name: "a", provider: .codex, authIndex: "a")
        var b = Account(name: "b", provider: .codex, authIndex: "b")
        let history = [a, b].flatMap { account in
            [sample(accountHistoryKey(account), 60, minutesAgo: 120, reset: reset),
             sample(accountHistoryKey(account), 50, minutesAgo: 0, reset: reset)]
        }
        func reading(_ reset: Date?) -> QuotaReading {
            QuotaReading(observedAt: now, windows: [.init(id: "weekly", label: "Weekly", usedPercent: 50, resetAt: reset)], models: [:], plan: nil)
        }
        a.quota = reading(reset)
        #expect(Forecast.pool(history, accounts: [a, b], provider: .codex, kind: .weekly, now: now) == nil)
        b.quota = reading(nil)
        #expect(Forecast.pool(history, accounts: [a, b], provider: .codex, kind: .weekly, now: now) == nil)
        b.quota = reading(reset.addingTimeInterval(86400))
        #expect(Forecast.pool(history, accounts: [a, b], provider: .codex, kind: .weekly, now: now) == nil)
        b.quota = reading(reset.addingTimeInterval(120))
        #expect(Forecast.pool(history, accounts: [a, b], provider: .codex, kind: .weekly, now: now) != nil)
        b.disabled = true
        #expect(Forecast.pool(history, accounts: [a, b], provider: .codex, kind: .weekly, now: now) != nil)
    }

    @Test func forecastExpiresWithoutNewEvidence() {
        let reset = now.addingTimeInterval(86400)
        let history = [sample("a", 60, minutesAgo: 120, reset: reset), sample("a", 50, minutesAgo: 0, reset: reset)]
        #expect(Forecast.pool(history, members: ["a"], kind: .weekly, now: now) != nil)
        #expect(Forecast.pool(history, members: ["a"], kind: .weekly, now: now.addingTimeInterval(3 * 3600 + 1)) == nil)
    }

    @Test func historyPruneCapAndThin() {
        var h = QuotaHistory()
        let r = now.addingTimeInterval(3600)
        #expect(h.record([sample("a", 50, minutesAgo: 36 * 1440, reset: r),     // older than 35 days
                          sample("a", 50, minutesAgo: -60, reset: r),          // in the future
                          sample("a", 50, minutesAgo: 10, reset: r)], now: now) == 1)
        #expect(h.record([sample("a", 50, minutesAgo: 9, reset: r)], now: now) == 0)    // unchanged, too soon
        #expect(h.record([sample("a", 50, minutesAgo: 10, reset: r)], now: now) == 0)   // duplicate
        #expect(h.record([sample("a", 49, minutesAgo: 8, reset: r)], now: now) == 1)
        h.prune(now: now.addingTimeInterval(36 * 86400)); #expect(h.samples.isEmpty)

        var big = QuotaHistory()
        let many = (0..<(QuotaHistory.maximumSamples + 50)).map { i in
            QuotaSample(key: "k", kind: .weekly, remaining: Double(i % 100), resetAt: nil, observedAt: now.addingTimeInterval(Double(i - 100_000)))
        }
        big.record(many, now: now)
        #expect(big.samples.count == QuotaHistory.maximumSamples)
        #expect(big.samples.first?.observedAt == many[50].observedAt)   // oldest dropped
    }

    @Test func storeRoundTripAndNoNames() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaHistoryStore(url: dir.appendingPathComponent("quota-history.json"))
        var q = QuotaReading.none
        q.observedAt = now
        q.windows = [QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 30, resetAt: now.addingTimeInterval(3600))]
        let acc = Account(name: "codex-1-me@example.com-pro", provider: .codex, quota: q, authIndex: "3")
        var h = QuotaHistory()
        #expect(h.record(quotaSamples(from: [acc]), now: now) == 1)
        try await store.save(h)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("example") && !text.contains("@"))
        #expect(await store.load(now: now) == h)
    }
}
