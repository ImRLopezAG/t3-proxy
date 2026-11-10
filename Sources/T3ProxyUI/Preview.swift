import SwiftUI
import T3ProxyCore

/// Sample content exists only for design comparison and always shows the red SAMPLE banner.
public enum SamplePreview {
    @MainActor public static func content() -> PanelContent {
        var r: [Int64] = [5, 6, 5, 7, 8, 7, 9, 10, 9, 8, 9, 11, 12, 11, 9, 8, 9, 10, 9, 10]
        var accounts = [
            Account(name: "sample-claude-a", provider: .claude, requests: r),
            Account(name: "sample-claude-b", provider: .claude, requests: r.map { $0 * 3 }),
            Account(name: "sample-codex-a", provider: .codex, requests: r.reversed().map { $0 + 2 }),
            Account(name: "sample-claude-c", provider: .claude, held: true, heldReason: "Sample: rate limited", releaseAt: Date().addingTimeInterval(9000)),
        ]
        r = []
        // Sample readings that show each pace: in deficit and running out, in reserve, and a held account.
        let now = Date()
        func w(_ id: String, _ label: String, _ used: Double, _ reset: TimeInterval) -> QuotaWindow {
            .init(id: id, label: label, usedPercent: used, resetAt: now.addingTimeInterval(reset))
        }
        func reading(_ windows: [QuotaWindow], plan: String) -> QuotaReading {
            var q = QuotaReading(observedAt: now.addingTimeInterval(-60), windows: windows, models: [:], plan: plan)
            q.source = .live
            return q
        }
        // A plan without a 5-hour limit and with a model window; a Team plan running hot; Codex with both.
        accounts[0].quota = reading([w("seven-day", "Weekly", 32, 4.34 * 86400), w("seven-day-fable", "Weekly · Fable", 26, 4.34 * 86400)], plan: "max 20x")
        accounts[1].quota = reading([w("five-hour", "5-hour session", 71, 2 * 3600 + 5 * 60), w("seven-day", "Weekly", 24, 3.2 * 86400)], plan: "team")
        accounts[2].quota = reading([w("five-hour", "5-hour session", 12, 4 * 3600), w("weekly", "Weekly", 92, 4.34 * 86400)], plan: "pro")
        var c = PanelContent(reachability: .live, management: .connected, endpoint: "127.0.0.1:8317", accounts: accounts, updatedAt: Date())
        c.isSample = true
        let reset = Date().addingTimeInterval(4 * 3600 + 24 * 60)
        c.quota = [QuotaPool(provider: .claude, kind: .session, remaining: 87, accounts: 3, measured: 3, resetAt: reset),
                   QuotaPool(provider: .claude, kind: .weekly, remaining: 81, accounts: 3, measured: 3, resetAt: reset.addingTimeInterval(86400)),
                   QuotaPool(provider: .codex, kind: .session, remaining: 100, accounts: 1, measured: 1, resetAt: reset.addingTimeInterval(1800)),
                   QuotaPool(provider: .codex, kind: .weekly, remaining: 74, accounts: 1, measured: 1, resetAt: reset.addingTimeInterval(90000))]
        c.days = sampleDays()
        c.recent = sampleRecent()
        return c
    }

    /// Deterministic sample token buckets (rendered only under the SAMPLE banner).
    public static func sampleRecent() -> RecentUsage {
        func series(_ scale: Int64, _ phase: Int) -> [UsageTotals] {
            (0..<20).map { i in
                var u = UsageTotals(); u.total = scale * Int64(4 + (i * 7 + phase) % 9)
                u.input = u.total / 10; u.output = u.total / 20; u.cached = u.total - u.input - u.output; u.requests = Int(u.total / 150_000)
                return u
            }
        }
        var r = RecentUsage(start: Date().addingTimeInterval(-12_000), width: 600, count: 20,
                            byProvider: [.claude: series(450_000, 2), .codex: series(260_000, 5)])
        r.cost = [.claude: CostEstimate(usd: 184.62), .codex: CostEstimate(usd: 61.30)]
        return r
    }

