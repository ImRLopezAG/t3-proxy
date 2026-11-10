import SwiftUI
import T3ProxyCore

/// Quota per account (live reads through the hub, or the headers it recorded from the last real
/// request), then pooled per provider with reset times, model-specific limits and Codex resets.
struct QuotaPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var live: LiveQuotaModel
    @ObservedObject private var forecaster = QuotaForecaster.shared
    @State private var plans: [String: PlanInfo] = [:]
    @State private var confirmReset: (account: Account, intent: LiveQuotaModel.ResetIntent)?

    var body: some View {
        Group {
            if monitor.accountsUpdatedAt == nil {
                ContentUnavailableView {
                    Label("No Quota Readings", systemImage: "gauge.with.dots.needle.0percent")
                } description: {
                    Text(monitor.management == .connected ? "Waiting for the first read." : "Add a management key to read quota from the proxy.")
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in content(now: ctx.date) }
            }
        }
        .navigationTitle("Quota")
        .toolbar {
            ToolbarItem {
                Button { Task { await live.refresh() } } label: {
                    if live.refreshing { ProgressView().controlSize(.small) } else { Label("Read Live Quota", systemImage: "arrow.clockwise") }
                }
                .help("Ask Claude and Codex for each account's current quota")
                .disabled(live.refreshing || monitor.management != .connected)
            }
        }
        .task { plans = await Task.detached { PlanCache.load() }.value }
        .task(id: monitor.management) { if monitor.management == .connected { await live.refresh() } }
        .confirmationDialog(confirmReset.map { "Use a reset on “\($0.account.quotaLabel(among: monitor.accounts))”?" } ?? "",
                            isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
                            titleVisibility: .visible, presenting: confirmReset) { c in
            Button(live.pending[c.account.id] == nil ? "Use Reset" : "Retry Reset") { Task { await live.useReset(c.intent) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            let a = c.account
            if live.pending[a.id] != nil {
                Text("Sends the same reset request again. If the first one went through, no second credit is spent.")
            } else {
                Text("Its 5-hour and weekly Codex limits start over right away. This spends one banked reset\(expiry(a).map { " (the one expiring \($0))" } ?? "") and can't be undone.")
            }
        }
    }

    private var rows: [Account] {
        monitor.accounts.filter { $0.provider != .other }
            .sorted { ($0.provider.rawValue, $0.label) < ($1.provider.rawValue, $1.label) }
    }

    private func content(now: Date) -> some View {
        Form {
            if let o = live.outcome {
                Label(o.text, systemImage: o.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(o.isError ? .orange : .green)
            }
            Section {
                Table(rows) {
                    TableColumn("Account") { a in
                        HStack(spacing: 6) {
                            ProviderMark(provider: a.provider, size: 14, name: a.providerName)
                            Text(live.label(for: a)).lineLimit(1).truncationMode(.middle)
                            if a.disabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Plan") { a in
                        let p = plan(a)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.plan.map(planTitle) ?? "—").foregroundStyle(p.plan == nil ? .secondary : .primary)
                            if let org = p.org { Text(org).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }.width(min: 70, ideal: 100)
                    TableColumn("5-hour") { a in WindowCell(a: a, kind: .session, now: now) }.width(min: 90, ideal: 110)
                    TableColumn("Weekly") { a in WindowCell(a: a, kind: .weekly, now: now) }.width(min: 90, ideal: 110)
                    TableColumn("Resets") { a in
                        if a.provider == .codex, let n = live.credits[a.id]?.count ?? a.quota.availableResetCredits {
                            Text(n == 0 ? "None" : "\(n) banked").foregroundStyle(n == 0 ? .secondary : .primary)
                        } else { Text("—").foregroundStyle(.secondary) }
                    }.width(min: 60, ideal: 70)
                    TableColumn("Read") { a in
                        if let o = a.quota.observedAt {
                            // `now` can lag the clock by up to 30 s, so a fresh read would format as "in 0 sec".
                            let age = Date().timeIntervalSince(o)
                            Text("\(a.quota.source == .live ? "Live" : "Recorded") · \(age < 60 ? "just now" : o.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                                .foregroundStyle(.secondary).lineLimit(1)
                        } else { Text("Never").foregroundStyle(.secondary) }
                    }.width(min: 90, ideal: 120)
                }
                .frame(height: CGFloat(rows.count) * 34 + 32)
            } header: {
                Text("Accounts")
            } footer: {
                Text("Live readings come from Claude and Codex through the hub, about every 5 minutes. Recorded ones come from the last real request and can be hours old.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            // Two explicit sections: a ForEach of conditional Sections made the grouped Form put rows and
            // footers in the wrong boxes.
            if monitor.accounts.contains(where: { $0.provider == .claude }) { providerSection(.claude, now: now) }
            if monitor.accounts.contains(where: { $0.provider == .codex }) { providerSection(.codex, now: now) }
        }
        .formStyle(.grouped)
    }

    private func providerSection(_ p: Provider, now: Date) -> some View {
        Section {
            PoolRow(pool: pooledQuota(monitor.accounts, p, .session, now: now), now: now, forecast: forecaster.forecast(p, .session))
            PoolRow(pool: pooledQuota(monitor.accounts, p, .weekly, now: now), now: now, forecast: forecaster.forecast(p, .weekly))
            ForEach(extraWindows(p, now: now), id: \.label) { w in
                LabeledContent(w.label) {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(w.entries, id: \.account) { e in
                            Text("\(e.account)  \(Int(e.remaining.rounded()))% left\(e.reset.map { " · resets \(shortDuration(until: $0, from: now))" } ?? "")")
                                .monospacedDigit()
                        }
                    }
                }
            }
            if p == .codex { resetRows(now: now) }
        } header: {
            HStack(spacing: 6) { ProviderMark(provider: p, size: 14); Text(p.title) }
        } footer: {
            Text(p == .claude
                 ? "Claude has no banked resets: each limit comes back at the reset time shown."
                 : "A banked reset starts an account's 5-hour and weekly limits over. Codex grants them occasionally and they expire.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func resetRows(now: Date) -> some View {
        ForEach(monitor.accounts.filter { $0.provider == .codex && !$0.disabled }) { a in
            LabeledContent {
                HStack(spacing: 10) {
                    if let list = live.credits[a.id] {
                        if let first = list.first {
                            Text("\(list.count) banked\(first.expiresAt.map { " · next expires in \(shortDuration(until: $0, from: now))" } ?? "")")
                                .foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("No banked resets").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(live.refreshing ? "Checking…" : "Unknown").foregroundStyle(.secondary)
                    }
                    if live.claiming == a.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(live.pending[a.id] == nil ? "Use Reset…" : "Retry Reset…") { if let i = live.intent(for: a) { confirmReset = (a, i) } }
                            .disabled((live.pending[a.id] == nil && live.credits[a.id]?.isEmpty != false) || live.claiming != nil)
                    }
                }
            } label: {
                Text("Resets · \(live.label(for: a))")
            }
        }
    }

    private func plan(_ a: Account) -> PlanInfo {
        let cached = a.authIndex.flatMap { plans[PlanCache.accountKey($0)] }
        return PlanInfo(plan: a.quota.planInfo?.plan ?? a.quota.plan ?? cached?.plan,
                        org: a.quota.planInfo?.org ?? cached?.org)
    }

    private func planTitle(_ p: String) -> String { p.split(separator: " ").map { $0.capitalized }.joined(separator: " ").replacingOccurrences(of: #"(\d+)X\b"#, with: "$1x", options: .regularExpression) }

    private func expiry(_ a: Account) -> String? {
        (live.pending[a.id]?.credit ?? live.credits[a.id]?.first)?.expiresAt?.formatted(date: .abbreviated, time: .shortened)
    }

    /// Model-specific and other non-pooled windows (e.g. "Weekly · Fable"), per account.
    private func extraWindows(_ p: Provider, now: Date) -> [(label: String, entries: [(account: String, remaining: Double, reset: Date?)])] {
        var out: [String: [(account: String, remaining: Double, reset: Date?)]] = [:]
        for a in monitor.accounts where a.provider == p && !a.disabled {
            for w in a.quota.windows where w.kind == nil {
                guard let used = w.usedPercent, a.quota.observedAt != nil else { continue }
                if let r = w.resetAt, r <= now { continue }
                out[w.label, default: []].append((live.label(for: a), min(100, max(0, 100 - used)), w.resetAt))
            }
        }
        return out.map { ($0.key, $0.value.sorted { $0.account < $1.account }) }.sorted { $0.label < $1.label }
    }
}

extension Account {
    var label: String { quotaLabel }
}

private struct PoolRow: View {
    let pool: QuotaPool; let now: Date
    /// Burn-rate projection; nil (nothing shown) until there's enough history.
    var forecast: PoolForecast? = nil
    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let r = pool.remaining {
                    Gauge(value: r, in: 0...100) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).frame(width: 160)
                    Text("\(Int(r.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                } else {
                    Text("Not measured").foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(pool.kind.title)
            Text(detail).foregroundStyle(.secondary)
        }
    }
    private var detail: String {
        var s = pool.accounts == 0 ? "No enabled accounts"
            : pool.measured == pool.accounts ? "\(pool.accounts) account\(pool.accounts == 1 ? "" : "s")"
            : "\(pool.measured) of \(pool.accounts) measured"
        if let r = pool.resetAt {
            s += " · next reset \(shortDuration(until: r, from: now))"
            if let g = pool.resetGainPercent, g >= 0.5 { s += ", +\(Int(g.rounded()))% back" }
        }
        if let forecast, pool.accounts > 0, pool.measured == pool.accounts { s += " · " + forecast.phrase }
        return s
    }
}

private struct WindowCell: View {
    let a: Account; let kind: QuotaWindowKind; let now: Date
    var body: some View {
        if let r = a.quota.remaining(kind, at: now) {
            let reset = a.quota.window(kind)?.resetAt
            HStack(spacing: 6) {
                Text("\(Int(r.rounded()))%").monospacedDigit().fontWeight(.medium)
                if let reset { Text(shortDuration(until: reset, from: now)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .help(reset.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        } else if a.quota.window(kind)?.usedPercent != nil {
            Label("Stale", systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                .help("This window reset after the last reading.")
        } else if a.quota.source == .live && !a.disabled {
            Text("None reported").foregroundStyle(.secondary)
                .help("The provider's latest answer had no \(kind == .session ? "5-hour" : "weekly") window for this account (not started, or not part of its plan).")
        } else {
            Text(a.disabled ? "Disabled" : "Unknown").foregroundStyle(.secondary)
        }
    }
}
