import SwiftUI
import T3ProxyCore

/// Provider quota lanes for the resizable Settings page.
struct QuotaDashboard: View {
    let accounts: [Account]
    let endpoint: String
    let now: Date
    var live: LiveQuotaModel? = nil
    var connected = true
    var sample = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach([Provider.codex, .claude], id: \.self) { provider in
                let own = accounts.filter { $0.provider == provider }
                if !own.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            ProviderMark(provider: provider, size: 17)
                            Text(provider.title).font(.system(size: 14, weight: .semibold))
                            let count = own.filter { !$0.disabled }.count
                            Text("\(count) subscription\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        let lanes = quotaLanes(accounts, provider: provider, now: now)
                        ForEach(lanes) { lane in
                            laneView(lane, provider: provider)
                        }
                        let unmeasured = own.filter { !$0.disabled && $0.quota.windows.isEmpty }
                        if !unmeasured.isEmpty { supplemental(unmeasured, title: "Awaiting readings") }
                        let disabled = own.filter(\.disabled)
                        if !disabled.isEmpty { supplemental(disabled, title: "Disabled") }
                    }
                }
            }
            let others = accounts.filter { $0.provider == .other }
            if !others.isEmpty { supplemental(others, title: "Other accounts") }
            if accounts.isEmpty { Note(text: "No accounts registered.") }
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 2, height: 12)
                    Text("Even pace")
                }
                Text("Ticks: local midnight")
                Text("W: Weekly · F: Fable · Full: both limits")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Account shares are equally weighted. Unknown readings are excluded from averages. Hover or click an account for details.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func laneView(_ lane: QuotaLane, provider: Provider) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(lane.title).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(lane.remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    if lane.remaining != nil { Text("left").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if let gain = lane.resetGainPercent, gain >= 0.5 {
                    Label("+\(Int(gain.rounded()))%", systemImage: "arrow.clockwise")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("Share of this measured pool restored at the next scheduled reset, assuming no further use.")
                }
                Text("\(lane.measured)/\(lane.entries.count) measured").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(width: 108, alignment: .leading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 8)], spacing: 8) {
                ForEach(lane.entries) { entry in
                    QuotaAccountTile(entry: entry, label: entry.account.quotaLabel(among: accounts),
                                     endpoint: endpoint, now: now, live: live, connected: connected, sample: sample)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(scheme == .dark ? 0.025 : 0.018), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07), lineWidth: 1))
    }

    private func supplemental(_ list: [Account], title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(list) { account in
                    HStack(spacing: 6) {
                        ProviderMark(provider: account.provider, size: 12, name: account.providerName)
                        Text(account.quotaLabel(among: accounts)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(account.disabled ? "Disabled" : account.heldReason ?? "No reading").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 10)).padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .hoverCard(enabled: !sample, interactive: true, clickToOpen: true) {
                        QuotaAccountDetails(account: account, label: account.quotaLabel(among: accounts),
                                            endpoint: endpoint, live: live, connected: connected)
                            .id(account.id)
                    }
                }
            }
        }
    }
}

/// Observes banked tickets and uncertain attempts as well as the monitor-owned account readings.
struct LiveQuotaDashboard: View {
    let accounts: [Account]
    let endpoint: String
    let now: Date
    @ObservedObject var live: LiveQuotaModel
    var connected = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome = live.outcome {
                Label(outcome.text, systemImage: outcome.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(outcome.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuotaDashboard(accounts: accounts, endpoint: endpoint, now: now, live: live, connected: connected)
        }
    }
}

private struct QuotaAccountTile: View {
    let entry: QuotaLane.Entry
    let label: String
    let endpoint: String
    let now: Date
    let live: LiveQuotaModel?
    let connected: Bool
    let sample: Bool
    @Environment(\.colorScheme) private var scheme

