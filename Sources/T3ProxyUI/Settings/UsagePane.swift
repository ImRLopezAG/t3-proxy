import Charts
import SwiftUI
import T3ProxyCore

/// Full-year token calendar, a day's breakdown, and a daily per-provider chart.
struct UsagePane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var usage = UsageModel.shared
    @State private var filter = Filter.all
    @State private var span = 30
    @State private var selected: UsageDay?
    @State private var rows: [UsageBreakdownRow] = []
    @State private var detail: UsageDayDetail?
    @State private var costSpan = 7
    @Environment(\.colorScheme) private var s

    enum Filter: String, CaseIterable { case all = "All", claude = "Claude", codex = "Codex"
        var provider: Provider? { self == .claude ? .claude : self == .codex ? .codex : nil } }

    var body: some View {
        Group {
            if usage.days.isEmpty { empty } else { content }
        }
        .navigationTitle("Usage")
        .toolbar { ToolbarItem { Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Reload") } }
        .onAppear { usage.refresh() }
        .task(id: usage.updatedAt) {
            guard let day = selected?.date else { return }
            let value = await usage.detail(for: day)
            if selected?.date == day { detail = value; rows = value?.rows ?? [] }
        }
    }

    @ViewBuilder private var empty: some View {
        // The recording switch stays reachable when there is no history yet: that is when a new install needs it.
        Form {
            UsageRecordingSection()
            Section {
                switch usage.state {
                case .loading: ProgressView().frame(maxWidth: .infinity)
                case .missing: ContentUnavailableView("No token history", systemImage: "calendar",
                                                     description: Text("Turn on recording above to start a history. Nothing is estimated."))
                case .failed(let m): ContentUnavailableView("Couldn't read token history", systemImage: "exclamationmark.triangle", description: Text(m))
                case .loaded: ContentUnavailableView("No token history", systemImage: "calendar", description: Text("No requests recorded in the last year."))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var content: some View {
        Form {
            UsageRecordingSection()
            Section {
                ForEach([1, 7, 30], id: \.self) { days in
                    LabeledContent(days == 1 ? "Today" : "Last \(days) days") {
                        Text(usage.ranges[days].map { $0.cost.label } ?? "—").monospacedDigit()
                    }
                }
                if let error = usage.rangeError { Text(error).foregroundStyle(.orange) }
            } header: { Text("Estimated API cost") } footer: {
                Text("API-equivalent list prices; subscriptions aren't billed per token. Today is included in each range. Unpriced models are excluded and counted explicitly; + marks partial totals.")
            }
            Section("Cost per account") {
                Picker("Range", selection: $costSpan) { Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented)
                if let range = usage.ranges[costSpan] {
                    NativeUsageAccountTable(accounts: range.accounts, identities: monitor.accounts)
                } else { Text("Cost breakdown unavailable").foregroundStyle(.secondary) }
            }
            Section {
                Picker("Provider", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                calendar
                Text(yearSummary).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } header: { Text("Last 12 months") }

            Section {
                if let d = selected {
                    let cost = detail.map { "  ·  est. \($0.cost.label)" } ?? ""
                    LabeledContent(usageDayLabel(d.date), value: "\(compactTokens(d.totals.total)) tokens · \(d.totals.requests) requests · \(d.totals.failed) failed\(cost)")
                        .monospacedDigit()
                    ForEach([Provider.claude, .codex, .other], id: \.self) { p in
                        if let v = d.byProvider[p] {
                            let c = detail?.costByProvider[p].map { " · est. \($0.label)" } ?? ""
                            LabeledContent {
                                Text("\(compactTokens(v.total)) · in \(compactTokens(v.input)) · out \(compactTokens(v.output)) · cache \(compactTokens(v.cached))\(c)").monospacedDigit()
                            } label: {
                                Label { Text(p.title) } icon: { ProviderMark(provider: p, size: 14) }
                            }
                        }
                    }
                    Table(rows) {
                        TableColumn("Provider") { Text($0.provider.title) }.width(70)
                        TableColumn("Model") { Text($0.model.isEmpty ? "—" : $0.model).lineLimit(1) }
                        TableColumn("Account") { Text(nativeUsageAccountLabel($0.accountKey, provider: $0.provider, accounts: monitor.accounts)).lineLimit(1) }.width(min: 100, ideal: 140)
                        TableColumn("Tokens") { Text(compactTokens($0.totals.total)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(60)
                        TableColumn("Requests") { Text("\($0.totals.requests)").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(60)
                        TableColumn("Est. cost") { r in
                            Text(r.estimatedCost.map { "≈ \(formatUSD($0))" } ?? "—").monospacedDigit()
                                .foregroundStyle(r.estimatedCost == nil ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .help(r.estimatedCost == nil ? "No verified list price for this model" : "API-equivalent list price")
                        }.width(76)
                    }.frame(minHeight: 160)
                    Text("Day cost per account").font(.headline)
                    NativeUsageAccountTable(accounts: UsageRangeDetail(rows: rows).accounts, identities: monitor.accounts)
                } else {
                    Text("Click a day in the calendar to see its breakdown.").foregroundStyle(.secondary)
                }
            } header: { Text("Day") } footer: {
                if selected != nil {
                    Text("Est. cost is the API-equivalent list price of these tokens (cache priced at cache rates). Subscriptions aren't billed per token. Models without a verified price show —.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Range", selection: $span) { Text("30 days").tag(30); Text("90 days").tag(90) }.pickerStyle(.segmented)
                chart.frame(height: 180)
            } header: { Text("Daily tokens") } footer: {
                let recent = usage.days.suffix(span)
                let sum = { (p: Provider) in compactTokens(recent.reduce(Int64(0)) { $0 + $1.tokens(p) }) }
                Text("Last \(span) days: Claude \(sum(.claude)) · Codex \(sum(.codex)). Providers overlap (not stacked), each measured from zero, so a much smaller one sits low on the chart.")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }.formStyle(.grouped)
    }

    private var calendar: some View {
        let cols = HeatmapGrid.columns(usage.days, weeks: 53)
        let cell: CGFloat = 10, gap: CGFloat = 3
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
        let recent = Array(usage.days.suffix(span))
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

/// T3 Proxy's own usage recorder: opt-in, because reading the hub's usage queue removes the records for any other
/// app reading it. Disabled (and explained) while Proxy Deck's database is present.
struct UsageRecordingSection: View {
    @ObservedObject private var recorder = UsageRecorderModel.shared
    private var blocked: Bool { UsageRecorder.otherRecorderPresent() }

    var body: some View {
        Section {
            Toggle("Record usage history", isOn: $recorder.enabled).disabled(blocked)
            LabeledContent("Status") {
                Label(statusText, systemImage: statusSymbol).foregroundStyle(statusColor)
            }
        } header: { Text("Recording") } footer: {
            Text(blocked
                 ? "Another app (Proxy Deck) already records this hub's usage, and T3 Proxy reads its history. T3 Proxy won't read the hub's usage queue while that app's database is present."
                 : "T3 Proxy reads the hub's usage queue every 30 seconds and keeps the history on this Mac (Application Support/T3 Proxy). Reading the queue removes the records from it, so leave this off if another app records usage from the same hub. Needs the hub's \"Usage statistics\" setting (Settings → Config).")
        }
    }

    private var statusText: String {
        if blocked { return "Another app records usage" }
        switch recorder.status {
        case .off: return "Off"
        case .blockedByOtherRecorder: return "Another app records usage"
        case .waitingForHub: return "Waiting for the hub"
        case .recording(let last, let total):
            let when = last.map { " · last \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return "Recording · \(total.formatted()) requests\(when)"
        case .statisticsDisabled: return "The hub's usage statistics are off"
        case .keyRejected: return "The management key was rejected"
        case .unsupported: return "This hub has no usage queue"
        case .failed(let m): return m
        }
    }
    private var statusSymbol: String {
        switch recorder.status {
        case .recording: "record.circle"
        case .off: "pause.circle"
        case .waitingForHub: "clock"
        default: blocked ? "person.2.circle" : "exclamationmark.triangle"
        }
    }
    private var statusColor: Color {
        switch recorder.status {
        case .recording: .green
        case .off, .waitingForHub: .secondary
        default: blocked ? .secondary : .orange
        }
    }
}
