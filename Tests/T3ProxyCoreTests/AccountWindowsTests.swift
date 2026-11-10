import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct AccountWindowsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(_ windows: [(String, String)]) -> QuotaReading {
        QuotaReading(observedAt: now, windows: windows.map {
            QuotaWindow(id: $0.0, label: $0.1, usedPercent: 40, resetAt: now.addingTimeInterval(3600))
        }, models: [:], plan: nil)
    }

    @Test func onlyActualWindowsAndStableOrder() {
        let ultra = reading([("seven-day-fable", "Weekly · Fable"), ("seven-day", "Weekly")]).accountWindows()
        #expect(ultra.map(\.title) == ["Weekly", "Fable weekly"])
        #expect(ultra.map(\.duration) == [604800, 604800])
        var codex = reading([("code-review-weekly", "Code review · Weekly"), ("weekly", "Weekly"), ("five-hour", "5-hour session")])
        codex.windows.append(.init(id: "primary", label: "Primary", usedPercent: nil, resetAt: nil))
        #expect(codex.accountWindows().map(\.title) == ["5-hour", "Weekly", "Code review weekly"])
        #expect(codex.accountWindows().map(\.duration) == [18000, 604800, 604800])
    }

    @Test func durationsAndTitles() {
        let windows = reading([("seven-day-opus", "Weekly · Opus"), ("monthly", "Monthly"),
                               ("code-review-90-minute", "Code review · 90-minute"), ("credit-pool", "Credit pool"),
                               ("extra-usage", "Extra usage"), ("primary", "Primary window")]).accountWindows()
        #expect(windows.map(\.title) == ["Opus weekly", "Monthly", "Code review 90-minute", "Credit pool", "Extra usage", "Primary window"])
        // "Monthly" has no fixed length: without a reported one it gets no pace instead of an assumed 30 days.
        #expect(windows.map(\.duration) == [604800, nil, 5400, nil, nil, nil])
    }

    @Test func reportedDurationsWin() throws {
        // Recorded hub headers name hourly/daily windows; Codex reports 28–31-day windows as "monthly".
        let r = QuotaReading(observedAt: now, windows: [
            .init(id: "1-hour", label: "1-hour", usedPercent: 10, resetAt: now.addingTimeInterval(1800)),
            .init(id: "1-day", label: "1-day", usedPercent: 10, resetAt: now.addingTimeInterval(3600)),
            .init(id: "monthly", label: "Monthly", usedPercent: 10, resetAt: now.addingTimeInterval(86400), duration: 31 * 86400),
        ], models: [:], plan: nil)
        let w = r.accountWindows()
        #expect(w.map(\.duration) == [3600, 86400, 31 * 86400])
        #expect(QuotaPace.of(try #require(w.first { $0.id == "1-day" }), observedAt: now, now: now) != nil)
        // Parsers carry the length they were given.
        let codex = parseCodexSignals(["x-codex-primary-used-percent": "12", "x-codex-primary-window-minutes": "44640",
                                       "x-codex-primary-reset-after-seconds": "3600"], observed: now)
        #expect(codex.first?.id == "monthly" && codex.first?.duration == 44640 * 60)
        let claude = parseClaudeSignals(["anthropic-ratelimit-unified-1d-utilization": "0.2",
                                         "anthropic-ratelimit-unified-1d-reset": .init(stringLiteral: "\(Int(now.timeIntervalSince1970) + 3600)")])
        #expect(claude.first?.duration == 86400)
    }

    @Test func generalizedPaceMatchesExistingAPI() throws {
        for (id, kind) in [("five-hour", QuotaWindowKind.session), ("seven-day", .weekly)] {
            let r = reading([(id, "")])
            let w = try #require(r.accountWindows().first)
            #expect(QuotaPace.of(w, observedAt: r.observedAt, now: now) == QuotaPace.of(r, kind, now: now))
        }
        let scoped = reading([("seven-day-fable", "Weekly · Fable")])
        #expect(QuotaPace.of(scoped.accountWindows()[0], observedAt: now, now: now)?.dayMarks.isEmpty == false)
    }

    @Test func remainingAndPaceValidity() {
        var r = reading([("90-minute", "90-minute")])
        var w = r.accountWindows()[0]
        #expect(r.remaining(w, at: now) == 60)
        #expect(r.remaining(w, at: now.addingTimeInterval(3600)) == nil)
        r.windows[0].resetAt = nil
        w = r.accountWindows()[0]
        #expect(r.remaining(w, at: now.addingTimeInterval(5399)) == 60)
        #expect(r.remaining(w, at: now.addingTimeInterval(5400)) == nil)
        r.observedAt = nil
        #expect(r.remaining(w, at: now) == nil)
        r.observedAt = now.addingTimeInterval(1)
        #expect(r.remaining(w, at: now) == nil)
        r = reading([("90-minute", "90-minute")])
        r.windows[0].usedPercent = 100
        #expect(QuotaPace.of(r.accountWindows()[0], observedAt: now, now: now) == nil)
        r.windows[0].usedPercent = 10
        r.windows[0].resetAt = now.addingTimeInterval(5390)
        #expect(QuotaPace.of(r.accountWindows()[0], observedAt: now, now: now) == nil)
        r.windows[0].resetAt = now.addingTimeInterval(5401)
        #expect(QuotaPace.of(r.accountWindows()[0], observedAt: now, now: now) == nil)
        r.windows[0].resetAt = now.addingTimeInterval(3600)
        #expect(QuotaPace.of(r.accountWindows()[0], observedAt: now.addingTimeInterval(-1801), now: now) == nil)
        #expect(QuotaPace.of(r.accountWindows()[0], observedAt: now.addingTimeInterval(1), now: now) == nil)
    }
}
