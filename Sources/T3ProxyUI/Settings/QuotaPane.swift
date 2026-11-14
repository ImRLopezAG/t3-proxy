import SwiftUI
import T3ProxyCore

/// Quota per account (live reads through the hub, or the headers it recorded from the last real
/// request), then pooled per provider with reset times, model-specific limits and reset grants.
struct QuotaPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var live: LiveQuotaModel
    @ObservedObject private var forecaster = QuotaForecaster.shared
    @State private var plans: [String: PlanInfo] = [:]
    @State private var confirmReset: (account: Account, intent: LiveQuotaModel.ResetIntent)?
    @State private var confirmClaude: LiveQuotaModel.ClaudeIntent?

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
        .confirmationDialog(confirmClaude.map { intent in
            let name = monitor.accounts.first { $0.id == intent.accountID }.map { live.label(for: $0) } ?? "Claude"
            return "Use \(intent.confirmation.grant.kind.title.lowercased()) on “\(name)”?"
        } ?? "Use reset?",
                            isPresented: Binding(get: { confirmClaude != nil }, set: { if !$0 { confirmClaude = nil } }),
                            titleVisibility: .visible, presenting: confirmClaude) { intent in
            Button(live.claudePending[intent.accountID] == nil ? "Use Reset" : "Retry Reset") {
                Task { await live.useClaudeReset(intent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { intent in
            if live.claudePending[intent.accountID] != nil {
                Text("Sends the same grant and request again. If the first attempt went through, this won't spend another reset.")
            } else {
                let grant = intent.confirmation.grant
                Text("\(claudeResetEffect(grant)) This uses one banked reset and can't be undone.\(grant.expiresAt.map { " This grant expires \(resetExpiry($0))." } ?? "")")
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
                        if a.provider == .claude, let resets = a.quota.claudeResets {
                            Text("\(resets.remaining(at: now)) banked").foregroundStyle(.secondary)
                        } else if a.provider == .codex, let n = live.credits[a.id]?.count ?? a.quota.availableResetCredits {
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
            if p == .claude { claudeResetRows(now: now) }
        } header: {
            HStack(spacing: 6) { ProviderMark(provider: p, size: 14); Text(p.title) }
        } footer: {
            Text(p == .claude
                 ? "Claude reset credits are separate from scheduled quota refills. Fable resets return Fable's contribution to weekly usage; they don't reset the whole week."
                 : "A banked reset starts an account's 5-hour and weekly limits over. Codex grants them occasionally and they expire.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func claudeResetRows(now: Date) -> some View {
        ForEach(monitor.accounts.filter { $0.provider == .claude && !$0.disabled }) { a in
            VStack(alignment: .leading, spacing: 10) {
                Text(live.label(for: a)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                let pending = live.claudePending[a.id]
                let status = a.quota.claudeResets
                let grants = status?.grants.filter { $0.isUnexpired(at: now) } ?? []
                if let status {
                    if grants.isEmpty && pending == nil {
                        Text(status.eligible ? "No banked resets" : "No reset grants reported for this account")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(live.refreshing ? "Checking reset credits…" : "Reset credits unavailable")
                        .foregroundStyle(.secondary)
                }
                ForEach(ClaudeResetKind.allCases, id: \.self) { kind in
                    let group = grants.filter { $0.kind == kind }
                    let retry = pending?.confirmation.grant.kind == kind ? pending?.confirmation.grant : nil
                    if let grant = retry ?? group.first(where: { status?.canUse($0, at: now) == true }) ?? group.first {
                        ClaudeResetRow(grant: grant, grants: group, count: group.reduce(0) { $0 + $1.resetsLeft },
                                       retry: retry != nil, busy: live.preparingClaude == a.id || live.claiming == a.id,
                                       enabled: live.claiming == nil && live.preparingClaude == nil && monitor.management == .connected
                                            && (retry != nil || pending == nil && status?.canUse(grant, at: now) == true)) {
                            Task {
                                if let intent = await live.claudeIntent(for: a, grant: grant) { confirmClaude = intent }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func resetExpiry(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened) + " " + (TimeZone.current.abbreviation(for: date) ?? "")
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

private func claudeResetEffect(_ grant: ClaudeResetGrant) -> String {
    if grant.givesBackWeekly {
        return "Returns Fable's contribution to weekly usage."
            + (grant.clears.contains("five_hour") ? " Also restarts the 5-hour window." : "")
    }
    let session = grant.clears.contains("five_hour"), weekly = grant.clears.contains("seven_day")
    if session && weekly { return "Restarts the 5-hour and weekly limits covered by this grant." }
    if weekly { return "Restarts the weekly limits covered by this grant." }
    if session { return "Restarts the 5-hour limits covered by this grant." }
    return "Resets the usage limits covered by this grant."
}

private struct ClaudeResetRow: View {
    let grant: ClaudeResetGrant
    let grants: [ClaudeResetGrant]
    let count: Int
    let retry: Bool
    let busy: Bool
    let enabled: Bool
    let use: () -> Void
    @State private var details = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(grant.kind.title).fontWeight(.medium)
                Text(retry ? "Pending" : "\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Text(retry ? "Unconfirmed" : expiry)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button { details.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel("\(grant.kind.title) details")
                .popover(isPresented: $details, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(grant.kind.title).font(.headline)
                        Text(claudeResetEffect(grant)).foregroundStyle(.secondary)
                        ForEach(grants.isEmpty ? [grant] : grants) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(g.resetsLeft) available · \(g.title)")
                                Text(g.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry reported")
                                    .foregroundStyle(.secondary)
                                if g.paused || !g.usableNow { Text(g.paused ? "Paused" : "Not currently usable").foregroundStyle(.secondary) }
                            }.font(.caption)
                        }
                    }.padding(16).frame(width: 300, alignment: .leading)
                }
            if busy { ProgressView().controlSize(.small) }
            Button(retry ? "Retry Reset…" : "Use Reset…", action: use).disabled(!enabled)
                .accessibilityLabel("\(retry ? "Retry" : "Use") \(grant.kind.title)…")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var expiry: String {
        guard let date = grants.compactMap(\.expiresAt).min() else { return "No expiry reported" }
        return "\(grants.count > 1 ? "Next expires" : "Expires") \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
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