    /// Deterministic sample calendar (rendered only under the SAMPLE banner).
    public static func sampleDays(count: Int = 365) -> [UsageDay] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        return (0..<count).compactMap { i -> UsageDay? in
            guard let d = cal.date(byAdding: .day, value: i - count + 1, to: today) else { return nil }
            let wave = (i * 37 % 11), weekend = cal.isDateInWeekend(d)
            var day = UsageDay(date: d)
            guard wave > 1, !(weekend && wave < 6) else { return day }
            var a = UsageTotals(); a.total = Int64(wave * wave) * 1_200_000 + Int64(i) * 90_000; a.requests = wave * 12
            var b = UsageTotals(); b.total = Int64(wave) * 900_000; b.requests = wave * 3
            day.byProvider = [.claude: a, .codex: b]
            return day
        }
    }

    /// Thread cards and a thread hover card from the sample snapshot.
    @MainActor public static func renderThreads(to dir: URL) throws {
        let now = Date()
        let snap = T3CodeSnapshot.sample(now: now)
        let rows = T3ThreadBoard.sections(snap, now: now, runningSince: [:]).flatMap(\.rows)
        func project(_ r: T3ThreadRow) -> T3CodeProject? { snap.projects.first { $0.id == r.thread.projectId } }
        for dark in [true, false] {
            let list = VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { r in ThreadRowView(row: r, now: now, accounts: [], sampleProject: project(r), sample: true) }
            }
            .frame(width: 332).padding(14)
            .background(dark ? Color(hex: 0x202020) : Color(hex: 0xF5F5F5))
            .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: list); r.scale = 3
            if let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try data.write(to: dir.appendingPathComponent("thread-cards-\(dark ? "dark" : "light").png"))
            }
            if let first = rows.first {
                try still(ThreadHoverCard(row: first, project: project(first), now: now), dark: dark,
                          to: dir.appendingPathComponent("card-thread-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Hover-card stills for design checks (sample data only; usage history is not read).
    @MainActor public static func renderCards(to dir: URL) throws {
        let c = content()
        for dark in [true, false] {
            for (i, a) in c.accounts.prefix(3).enumerated() {
                let card = AccountHoverCard(account: a, tint: Theme(dark ? .dark : .light).tint(a.provider), now: Date(), sample: true,
                                            preset: sampleSummary(seed: i, provider: a.provider))
                try still(card, dark: dark, to: dir.appendingPathComponent("card-account\(i)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Deterministic sample breakdown (rendered only in design stills).
    static func sampleSummary(seed: Int, provider: Provider) -> AccountUsageSummary {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        func totals(_ n: Int64) -> UsageTotals { var u = UsageTotals(); u.total = n; u.requests = Int(n / 90_000); return u }
        let days = (0..<30).map { i -> AccountUsageDay in
            let wave = Int64((i * 7 + seed * 5) % 11)
            let n = i < 8 ? 0 : wave * wave * 2_400_000
            return AccountUsageDay(date: cal.date(byAdding: .day, value: i - 29, to: today) ?? today, totals: totals(n),
                                   cost: CostEstimate(usd: Double(n) / 1_000_000 * 1.9))
        }
        let sum = days.reduce(UsageTotals()) { $0 + $1.totals }
        let cost = days.reduce(CostEstimate()) { $0 + $1.cost }
        let models = provider == .codex
            ? [UsageModelRow(provider: .codex, model: "gpt-6.1-sol", totals: totals(sum.total * 7 / 10), cost: cost.usd * 0.7),
               UsageModelRow(provider: .codex, model: "gpt-6-astra", totals: totals(sum.total * 3 / 10), cost: cost.usd * 0.3)]
            : [UsageModelRow(provider: .claude, model: "claude-opus-5-5", totals: totals(sum.total * 6 / 10), cost: cost.usd * 0.6),
               UsageModelRow(provider: .claude, model: "claude-fable-5-1", totals: totals(sum.total * 3 / 10), cost: cost.usd * 0.32),
               UsageModelRow(provider: .claude, model: "claude-haiku-5-5", totals: totals(sum.total / 10), cost: cost.usd * 0.08)]
        let last = days.last!
        return AccountUsageSummary(today: last.totals, todayCost: last.cost, window: totals(last.totals.total / 3),
                                   windowCost: CostEstimate(usd: last.cost.usd / 3), last30: sum, last30Cost: cost, days: days, models: models)
    }

    /// Getting Started still in the no-key state. Form/ScrollView don't render offscreen, so sections stack in a VStack.
    @MainActor public static func renderGettingStarted(to dir: URL, port: Int = HubPort.defaultPort) throws {
        let c = PanelContent(reachability: .live, management: .noKey, endpoint: ProxyEndpoint(port: port).label, accounts: [], updatedAt: nil)
        let list = SetupChecklist(c, t3Connected: false, recorder: .off)
        for dark in [true, false] {
            let v = VStack(alignment: .leading, spacing: 12) { GettingStartedSections(list: list, port: port) { _ in } }
                .frame(width: 520, alignment: .leading).padding(20).fixedSize(horizontal: false, vertical: true)
                .background(dark ? Color(hex: 0x202020) : Color(hex: 0xF5F5F5))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: v); r.scale = 2
            guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: dir.appendingPathComponent("getting-started-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor static func still<V: View>(_ v: V, dark: Bool, to url: URL) throws {
        let view = v.frame(width: 300, alignment: .leading).padding(14).fixedSize(horizontal: false, vertical: true)
            .background(dark ? Color(hex: 0x2A2A2A) : Color(hex: 0xF2F2F2))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 3
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    @MainActor public static func render(_ content: PanelContent, tab: PanelTab, dark: Bool, to url: URL) throws {
        let actions = PanelActions(refresh: {}, setKey: { _ in }, removeKey: {}, quit: {}, interval: .constant(60))
        let view = PanelView(content: content, actions: actions, tab: tab)
            .background(dark ? Color(hex: 0x202020) : Color(hex: 0xF5F5F5))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 3
        guard let cg = r.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        try data.write(to: url)
    }
}
