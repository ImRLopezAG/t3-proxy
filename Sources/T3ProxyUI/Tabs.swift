import SwiftUI
import T3ProxyCore

struct Sparkline: View {
    let values: [Int64]; let color: Color
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 0, 1)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(v) / CGFloat(maxV)) * 0.9 + g.size.height * 0.05)
            }
            if pts.count > 1 {
                let line = smooth(pts)
                var area = line
                let _ = area.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                let _ = area.addLine(to: CGPoint(x: 0, y: g.size.height))
                area.fill(LinearGradient(colors: [color.opacity(0.42), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                line.stroke(color, lineWidth: 1.4)
            } else {
                Rectangle().fill(color.opacity(0.35)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
    private func smooth(_ p: [CGPoint]) -> Path {
        var path = Path(); path.move(to: p[0])
        for i in 1..<p.count {
            let mid = (p[i - 1].x + p[i].x) / 2
            path.addCurve(to: p[i], control1: CGPoint(x: mid, y: p[i - 1].y), control2: CGPoint(x: mid, y: p[i].y))
        }
        return path
    }
}

struct OverviewTab: View {
    let c: PanelContent
    @Binding var range: TokenRange
    var openSettings: () -> Void = {}
    @ObservedObject private var forecaster = QuotaForecaster.shared
    @ObservedObject private var t3 = T3CodeModel.shared()
    @Environment(\.colorScheme) private var s
    var body: some View {
        let t = Theme(s)
        let setup = SetupChecklist(c, t3Connected: t3.status.isConnected)
        VStack(alignment: .leading, spacing: 0) {
            if setup.needsSetup && !c.isSample { SetupGuideCard(list: setup, openSettings: openSettings).padding(.top, 8) }
            hero(t).padding(.vertical, 12)
            Rule()
            SectionTitle(text: "Remaining quota").padding(.top, 8).padding(.bottom, 6)
            quotaRow(.claude, t); Rule().padding(.vertical, 5); quotaRow(.codex, t)
            Rule().padding(.top, 8)
            history(t).padding(.top, 8)
        }
    }
    private func hero(_ t: Theme) -> some View {
        let r = c.recent
        let total = r?.totals.total ?? (summarize(c.accounts, .claude).total + summarize(c.accounts, .codex).total)
        let unit = r == nil ? "Requests" : "Tokens"
        let shown = r != nil || c.hasAccounts
        return HStack(spacing: 13) {
            VStack(spacing: 2) {
                Text(shown ? compact(total) : "—").font(.system(size: 38, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
                if let cost = r?.totalCost {
                    Text(cost.short).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(t.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .help("Estimated at API list prices, per model, from requests through the hub" + (cost.unpriced.isEmpty ? "" : " · \(cost.label)"))
                }
                if r != nil && !c.isSample {
                    // Native pop-up menu: the period the headline and sparklines cover.
                    Picker(selection: $range) {
                        ForEach(TokenRange.allCases) { Text($0.title).tag($0) }
                    } label: { EmptyView() }
                    .pickerStyle(.menu).buttonStyle(.borderless).menuIndicator(.visible).labelsHidden()
                    .font(.system(size: 10.5)).foregroundStyle(t.secondary).fixedSize()
                } else {
                    Text(c.isSample ? "\(unit) · sample" : "\(unit) · \(requestWindowLabel)").font(.system(size: 10.5)).lineLimit(1).fixedSize().foregroundStyle(t.secondary)
                }
                if c.tokensStaleSince != nil {
                    Label("Tokens not recording", systemImage: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1).fixedSize()
                }
            }.frame(width: 122)
            .help(r.map { x in
                let s = x.totals
                return "\(compact(s.total)) tokens · \(compact(s.input)) input · \(compact(s.output)) output · \(compact(s.cached)) cache read · \(s.requests) requests"
            } ?? c.tokensStaleSince.map { d in
                d == .distantPast ? "Token usage has no records yet, so request counts are shown."
                    : "No token usage recorded since \(d.formatted(date: .omitted, time: .shortened)) while the proxy kept serving requests, so request counts are shown."
            } ?? "")
            VRule()
            VStack(spacing: 8) { providerActivity(.claude, t); providerActivity(.codex, t) }
        }.frame(height: 100)
    }
    private func providerActivity(_ p: Provider, _ t: Theme) -> some View {
        let values = c.recent?.tokens(p) ?? summarize(c.accounts, p).requests
        let shown = c.recent != nil || c.hasAccounts
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                ProviderMark(provider: p, size: 15)
                Text(p.title).font(.system(size: 12, weight: .bold))
                Spacer()
                if let cost = c.recent?.cost?[p] {
                    Text(cost.short).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(t.secondary).lineLimit(1)
                }
                Text(shown ? compact(values.reduce(0, +)) : "—").font(.system(size: 12, weight: .bold))
            }
            Sparkline(values: values, color: t.tint(p)).frame(height: 16)
            HStack { Text(shown ? (c.recent != nil ? range.startLabel : "3h 20m ago") : " "); Spacer(); Text(shown ? "Now" : " ") }.font(.system(size: 9)).foregroundStyle(t.secondary)
        }
    }
    private func quotaRow(_ p: Provider, _ t: Theme) -> some View {
        let short = c.quota.first { $0.provider == p && $0.kind == .session }
        let weekly = c.quota.first { $0.provider == p && $0.kind == .weekly }
        let accounts = max(short?.accounts ?? 0, weekly?.accounts ?? 0)
        let measured = max(short?.measured ?? 0, weekly?.measured ?? 0)
        let reset = [short?.resetAt, weekly?.resetAt].compactMap { $0 }.min()
        return HStack(spacing: 11) {
            ProviderMark(provider: p, size: 21)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.system(size: 12, weight: .bold))
                Text(measured == 0 ? "Not measured" : measured == accounts ? "\(accounts) account\(accounts == 1 ? "" : "s")" : "\(measured) of \(accounts) measured")
                    .font(.system(size: 10.5)).foregroundStyle(t.secondary).lineLimit(1)
                if let reset { Text("resets \(shortDuration(until: reset))").font(.system(size: 10.5)).foregroundStyle(t.secondary).lineLimit(1) }
                if !c.isSample, let out = runsOut(p) {
                    Text("out \(out.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                        .help("At the measured pace this pool runs out before its next reset.")
                }
            }.frame(width: 90, alignment: .leading)
            VRule().frame(height: 28)
            VStack(spacing: 4) { bar("Short", short, p, t); bar("Weekly", weekly, p, t) }
        }
    }
    /// Soonest projected run-out across the 5-hour and weekly pools; nil without enough history.
    private func runsOut(_ p: Provider) -> Date? {
        QuotaWindowKind.allCases.compactMap { k -> Date? in
            if case .runsOut(let d)? = forecaster.forecast(p, k) { return d }
            return nil
        }.min()
    }
    private func bar(_ label: String, _ q: QuotaPool?, _ p: Provider, _ t: Theme) -> some View {
        let v = q?.remaining
        return HStack(spacing: 8) {
            Text(label).font(.system(size: 10.5)).frame(width: 38, alignment: .leading)
            if let v {
                ProgressView(value: v, total: 100).progressViewStyle(.linear).tint(t.tint(p)).controlSize(.small)
            } else {
                Capsule().fill(t.track).frame(height: 4).frame(height: 14)   // same row height as a bar
            }
            Text(v.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 10.5, weight: .bold)).lineLimit(1).fixedSize().frame(width: 34, alignment: .trailing)
        }
        .help(q.map { pool in
            let r = pool.resetAt.map { ", resets \(shortDuration(until: $0))" } ?? ""
            let f = c.isSample ? "" : forecaster.forecast(p, pool.kind).map { " · \($0.phrase)" } ?? ""
            return "\(pool.measured) of \(pool.accounts) accounts measured\(r)\(f)"
        } ?? "")
    }
    private func history(_ t: Theme) -> some View { DailyHistorySection(c: c) }
}
struct ActiveTab: View {
    let c: PanelContent
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let list = c.accounts.filter { !$0.held } + c.accounts.filter(\.held)
        let providers = Provider.allCases.filter { provider in list.contains { $0.provider == provider } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack { SectionTitle(text: "Accounts"); Spacer(); Pill(text: c.held > 0 ? "\(c.active) active · \(c.held) held" : "\(list.count)") }.padding(.vertical, 8)
            if !c.hasAccounts { Note(text: accountsHint(c)).padding(.bottom, 4) }
            else if list.isEmpty { Note(text: "No accounts.") }
            let rows = VStack(spacing: 0) {
                ForEach(providers, id: \.self) { provider in
                    let group = list.filter { $0.provider == provider }
                    HStack(spacing: 5) {
                        Text(provider.title).font(.system(size: 10, weight: .semibold))
                        Text("\(group.count)").font(.system(size: 9)).monospacedDigit()
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, provider == providers.first ? 4 : 10).padding(.bottom, 2)
                    ForEach(group) { a in
                        AccountRow(account: a, now: now, sample: c.isSample, heldLine: heldLine(a, now: now),
                                   endpoint: c.endpoint, connected: c.management == .connected)
                        if a != group.last { Rule() }
                    }
                }
            }
            // ImageRenderer cannot draw a ScrollView; sample stills lay the rows out directly.
            if c.isSample { rows } else {
                ScrollView { rows.overlayScroller() }
                    .frame(maxHeight: min(420, (NSScreen.main?.visibleFrame.height ?? 800) - 210)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func heldLine(_ a: Account, now: Date) -> String {
        var s = a.heldReason ?? "Held"
        if let r = a.releaseAt, r > now { s += " · back in \(shortDuration(until: r, from: now))" }
        return s
    }
}

/// One account, compact: name, then one line per limit window the account really has (a plan without a 5-hour
/// limit shows none; model windows such as "Fable weekly" appear). Pace, resets and usage are in the hover card.
struct AccountRow: View {
    let account: Account
    let now: Date
    let sample: Bool
    let heldLine: String
    let endpoint: String
    let connected: Bool
    @Environment(\.colorScheme) private var s

    var body: some View {
        let t = Theme(s)
        let a = account
        let windows = a.quota.accountWindows().map { WindowState($0, a.quota, now: now) }
        let urgent = windows.first { $0.urgent }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProviderMark(provider: a.provider, size: 15, name: a.providerName)
                Text((a.nickname ?? a.name).emailHidden).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    .layoutPriority(1)
                if a.held {
                    Text(heldLine).font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !sample, let live = LiveQuotaModel.primary {
                    HStack(spacing: 4) {
                        QuotaResetControls(account: a, live: live, now: now, compact: true, connected: connected)
                    }
                }
            }
            if a.provider == .other {
                Text("No quota data").font(.system(size: 10)).foregroundStyle(t.secondary)
            } else if windows.isEmpty {
                Text("No limit reading yet").font(.system(size: 10)).foregroundStyle(t.secondary)
            } else {
                ForEach(windows, id: \.window.id) { AccountWindowLine(state: $0, tint: t.tint(a.provider)) }
            }
            if let u = urgent, let p = u.pace {
                Label("\(u.window.title): \(p.summary)" + (p.projection(now: now).map { " · \($0)" } ?? ""), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .opacity(a.disabled ? 0.6 : 1)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // Sample stills skip the hover sensor: ImageRenderer can't draw AppKit views.
        .hoverCard(enabled: !sample, interactive: true, clickToOpen: true) {
            QuotaAccountDetails(account: a, label: a.quotaLabel, endpoint: endpoint,
                                live: LiveQuotaModel.primary, connected: connected).id(a.id)
        }
    }
}

func accountsHint(_ c: PanelContent) -> String {
    switch c.management {
    case .noKey: return "Add a management key in Settings → Connection to see accounts."
    case .rejected: return "The proxy rejected this key. T3 Proxy stopped asking so it can't trigger the proxy's lockout. Enter a new key to retry."
    case .failed(let m): return "Couldn't read accounts: \(m)."
    case .connected: return ""
    }
}

struct PillButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
    }
}
