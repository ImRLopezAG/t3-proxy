import Foundation
import Testing
@testable import T3ProxyCore

/// Shaped like the live `/v0/management/auth-files` entries (values invented).
private let now = Date(timeIntervalSince1970: 1_794_000_000)
private let quotaFiles = #"""
{"files":[
 {"name":"claude-1.json","provider":"claude","note":"Main\u0007  work","quota":{"observed_at":"2026-11-06T13:00:00.304484-04:00","signals":{
   "Anthropic-Ratelimit-Unified-5h-Utilization":"0.31","Anthropic-Ratelimit-Unified-5h-Reset":"1794003600",
   "Anthropic-Ratelimit-Unified-7d-Utilization":"0.52","Anthropic-Ratelimit-Unified-7d-Reset":"1794100000",
   "Anthropic-Ratelimit-Unified-Overage-Utilization":"0.0","Anthropic-Ratelimit-Unified-Overage-Reset":"1796083200",
   "Anthropic-Ratelimit-Unified-Status":"allowed"}},
  "model_quotas":{"claude-opus":{"observed_at":"2026-11-06T13:00:00.3-04:00","signals":{"Anthropic-Ratelimit-Unified-7d-Utilization":0.76,"Anthropic-Ratelimit-Unified-7d-Reset":1794100000}}}},
 {"name":"claude-2.json","provider":"claude","quota":{"observed_at":"2026-11-06T13:00:00-04:00","signals":{
   "Anthropic-Ratelimit-Unified-7d-Utilization":"0.79","Anthropic-Ratelimit-Unified-7d-Reset":"1794050000"}}},
 {"name":"claude-3.json","provider":"claude","quota":{"signals":{}}},
 {"name":"claude-4.json","provider":"claude","disabled":true,"quota":{"observed_at":"2026-11-06T13:00:00-04:00","signals":{
   "Anthropic-Ratelimit-Unified-7d-Utilization":"0.0","Anthropic-Ratelimit-Unified-7d-Reset":"1794100000"}}},
 {"name":"codex-1.json","provider":"codex","quota":{"observed_at":"2026-11-06T13:00:00.33308-04:00","signals":{
   "X-Codex-Plan-Type":"pro","X-Codex-Primary-Used-Percent":"7","X-Codex-Primary-Window-Minutes":"10080","X-Codex-Primary-Reset-At":"1794400000",
   "X-Codex-Secondary-Used-Percent":"0","X-Codex-Secondary-Window-Minutes":"0","X-Codex-Secondary-Reset-After-Seconds":"0"}}},
 {"name":"codex-2.json","provider":"codex","quota":{"observed_at":"2026-11-06T13:00:00-04:00","signals":{
   "X-Codex-Plan-Type":"team","X-Codex-Primary-Used-Percent":"9","X-Codex-Primary-Window-Minutes":"300","X-Codex-Primary-Reset-After-Seconds":"3600",
   "X-Codex-Secondary-Used-Percent":"27","X-Codex-Secondary-Window-Minutes":"10080","X-Codex-Secondary-Reset-At":"1793990000"}}}
]}
"""#

private func accounts() throws -> [Account] {
    try JSONDecoder().decode(AuthFilesEnvelope.self, from: Data(quotaFiles.utf8)).files.map(Account.init)
}

@Suite struct QuotaTests {
    @Test func claudeFractionsBecomePercents() throws {
        let a = try accounts()[0]
        #expect(a.nickname == "Main work")
        #expect(a.quota.window(.session)?.usedPercent == 31)
        #expect(a.quota.remaining(.weekly, at: now) == 48)
        #expect(a.quota.windows.map(\.id).sorted() == ["extra-usage", "five-hour", "seven-day"])
        #expect(a.quota.models["claude-opus"]?.first?.usedPercent == 76)
        #expect(a.quota.observedAt != nil)
    }

    @Test func codexPercentsNamedByLength() throws {
        let all = try accounts()
        let pro = all[4], team = all[5]
        #expect(pro.quota.plan == "pro")
        #expect(pro.quota.windows.map(\.id) == ["weekly"])   // zero-length secondary slot dropped
        #expect(pro.quota.remaining(.weekly, at: now) == 93)
        #expect(pro.quota.remaining(.session, at: now) == nil)
        #expect(team.quota.window(.session)?.resetAt == team.quota.observedAt!.addingTimeInterval(3600))
    }

    @Test func nonFiniteOrHugeSignalsAreIgnoredNotCrashing() throws {
        let json = #"{"files":[{"name":"codex-x.json","provider":"codex","quota":{"observed_at":"2026-11-06T13:00:00-04:00","signals":{"X-Codex-Primary-Used-Percent":"nan","X-Codex-Primary-Window-Minutes":"1e300","X-Codex-Secondary-Used-Percent":"5","X-Codex-Secondary-Window-Minutes":"inf"}}}]}"#
        let a = try JSONDecoder().decode(AuthFilesEnvelope.self, from: Data(json.utf8)).files.map(Account.init)
        #expect(a.count == 1)
        #expect(finiteNumber("nan") == nil); #expect(finiteNumber("1e300") == nil); #expect(finiteNumber("300") == 300)
    }

    @Test func expiredResetIsUnknown() throws {
        let team = try accounts()[5]
        #expect(team.quota.window(.weekly)?.usedPercent == 27)
        #expect(team.quota.remaining(.weekly, at: now) == nil)   // reset 1793990000 < now
        #expect(team.quota.remaining(.weekly, at: Date(timeIntervalSince1970: 1_793_988_000)) == 73)
    }

    @Test func noResetExpiresAfterOnePeriod() {
        let obs = now
        let q = QuotaReading(observedAt: obs, windows: [QuotaWindow(id: "five-hour", label: "", usedPercent: 40, resetAt: nil)], models: [:], plan: nil)
        #expect(q.remaining(.session, at: obs.addingTimeInterval(3600)) == 60)
        #expect(q.remaining(.session, at: obs.addingTimeInterval(5 * 3600)) == nil)
    }

    @Test func pooledAcrossAccountsExcludingDisabledAndUnknown() throws {
        let all = try accounts()
        let weekly = pooledQuota(all, .claude, .weekly, now: now)
        // claude-1 48, claude-2 21, claude-3 unknown, claude-4 disabled
        #expect(weekly.accounts == 3); #expect(weekly.measured == 2); #expect(weekly.unknown == 1)
        #expect(weekly.remaining == 34.5)
        #expect(weekly.resetAt == Date(timeIntervalSince1970: 1_794_050_000))
        let session = pooledQuota(all, .claude, .session, now: now)
        #expect(session.measured == 1); #expect(session.remaining == 69)
        let codexWeekly = pooledQuota(all, .codex, .weekly, now: now)
        #expect(codexWeekly.measured == 1); #expect(codexWeekly.remaining == 93)
        #expect(pooledQuota([], .codex, .weekly, now: now).remaining == nil)
    }

    @Test func durations() {
        #expect(shortDuration(until: now.addingTimeInterval(4 * 3600 + 24 * 60 + 5), from: now) == "4h 24m")
        #expect(shortDuration(until: now.addingTimeInterval(2 * 86400 + 3 * 3600), from: now) == "2d 3h")
    }
}
