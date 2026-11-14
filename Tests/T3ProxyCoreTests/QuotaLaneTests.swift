import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct QuotaLaneTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func account(_ name: String, used: Double, reset: TimeInterval = 3600, disabled: Bool = false) -> Account {
        var a = Account(name: name, provider: .claude)
        a.disabled = disabled
        a.quota = QuotaReading(observedAt: now, windows: [
            .init(id: "seven-day", label: "Weekly", usedPercent: used, resetAt: now.addingTimeInterval(reset)),
            .init(id: "seven-day-fable", label: "Weekly · Fable", usedPercent: used / 2, resetAt: now.addingTimeInterval(reset))
        ], models: [:], plan: nil)
        return a
    }

    @Test func groupsActualWindowsWithStableAccountIdentity() throws {
        let a = account("a", used: 80), b = account("b", used: 20)
        let lanes = quotaLanes([b, a, account("disabled", used: 0, disabled: true)], provider: .claude, now: now)
        #expect(lanes.map(\.id) == ["weekly", "seven-day-fable"])
        #expect(lanes.map(\.title) == ["Weekly", "Weekly · Fable"])
        #expect(lanes.allSatisfy { $0.entries.map(\.id) == [a.id, b.id] })
        #expect(lanes[0].remaining == 50)
        #expect(lanes[1].remaining == 75)
        #expect(lanes[0].resetGainPercent == 50)
        #expect(quotaLanes([a], provider: .codex, now: now).isEmpty)
    }

    @Test func expiryChangesOpenLaneToUnknownWithoutInventingARefill() throws {
        let a = account("a", used: 100), b = account("b", used: 20, reset: 7200)
        let first = try #require(quotaLanes([a, b], provider: .claude, now: now).first)
        #expect(first.remaining == 40)
        #expect(first.resetGainPercent == 50)
        let later = try #require(quotaLanes([a, b], provider: .claude, now: now.addingTimeInterval(3600)).first)
        #expect(later.entries.count == 2)
        #expect(later.entries[0].remaining == nil)
        #expect(later.remaining == 80)
        #expect(later.measured == 1)
        #expect(later.resetAt == now.addingTimeInterval(7200))
        #expect(later.resetGainPercent == 20)
    }

    @Test func unknownAndNonFiniteReadingsNeverBecomeZeroOrFull() throws {
        var a = account("a", used: .nan)
        var b = account("b", used: 70)
        b.quota.observedAt = nil
        a.quota.windows[1].usedPercent = nil
        let lane = try #require(quotaLanes([a, b], provider: .claude, now: now).first)
        #expect(lane.remaining == nil)
        #expect(lane.measured == 0)
        #expect(lane.resetAt == nil)
        #expect(lane.resetGainPercent == nil)
        #expect(lane.entries.allSatisfy { $0.remaining == nil })
    }

    @Test func manySubscriptionsStayDistinctAndMissingSessionIsNotInvented() throws {
        let accounts = (0..<40).map { account(String(format: "account-%02d", $0), used: Double($0)) }
        let lanes = quotaLanes(accounts, provider: .claude, now: now)
        #expect(lanes.count == 2)
        #expect(lanes.allSatisfy { $0.entries.count == 40 && Set($0.entries.map(\.id)).count == 40 })
        #expect(lanes[0].remaining == 80.5)
    }
}
