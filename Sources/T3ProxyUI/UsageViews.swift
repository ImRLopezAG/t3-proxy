import SwiftUI
import T3ProxyCore

/// Neutral green contribution scale, independent of the provider tints.
func heatColor(_ level: Int, _ t: Theme) -> Color {
    if level == 0 { return t.track }
    let base = Color(hex: t.dark ? 0x39D353 : 0x2DA44E)
    return base.opacity([0.3, 0.5, 0.75, 1][min(level, 4) - 1])
}

func usageDayLabel(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()) }

/// Plain-text summary for VoiceOver.
func usageTooltip(_ d: UsageDay) -> String {
    let c = d.byProvider[.claude]?.total ?? 0, x = d.byProvider[.codex]?.total ?? 0, o = d.byProvider[.other]?.total ?? 0
    var s = "\(usageDayLabel(d.date)), \(compactTokens(d.totals.total)) tokens, \(d.totals.requests) requests, Claude \(compactTokens(c)), Codex \(compactTokens(x))"
    if o > 0 { s += ", Other \(compactTokens(o))" }
    return s
}

/// Hover card for one calendar day: totals at once, provider and model split (with estimated cost) loaded lazily.
struct DayHoverCard: View {
    let day: UsageDay
    @ObservedObject private var usage = UsageModel.shared

    var body: some View {
        let detail = usage.details[day.date]
        let t = day.totals
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(usageDayLabel(day.date)).font(.headline)
                Text("\(compactTokens(t.total)) tokens · \(t.requests) requests" + (t.failed > 0 ? " · \(t.failed) failed" : ""))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if let detail, t.requests > 0 {
                    Text("Est. cost \(detail.cost.label)").font(.callout).monospacedDigit()
                }
            }
            if t.requests == 0 {
                Text("No requests").font(.callout).foregroundStyle(.secondary)
            } else if let detail {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach([Provider.claude, .codex, .other], id: \.self) { p in
                        if let v = detail.byProvider[p] {
                            GridRow {
                                ProviderMark(provider: p, size: 13)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.title).font(.callout.weight(.medium))
                                    Text("in \(compactTokens(v.input)) · out \(compactTokens(v.output)) · cache \(compactTokens(v.cached + v.cacheCreation))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(compactTokens(v.total)).gridColumnAlignment(.trailing)
                                Text(detail.costByProvider[p]?.short ?? "—").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            }.font(.callout).monospacedDigit()
                        }
                    }
                }
                let top = detail.models.prefix(4)
                if !top.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                        ForEach(Array(top)) { m in
                            GridRow {
                                Text(m.model.isEmpty ? "Unknown model" : m.model).lineLimit(1).truncationMode(.middle)
                                Text(compactTokens(m.totals.total)).gridColumnAlignment(.trailing)
                                Text(m.cost.map { "≈ \(formatUSD($0))" } ?? "—").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            }
                        }
                    }.font(.caption).monospacedDigit()
                    if detail.models.count > 4 {
                        Text("+ \(detail.models.count - 4) more").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text("Estimated at API list prices; subscriptions aren't billed per token.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .task(id: day.date) { if day.totals.requests > 0 { await usage.detail(for: day.date) } }
    }
}

/// Weeks as columns (calendar's first weekday on top), ending with the week that holds the last day.
struct HeatmapGrid: View {
    let days: [UsageDay]
    let weeks: Int
    var cell: CGFloat = 10
    var gap: CGFloat = 2
    var provider: Provider? = nil
    var selected: Date? = nil
    var onSelect: ((UsageDay) -> Void)? = nil
    @Environment(\.colorScheme) private var s
    /// The day whose hover card is open, set after a short dwell so sweeping across the grid doesn't flash cards.
    @State private var hovered: Date?
    @State private var dwell: Task<Void, Never>?

    /// Columns of 7 optional days; nil cells are before the data or in the future.
    static func columns(_ days: [UsageDay], weeks: Int, calendar: Calendar = .current) -> [[UsageDay?]] {
        guard let last = days.last?.date else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let wd = (calendar.component(.weekday, from: last) - calendar.firstWeekday + 7) % 7
        guard let lastWeekStart = calendar.date(byAdding: .day, value: -wd, to: last),
              let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: lastWeekStart) else { return [] }
        return (0..<weeks).map { w in
            (0..<7).map { d in
                calendar.date(byAdding: .day, value: w * 7 + d, to: first).flatMap { byDate[calendar.startOfDay(for: $0)] }
            }
        }
    }

    private func hover(_ date: Date, _ inside: Bool) {
        dwell?.cancel()
        if inside {
            // Already showing a card: move it straight away; otherwise wait briefly.
            let delay: Duration = hovered == nil ? .milliseconds(350) : .milliseconds(60)
            dwell = Task { try? await Task.sleep(for: delay); if !Task.isCancelled { hovered = date } }
        } else if hovered == date {
            dwell = Task { try? await Task.sleep(for: .milliseconds(150)); if !Task.isCancelled, hovered == date { hovered = nil } }
        }
    }

    private func cardBinding(_ date: Date) -> Binding<Bool> {
        Binding(get: { hovered == date }, set: { if !$0, hovered == date { hovered = nil } })
    }

    var body: some View {
        let t = Theme(s)
        let cols = Self.columns(days, weeks: weeks)
        let maxV = days.map { $0.tokens(provider) }.max() ?? 0
        HStack(alignment: .top, spacing: gap) {
            ForEach(cols.indices, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        if let day = cols[w][d] {
                            RoundedRectangle(cornerRadius: cell * 0.25)
                                .fill(heatColor(usageLevel(day.tokens(provider), max: maxV), t))
                                .overlay { if day.date == selected { RoundedRectangle(cornerRadius: cell * 0.25).stroke(Color.primary, lineWidth: 1.2) } }
                                .frame(width: cell, height: cell)
                                .contentShape(Rectangle())
                                .onHover { inside in hover(day.date, inside) }
                                .popover(isPresented: cardBinding(day.date), arrowEdge: .bottom) { DayHoverCard(day: day) }
                                .onTapGesture { onSelect?(day) }
                                .accessibilityLabel(usageTooltip(day))
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}

struct HeatLegend: View {
    @Environment(\.colorScheme) private var s
    var cell: CGFloat = 8
    var body: some View {
        let t = Theme(s)
        HStack(spacing: 2) {
            Text("Less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(heatColor($0, t)).frame(width: cell, height: cell) }
            Text("More").padding(.leading, 2)
        }.font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

/// Overview's "Daily history" section: compact 26-week calendar plus a one-line summary.
struct DailyHistorySection: View {
    let c: PanelContent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "Daily history")
                Spacer()
                if !c.days.isEmpty { HeatLegend() }
            }
            if c.days.isEmpty {
                Note(text: c.usageNote ?? "Token history isn't available yet. Nothing is estimated here.")
            } else {
                HeatmapGrid(days: c.days, weeks: 26, cell: 9.5, gap: 2).frame(maxWidth: .infinity, alignment: .center)
                Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
        }
    }
    private var summary: String {
        let year = c.days.reduce(Int64(0)) { $0 + $1.totals.total }
        let week = c.days.suffix(7).reduce(Int64(0)) { $0 + $1.totals.total }
        let today = c.days.last?.totals.total ?? 0
        return "\(compactTokens(year)) tokens this year · last 7 days \(compactTokens(week)) · today \(compactTokens(today))"
    }
}
