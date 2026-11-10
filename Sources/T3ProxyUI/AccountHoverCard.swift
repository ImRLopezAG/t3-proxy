import SwiftUI
import T3ProxyCore

/// The card beside the panel for one account: every limit window it has with pace, then its own usage from the
/// local request history (today, the current window, 30 days, a daily chart and the top models).
struct AccountHoverCard: View {
    let account: Account
    let tint: Color
    let now: Date
    var sample = false
    /// Sample stills only: a fixed breakdown instead of reading the history.
    var preset: AccountUsageSummary? = nil
    @State private var summary: AccountUsageSummary?
    @State private var loaded = false
    @Environment(\.colorScheme) private var s

    var body: some View {
        let t = Theme(s)
        let windows = account.quota.accountWindows().map { WindowState($0, account.quota, now: now) }
        VStack(alignment: .leading, spacing: 10) {
            header(t)
            Rule()
            if windows.isEmpty {
                Text("No limit reading for this account yet.").font(.system(size: 11)).foregroundStyle(t.secondary)
            }
            ForEach(windows, id: \.window.id) { AccountWindowPace(state: $0, tint: tint, now: now) }
            if let n = account.quota.availableResetCredits, n > 0 {
                Label("\(n) limit reset credit\(n == 1 ? "" : "s") available", systemImage: "arrow.counterclockwise.circle")
                    .font(.system(size: 10.5)).foregroundStyle(t.secondary)
            }
            Rule()
            usage(t)
        }
        .task(id: account.id) { await load() }
    }

    private func header(_ t: Theme) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderMark(provider: account.provider, size: 18, name: account.providerName)
            VStack(alignment: .leading, spacing: 1) {
                Text((account.nickname ?? account.name).emailHidden).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(updatedText).font(.system(size: 10)).foregroundStyle(t.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let plan = planText { Text(plan).font(.system(size: 10.5)).foregroundStyle(t.secondary).lineLimit(1) }
        }
    }

    private var updatedText: String {
        guard let seen = account.quota.observedAt else { return account.name.emailHidden }
        let ago = now.timeIntervalSince(seen) < 60 ? "just now" : "\(shortDuration(until: now, from: seen)) ago"
        return "Updated \(ago)" + (account.nickname != nil ? " · \(account.name.emailHidden)" : "")
    }

    private var planText: String? {
        let p = account.quota.planInfo?.plan ?? account.quota.plan
        // "max 20x" → "Max 20x": capitalise each word's first letter only.
        return p.map { $0.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
    }

    // MARK: Usage

    @ViewBuilder private func usage(_ t: Theme) -> some View {
        if let u = summary ?? preset {
            if u.last30.requests == 0 && u.last30.total == 0 {
                Text("No requests through the hub for this account in the last 30 days.")
                    .font(.system(size: 10.5)).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    stat("Today", u.todayCost, u.today)
                    stat("This window", u.windowCost, u.window)
                    stat("30 days", u.last30Cost, u.last30)
                }
                DailyBars(days: u.days, tint: tint)
                if !u.models.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(u.models.prefix(3)) { m in
                            HStack(spacing: 6) {
                                Text(T3Display.model(m.model) ?? m.model).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(compactTokens(m.totals.total)).monospacedDigit().foregroundStyle(t.secondary)
                                Text(m.cost.map { formatUSD($0) } ?? "—").monospacedDigit().frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                    .font(.system(size: 10.5))
                }
                Text("Estimated at API list prices from requests through the hub.").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        } else if loaded || sample {
            Text(account.usageKey == nil ? "Usage history isn't linked to this account yet." : "Usage history is unavailable.")
                .font(.system(size: 10.5)).foregroundStyle(t.secondary)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading usage…").font(.system(size: 10.5)).foregroundStyle(t.secondary) }
        }
    }

    private func stat(_ title: String, _ cost: CostEstimate?, _ tokens: UsageTotals?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Text(cost.map(\.short) ?? "—").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(tokens.map { "\(compactTokens($0.total)) tokens" } ?? " ").font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The window the hub's "current window" column means: the shortest window with a known start.
    private var windowStart: Date? {
        account.quota.accountWindows().compactMap { w -> Date? in
            guard let d = w.duration, let reset = w.window.resetAt, reset > now, reset.timeIntervalSince(now) <= d else { return nil }
            return reset.addingTimeInterval(-d)
        }.max()
    }

    private func load() async {
        // Never show another account's numbers: start empty for every account.
        summary = nil; loaded = false
        if let preset { summary = preset; loaded = true; return }
        guard !sample, let key = account.usageKey else { loaded = true; return }
        let source = UsageModel.shared.source, provider = account.provider, start = windowStart, at = now
        let result = await Task.detached(priority: .userInitiated) {
            try? source.accountSummary(provider: provider, accountKey: key, windowStart: start, now: at, calendar: .current)
        }.value
        guard !Task.isCancelled else { return }   // superseded by a newer account or the card closed
        summary = result
        loaded = true
    }
}

/// 30 daily bars, newest on the right, with the largest day's cost as the scale label.
struct DailyBars: View {
    let days: [AccountUsageDay]
    let tint: Color
    var body: some View {
        let peak = days.map(\.totals.total).max() ?? 0
        let peakCost = days.max { $0.totals.total < $1.totals.total }?.cost
        VStack(alignment: .trailing, spacing: 3) {
            if peak > 0, let c = peakCost { Text(c.short).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit() }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { d in
                    let v = peak > 0 ? CGFloat(d.totals.total) / CGFloat(peak) : 0
                    RoundedRectangle(cornerRadius: 1.5).fill(v > 0 ? tint : Color.primary.opacity(0.12))
                        .frame(height: max(2, 34 * v))
                        .help("\(d.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(compactTokens(d.totals.total)) tokens · \(d.cost.short)")
                }
            }
            .frame(height: 34, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily tokens for the last 30 days")
    }
}
