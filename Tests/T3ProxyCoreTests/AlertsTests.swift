import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct AlertsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = Date(timeIntervalSince1970: 1_800_010_000)

    func acct(_ s: Double? = nil, _ w: Double? = nil, held: Bool = false, key: String = "codex:aa", label: String = "Work") -> AlertAccount {
        AlertAccount(key: key, label: label, held: held, heldReason: held ? "Rate limited by the provider" : nil,
                     session: s.map { .init(remaining: $0, resetAt: reset) }, weekly: w.map { .init(remaining: $0, resetAt: reset.addingTimeInterval(86400)) })
    }
    /// A state past first-run seeding with nothing fired.
    func seeded() -> AlertState {
        AlertRules.evaluate(AlertState(), AlertSnapshot(reachability: .live, accounts: []), settings: .init(), now: t0).state
    }
    func run(_ st: AlertState, _ accounts: [AlertAccount]?, reach: Reachability = .live, credits: [String: [Date]] = [:],
             settings: AlertSettings = .init(), at: Date? = nil) -> ([Alert], AlertState) {
        AlertRules.evaluate(st, AlertSnapshot(reachability: reach, accounts: accounts, credits: credits), settings: settings, now: at ?? t0)
    }

    @Test func thresholdAndZeroFireOncePerPeriod() {
        var st = seeded()
        var (a, s) = run(st, [acct(50)]); #expect(a.isEmpty); st = s
        (a, s) = run(st, [acct(9)]); #expect(a.map(\.id).first?.hasPrefix("low|") == true); #expect(a.count == 1); st = s
        (a, s) = run(st, [acct(8)]); #expect(a.isEmpty); st = s           // no spam on every poll
        (a, s) = run(st, [acct(0)]); #expect(a.count == 1 && a[0].id.hasPrefix("zero|")); st = s
        (a, s) = run(st, [acct(0)]); #expect(a.isEmpty)
        #expect(!a.contains { $0.title.contains("@") })
    }

    @Test func straightToZeroSkipsLowAndCustomThreshold() {
        var (a, s) = run(seeded(), [acct(0)]); #expect(a.count == 1 && a[0].id.hasPrefix("zero|"))
        (a, s) = run(s, [acct(0)]); #expect(a.isEmpty)
        var set = AlertSettings(); set.threshold = 25
        (a, _) = run(seeded(), [acct(20)], settings: set); #expect(a.count == 1)
        (a, _) = run(seeded(), [acct(20)]); #expect(a.isEmpty)
    }

    @Test func newResetPeriodAlertsAgain() {
        let (_, s) = run(seeded(), [acct(5)])
        let next = AlertAccount(key: "codex:aa", label: "Work", session: .init(remaining: 5, resetAt: reset.addingTimeInterval(5 * 3600)))
        let (a, _) = run(s, [next], at: reset.addingTimeInterval(60))
        #expect(a.count == 1)
    }

    @Test(arguments: [QuotaWindowKind.session, .weekly])
    func resetJitterAcrossRoundingBoundaryDoesNotAlertAgain(_ kind: QuotaWindowKind) {
        let boundary = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 600).rounded(.down) * 600 + 300)
        func account(_ date: Date) -> AlertAccount {
            let window = AlertAccount.Window(remaining: 5, resetAt: date)
            return AlertAccount(key: "codex:aa", label: "Work", session: kind == .session ? window : nil,
                                weekly: kind == .weekly ? window : nil)
        }
        let (first, state) = run(seeded(), [account(boundary.addingTimeInterval(-1))])
        #expect(first.count == 1)
        let (again, _) = run(state, [account(boundary.addingTimeInterval(1))])
        #expect(again.isEmpty)
    }

    @Test func firstLaunchSeedsWithoutAlerting() {
        let (a, s) = run(AlertState(), [acct(3, 0, held: true)])
        #expect(a.isEmpty); #expect(s.accountsSeeded)
        // Unknown accounts (still loading) neither alert nor seed.
        let (b, u) = run(AlertState(), nil)
        #expect(b.isEmpty); #expect(!u.accountsSeeded)
        // Relaunch with persisted state: already-told conditions stay quiet, new ones alert.
        let restored = try! JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(s))
        let (c, _) = run(restored, [acct(3, 0, held: true), acct(2, key: "claude:bb", label: "Home")])
        #expect(c.count == 1 && c[0].title.contains("Home"))
    }

    @Test func heldIsEdgeTriggered() {
        var (a, s) = run(seeded(), [acct(held: true)]); #expect(a.count == 1 && a[0].kind == .accountHeld)
        (a, s) = run(s, [acct(held: true)]); #expect(a.isEmpty)
        (a, s) = run(s, nil); #expect(a.isEmpty)                 // unknown keeps state
        (a, s) = run(s, [acct(held: true)]); #expect(a.isEmpty)
        (a, s) = run(s, [acct()]); #expect(a.isEmpty)
        (a, s) = run(s, [acct(held: true)]); #expect(a.count == 1)
    }

    @Test func offlineAndBack() {
        var (a, s) = run(AlertState(), [], reach: .unknown); #expect(a.isEmpty)
        (a, s) = run(s, [], reach: .offline); #expect(a.isEmpty)   // offline at first launch: not new
        (a, s) = run(s, [], reach: .live); #expect(a.isEmpty)
        (a, s) = run(s, [], reach: .offline); #expect(a.map(\.id) == ["hub|offline"])
        (a, s) = run(s, nil, reach: .offline); #expect(a.isEmpty)
        (a, s) = run(s, nil, reach: .unknown); #expect(a.isEmpty)
        (a, s) = run(s, [], reach: .live); #expect(a.map(\.id) == ["hub|online"])
        (a, s) = run(s, [], reach: .live); #expect(a.isEmpty)
    }

    @Test func disabledKindStaysQuietAndDoesNotFireLater() {
        var off = AlertSettings(); off.disabled = [.lowQuota, .hubOffline]
        var (a, s) = run(seeded(), [acct(4)], settings: off); #expect(a.isEmpty)
        (a, s) = run(s, [acct(4)]); #expect(a.isEmpty)
        (a, _) = run(run(s, [], reach: .live).1, [], reach: .offline, settings: off); #expect(a.isEmpty)
    }

    @Test func creditExpiry() {
        let soon = t0.addingTimeInterval(20 * 3600), later = t0.addingTimeInterval(72 * 3600)
        // First time an account's credits are seen: seeded quietly.
        var (a, s) = run(seeded(), [acct()], credits: ["codex:aa": [soon, later]]); #expect(a.isEmpty)
        (a, s) = run(s, [acct()], credits: ["codex:aa": [soon, later]]); #expect(a.isEmpty)
        // The later one enters the 48 h window.
        let tomorrow = t0.addingTimeInterval(30 * 3600)
        (a, s) = run(s, [acct()], credits: ["codex:aa": [later]], at: tomorrow)
        #expect(a.count == 1 && a[0].kind == .creditExpiring && a[0].title.contains("Work"))
        (a, _) = run(s, [acct()], credits: ["codex:aa": [later]], at: tomorrow.addingTimeInterval(60)); #expect(a.isEmpty)
        // Expired credits never alert.
        (a, _) = run(s, [acct()], credits: ["codex:aa": [t0]], at: tomorrow); #expect(a.isEmpty)
    }

    @Test func creditSeedMemoryExpiresCapsAndSurvivesOutages() {
        var state = seeded()
        for i in 0..<250 { state.creditsSeeded["old-\(i)"] = t0.addingTimeInterval(Double(i - 300)) }
        state.creditsSeeded["expired"] = t0.addingTimeInterval(-15 * 86400)
        let (_, capped) = run(state, nil)
        #expect(capped.creditsSeeded.count == 200)
        #expect(capped.creditsSeeded["expired"] == nil)
        #expect(capped.creditsSeeded["old-0"] == nil)
        #expect(capped.creditsSeeded["old-249"] != nil)
        let (_, outage) = run(capped, nil, at: t0.addingTimeInterval(60))
        #expect(outage.creditsSeeded == capped.creditsSeeded)
        let (_, expired) = run(outage, nil, at: t0.addingTimeInterval(15 * 86400))
        #expect(expired.creditsSeeded.isEmpty)
        let (_, seen) = run(seeded(), [acct()], credits: ["codex:aa": []])
        let (_, refreshed) = run(seen, nil, credits: ["codex:aa": []], at: t0.addingTimeInterval(86400))
        #expect(refreshed.creditsSeeded["codex:aa"] == t0.addingTimeInterval(86400))
    }

    @Test func legacyCreditSeedStateMigratesWithoutLosingAlerts() throws {
        let data = Data(#"{"fired":{},"accountsSeeded":true,"creditsSeeded":["codex:aa"],"offlineAlerted":false}"#.utf8)
        let state = try JSONDecoder().decode(AlertState.self, from: data)
        #expect(state.accountsSeeded && state.creditsSeeded["codex:aa"] != nil)
        #expect(try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test func humanLabelsNeverUseCredentialIdentifiers() {
        var a = Account(name: "codex-28b589bb-private-pro.json", provider: .codex, authIndex: "private")
        a.quota.plan = "pro"
        #expect(a.quotaLabel == "Codex Pro account")
        var b = a; b.name = "codex-second-private-pro.json"
        #expect(a.quotaLabel(among: [b, a]) == "Codex Pro account #1")
        #expect(b.quotaLabel(among: [a, b]) == "Codex Pro account #2")
        a.nickname = "Work"
        #expect(a.quotaLabel(among: [a, b]) == "Work")
        a.nickname = nil; a.quota.plan = "private-account-123"
        #expect(a.quotaLabel == "Codex account")
    }

    @Test func accountKeysAreHashedAndLabelsHideEmails() throws {
        let acc = Account(name: "codex-1-me@example.com-pro", provider: .codex, held: true, heldReason: "Unavailable",
                          authIndex: "7")
        let a = try #require(AlertAccount(acc, now: t0))
        #expect(!a.key.contains("@") && !a.key.contains("example") && a.key.hasPrefix("codex:"))
        #expect(!a.label.contains("@"))
        let (alerts, st) = run(seeded(), [a])
        #expect(!alerts.isEmpty && !alerts[0].title.contains("example.com"))
        let stored = String(decoding: try JSONEncoder().encode(st), as: UTF8.self)
        #expect(!stored.contains("example") && !stored.contains("@"))
        #expect(AlertAccount(Account(name: "x", provider: .codex, disabled: true), now: t0) == nil)
    }
}
