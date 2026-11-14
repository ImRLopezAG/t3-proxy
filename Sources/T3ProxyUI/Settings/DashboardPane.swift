import Charts
import SwiftUI
import T3ProxyCore

struct DashboardPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var usage = UsageModel.shared
    @ObservedObject var live: LiveQuotaModel
    @State private var historyDays = 7
    @State private var filter = Filter.all
    @State private var selected: UsageDay?
    @State private var rows: [UsageBreakdownRow] = []
    @State private var detail: UsageDayDetail?
    @State private var inspectedID: String?
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.colorScheme) private var s

    enum Filter: String, CaseIterable {
        case all = "All", claude = "Claude", codex = "Codex"
        var provider: Provider? { self == .claude ? .claude : self == .codex ? .codex : nil }
    }
    private var range: UsageRangeDetail? { usage.ranges[historyDays] }
    private var inspected: Account? { monitor.accounts.first { $0.id == inspectedID } }

    var body: some View {
        GeometryReader { geometry in
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                stats
                if geometry.size.width >= 850 {
                    HStack(alignment: .top, spacing: 20) {
                        limits.frame(maxWidth: .infinity)
                        activity.frame(maxWidth: .infinity)
                    }
                } else { VStack(spacing: 20) { limits; activity } }
                accountHistory
                if selected != nil { dayDetails }
            }.padding(24).overlayScroller()
                .environment(\.settingsScrollOffset, scrollOffset)
          }
          .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in scrollOffset = value }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Dashboard")
        .inspector(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let inspected {
                ScrollView {
                    QuotaAccountDetails(account: inspected, label: inspected.quotaLabel(among: monitor.accounts),
                                        endpoint: monitor.endpointLabel, live: live, connected: monitor.management == .connected)
                        .id(inspected.id).padding(20)
                }.inspectorColumnWidth(min: 310, ideal: 340, max: 390)
            }
        }
        .toolbar {
            Button {
                usage.refresh()
                Task { await monitor.refresh(); await live.refresh() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(monitor.refreshing || live.refreshing)
        }
        .onAppear { usage.refresh() }
        .task(id: monitor.management) { if monitor.management == .connected { await live.refresh() } }
        .task(id: usage.updatedAt) {
            guard let day = selected?.date else { return }
            let value = await usage.detail(for: day)
            if selected?.date == day { detail = value; rows = value?.rows ?? [] }
        }
        .onChange(of: monitor.accounts) { _, accounts in
            if let inspectedID, !accounts.contains(where: { $0.id == inspectedID }) { self.inspectedID = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your proxy at a glance").font(.title2).fontWeight(.semibold)
                HStack(spacing: 12) {
                    Text(monitor.accountsUpdatedAt.map { "Accounts read \($0.formatted(date: .omitted, time: .shortened))" } ?? "Accounts not read yet")
                    Text(usage.updatedAt.map { "History read \($0.formatted(date: .omitted, time: .shortened))" } ?? "History not read yet")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("History range", selection: $historyDays) {
                Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 215)
        }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
            stat("Recorded tokens", value: range.map { compactTokens($0.totals.total) } ?? "—", symbol: "text.word.spacing", note: historyLabel)
            stat("Requests", value: range.map { $0.totals.requests.formatted() } ?? "—", symbol: "arrow.left.arrow.right", note: range.map { "\($0.totals.failed.formatted()) failed" } ?? historyLabel)
            stat("API-equivalent value", value: range?.cost.short ?? "—", symbol: "dollarsign.circle", note: "Estimate · \(historyLabel.lowercased())")
            stat("Enabled accounts", value: monitor.accountsUpdatedAt == nil ? "—" : "\(monitor.accounts.filter { !$0.disabled && !$0.held }.count)/\(monitor.accounts.count)", symbol: "person.2", note: "Enabled and outside cooldown")
        }
    }

    private var historyLabel: String { historyDays == 1 ? "Today" : "Last \(historyDays) days" }

    private func stat(_ title: String, value: String, symbol: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
    }

    private var limits: some View {
        DashboardSection("Live limits", subtitle: live.lastRefresh.map { "Last attempt \($0.formatted(date: .omitted, time: .shortened))" } ?? "Current provider readings") {
            if monitor.accountsUpdatedAt == nil {
                Label(monitor.management == .connected ? "Waiting for accounts" : "Connect the hub in Settings → CLIProxyAPI", systemImage: "gauge.with.dots.needle.0percent")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LiveQuotaDashboard(accounts: monitor.accounts, endpoint: monitor.endpointLabel, now: context.date,
                                       live: live, connected: monitor.management == .connected,
                                       inspect: { inspectedID = $0.id })
                }
            }
        }
    }

    private var activity: some View {
        DashboardSection("Usage activity", subtitle: "Daily recorded tokens · \(historyLabel.lowercased())") {
            if !usage.days.isEmpty, case .failed(let message) = usage.state {
                Label("Showing saved history · " + message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if usage.days.isEmpty { historyState }
            else {
                chart.frame(height: 170)
                Divider().padding(.vertical, 6)
                HStack {
                    Text("Last 12 months").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Picker("Calendar provider", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                ScrollView(.horizontal) { calendar.fixedSize() }.defaultScrollAnchor(.trailing)
                Text(yearSummary).font(.caption).foregroundStyle(.secondary)
                Text("Select a day for its account and model breakdown.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var historyState: some View {
        switch usage.state {
        case .loading: ProgressView("Reading history…")
        case .missing:
            Text("No token history yet.").foregroundStyle(.secondary)
            Button("Recording settings…") { SettingsRouter.shared.pane = .recording }
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .loaded: Text("No requests recorded in the last year.").foregroundStyle(.secondary)
        }
    }

    private var accountHistory: some View {
        DashboardSection("Usage by account", subtitle: historyLabel) {
            if let error = usage.rangeError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let range {
                NativeUsageAccountTable(accounts: range.accounts, identities: monitor.accounts)
                Text(range.cost.label).font(.caption).foregroundStyle(.secondary)
            } else { Text("Account breakdown unavailable").foregroundStyle(.secondary) }
            Text("API-equivalent list prices, not subscription spending. Unpriced models are excluded and counted; + marks partial totals.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dayDetails: some View {
        DashboardSection(selected.map { usageDayLabel($0.date) } ?? "Day", subtitle: "Recorded account and model breakdown") {
            if let selected {
                HStack {
                    Text("\(compactTokens(selected.totals.total)) tokens · \(selected.totals.requests) requests · \(selected.totals.failed) failed").font(.callout).monospacedDigit()
                    Spacer()
                    Button("Close day") { self.selected = nil; detail = nil; rows = [] }
                }
                if let detail {
                    Text("API-equivalent value: \(detail.cost.label)").font(.caption).foregroundStyle(.secondary)
                    NativeUsageAccountTable(accounts: UsageRangeDetail(rows: rows).accounts, identities: monitor.accounts)
                    Table(rows) {
                        TableColumn("Model") { Text($0.model.isEmpty ? "—" : $0.model).lineLimit(1) }
                        TableColumn("Account") { Text(nativeUsageAccountLabel($0.accountKey, provider: $0.provider, accounts: monitor.accounts)).lineLimit(1) }
                        TableColumn("Tokens") { Text(compactTokens($0.totals.total)).monospacedDigit() }.width(80)
                        TableColumn("Requests") { Text("\($0.totals.requests)").monospacedDigit() }.width(65)
                        TableColumn("Est. value") { Text($0.estimatedCost.map { "≈ \(formatUSD($0))" } ?? "—").monospacedDigit() }.width(95)
                    }.frame(height: 180)
                } else if case .failed(let message) = usage.state {
                    Text(message).foregroundStyle(.orange)
                } else {
                    Text("Day details unavailable or still loading. Select the day again to retry.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var calendar: some View {
        let cols = HeatmapGrid.columns(usage.days, weeks: 53)
        let cell: CGFloat = 7, gap: CGFloat = 2
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28)
                ForEach(cols.indices, id: \.self) { w in
                    Text(monthLabel(cols, w)).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                        .frame(width: cell + gap, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(d % 2 == 1 ? weekday(d) : "").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 28, height: cell, alignment: .leading)
                    }
                }
                HeatmapGrid(days: usage.days, weeks: 53, cell: cell, gap: gap, provider: filter.provider, selected: selected?.date) { day in
                    selected = day
                    rows = []
                    detail = usage.details[day.date]
                    Task {
                        let r = await usage.detail(for: day.date)
                        // A slower answer for an earlier click must not replace the current day's rows.
                        if selected?.date == day.date { rows = r?.rows ?? []; detail = r }
                    }
                }
            }
            HStack { Spacer(); HeatLegend(cell: 9) }
        }.padding(.vertical, 4)
    }

    private var chart: some View {
        let t = Theme(s)
        let recent = Array(usage.days.suffix(historyDays))
        // Always both providers: the Provider picker belongs to the calendar only.
        let providers: [Provider] = [.claude, .codex]
        return Chart {
            ForEach(providers, id: \.self) { p in
                ForEach(recent) { d in
                    // Swift Charts stacks areas by default, which put Codex's fill on top of Claude's.
                    AreaMark(x: .value("Day", d.date, unit: .day), y: .value("Tokens", d.tokens(p)), series: .value("Provider", p.title), stacking: .unstacked)
                        .foregroundStyle(by: .value("Provider", p.title)).opacity(0.28).interpolationMethod(.monotone)
                    LineMark(x: .value("Day", d.date, unit: .day), y: .value("Tokens", d.tokens(p)), series: .value("Provider", p.title))
                        .foregroundStyle(by: .value("Provider", p.title)).interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(["Claude": t.tint(.claude), "Codex": t.tint(.codex)])
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int64.self) { Text(compactTokens(n)) } } } }
    }

    private var yearSummary: String {
        let p = filter.provider
        let year = usage.days.reduce(Int64(0)) { $0 + $1.tokens(p) }
        let active = usage.days.filter { $0.tokens(p) > 0 }.count
        let best = usage.days.max { $0.tokens(p) < $1.tokens(p) }
        var s = "\(compactTokens(year)) tokens · \(active) active days"
        if let best, best.tokens(p) > 0 { s += " · busiest \(best.date.formatted(.dateTime.month(.abbreviated).day())) (\(compactTokens(best.tokens(p))))" }
        return s
    }

    private func monthLabel(_ cols: [[UsageDay?]], _ w: Int) -> String {
        guard let first = cols[w].compactMap({ $0 }).first?.date else { return "" }
        let cal = Calendar.current
        let m = cal.component(.month, from: first)
        let prev = w > 0 ? cols[w - 1].compactMap({ $0 }).first.map { cal.component(.month, from: $0.date) } : nil
        return prev == m || (w == 0 && cal.component(.day, from: first) > 7) ? "" : first.formatted(.dateTime.month(.abbreviated))
    }
    private func weekday(_ row: Int) -> String {
        let cal = Calendar.current
        return cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + row) % 7]
    }
}


struct DashboardSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
    }
}