    private var state: WindowState { WindowState(entry.window, entry.account.quota, now: now) }
    private var laneID: String { entry.window.window.kind?.rawValue ?? entry.window.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if state.urgent {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(state.pace?.summary ?? "")
                }
                Spacer(minLength: 0)
                if entry.remaining != nil, let reset = entry.window.window.resetAt {
                    Label(shortDuration(until: reset, from: now), systemImage: "arrow.clockwise")
                        .font(.system(size: 9)).fixedSize().foregroundStyle(.secondary)
                }
                if let live {
                    QuotaResetControls(account: entry.account, live: live, now: now, windowID: laneID, compact: true, connected: connected)
                }
            }
            HStack(spacing: 8) {
                PaceBar(remaining: entry.remaining, pace: state.pace, tint: state.fill(Theme(scheme).tint(entry.account.provider)))
                    .frame(height: 5)
                if let remaining = entry.remaining {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(remaining <= 0 ? .red : remaining < 10 ? .orange : .primary)
                        .frame(width: 34, alignment: .trailing)
                } else {
                    Text(state.expired ? "Expired" : "Unknown").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .font(.system(size: 11)).padding(9)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .hoverCard(enabled: !sample, interactive: true, clickToOpen: true) {
            QuotaAccountDetails(account: entry.account, label: label, endpoint: endpoint,
                                selected: entry.window.id, live: live, connected: connected)
                .id(entry.account.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(entry.window.title), \(entry.remaining.map { "\(Int($0.rounded())) percent left" } ?? "reading unavailable")")
    }
}

struct QuotaAccountDetails: View {
    let account: Account
    let label: String
    let endpoint: String
    var selected: String? = nil
    let live: LiveQuotaModel?
    let connected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var cachedPlan: PlanInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .task(id: account.id) {
            cachedPlan = nil
            guard let index = account.authIndex else { return }
            let loaded = await Task.detached { PlanCache.load()[PlanCache.accountKey(index)] }.value
            guard !Task.isCancelled else { return }
            cachedPlan = loaded
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderMark(provider: account.provider, size: 18, name: account.providerName)
                Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            if let plan = account.quota.planInfo?.plan ?? account.quota.plan {
                detail("Plan", plan.capitalized)
            } else if let index = account.authIndex,
                      let cached = live?.verifiedPlan(provider: account.provider, authIndex: index, chatgptAccountID: account.chatgptAccountID) {
                detail("Plan", cached.plan.capitalized + " · last verified " + cached.readAt.formatted(date: .abbreviated, time: .shortened))
            } else if let plan = cachedPlan?.plan {
                detail("Plan", plan.capitalized + " · cached")
            }
            if let organization = account.quota.planInfo?.org ?? cachedPlan?.org { detail("Team", organization) }
            detail("Via", endpoint)
            if let seen = account.quota.observedAt {
                detail(account.quota.source == .live ? "Live read" : "Recorded", seen.formatted(date: .omitted, time: .shortened))
            }
            if account.held {
                Text((account.heldReason ?? "Held") + (account.releaseAt.map { " · back in \(shortDuration(until: $0, from: now))" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Rule()
            ForEach(account.quota.accountWindows(), id: \.id) { window in
                let state = WindowState(window, account.quota, now: now)
                AccountWindowPace(state: state, tint: Theme(scheme).tint(account.provider), now: now)
                if window.id == selected, let pace = state.pace {
                    detail("Even pace", "\(Int(pace.expectedRemaining.rounded()))% left by now")
                }
            }
            if let live {
                Rule()
                QuotaResetControls(account: account, live: live, now: now, connected: connected)
                if live.preparingClaude == account.id || live.claiming == account.id {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking reset…").font(.system(size: 10)) }
                }
            }
            DisclosureGroup("Token usage") {
                AccountHoverCard(account: account, tint: Theme(scheme).tint(account.provider), now: now, usageOnly: true)
                    .padding(.top, 6)
            }.font(.system(size: 10))
        }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10.5))
    }
}
