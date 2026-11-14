import SwiftUI
import T3ProxyCore

struct QuotaDashboard: View {
    let accounts: [Account]
    let endpoint: String
    let now: Date
    var live: LiveQuotaModel? = nil
    var connected = true
    var sample = false
    var inspect: (Account) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([Provider.claude, .codex, .other], id: \.self) { provider in
                let own = accounts.filter { $0.provider == provider }.sorted { $0.quotaLabel(among: accounts).localizedStandardCompare($1.quotaLabel(among: accounts)) == .orderedAscending }
                if !own.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProviderMark(provider: provider, size: 16)
                            Text(provider == .other ? "Other providers" : provider.title).fontWeight(.semibold)
                            Spacer()
                            Text("\(own.count) accounts").font(.caption).foregroundStyle(.secondary)
                        }
                        if provider != .other {
                            let lanes = quotaLanes(accounts, provider: provider, now: now)
                            HStack(spacing: 18) {
                                ForEach(lanes.filter { $0.id == QuotaWindowKind.session.rawValue || $0.id == QuotaWindowKind.weekly.rawValue }) { lane in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(lane.title).font(.caption).foregroundStyle(.secondary)
                                        Text(lane.remaining.map { "\(Int($0.rounded()))% left" } ?? "No reading").font(.headline).monospacedDigit()
                                        Text("\(lane.measured) measured").font(.caption2).foregroundStyle(.tertiary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        ForEach(own) { account in
                            row(account)
                                .settingsQuotaDetails(enabled: !sample, inspect: { inspect(account) }) {
                                    QuotaAccountDetails(account: account, label: account.quotaLabel(among: accounts), endpoint: endpoint,
                                                        live: live, connected: connected).id(account.id)
                                }
                            if account.id != own.last?.id { Divider() }
                        }
                    }
                }
            }
            if accounts.isEmpty { Text("No accounts registered.").foregroundStyle(.secondary) }
            Text("Provider averages equally weight measured accounts; they are not shared subscription capacity. Bars show remaining quota and pace. Hover for resets; click to pin details.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func row(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.quotaLabel(among: accounts)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if account.disabled { Text("Disabled").foregroundStyle(.secondary) }
                else if account.held { Text(account.heldReason ?? "Held").foregroundStyle(.orange).lineLimit(1) }
                else if let plan = account.quota.planInfo?.plan ?? account.quota.plan {
                    Text(plan.capitalized).foregroundStyle(.secondary).lineLimit(1)
                }
            }.font(.callout)
            HStack(spacing: 16) {
                AccountQuotaBar(quota: account.quota, kind: .session, provider: account.provider, now: now)
                AccountQuotaBar(quota: account.quota, kind: .weekly, provider: account.provider, now: now)
            }
            if account.quota.accountWindows().contains(where: { $0.window.kind == nil }) {
                Text("Additional limits in details").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4).contentShape(Rectangle()).opacity(account.disabled ? 0.6 : 1)
    }
}

struct LiveQuotaDashboard: View {
    let accounts: [Account]
    let endpoint: String
    let now: Date
    @ObservedObject var live: LiveQuotaModel
    var connected = true
    var inspect: (Account) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connected { Label("Hub disconnected · showing last readings", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let outcome = live.outcome {
                Label(outcome.text, systemImage: outcome.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(outcome.isError ? .orange : .green)
            }
            QuotaDashboard(accounts: accounts, endpoint: endpoint, now: now, live: live, connected: connected, inspect: inspect)
        }
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
