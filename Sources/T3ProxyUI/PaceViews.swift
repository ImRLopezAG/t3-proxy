import SwiftUI
import T3ProxyCore

/// Remaining %, pace and colour for one window of a reading, computed once per draw.
struct WindowState {
    let window: AccountWindow
    let remaining: Double?
    let pace: QuotaPace?
    let now: Date
    init(_ w: AccountWindow, _ quota: QuotaReading, now: Date) {
        window = w; self.now = now
        remaining = quota.remaining(w, at: now)
        pace = remaining == nil ? nil : QuotaPace.of(w, observedAt: quota.observedAt, now: now)
    }
    var expired: Bool { remaining == nil && (window.window.resetAt.map { $0 <= now } ?? false) }
    /// A deficit that empties the window before its reset.
    var urgent: Bool { if case .deficit = pace?.stage { pace?.runsOutAt != nil } else { false } }
    func fill(_ tint: Color) -> Color { guard let r = remaining else { return tint }; return r <= 0 ? .red : r < 10 ? .orange : tint }
}

/// Compact row line: "Weekly  [bar with pace marker]  68%".
struct AccountWindowLine: View {
    let state: WindowState
    let tint: Color
    @Environment(\.colorScheme) private var s

    var body: some View {
        let t = Theme(s)
        HStack(spacing: 8) {
            Text(state.window.title).font(.system(size: 10)).foregroundStyle(t.secondary)
                .lineLimit(1).truncationMode(.tail).frame(width: 78, alignment: .leading)
            if let r = state.remaining {
                PaceBar(remaining: r, pace: state.pace, tint: state.fill(tint)).frame(height: 5)
                Text("\(Int(r.rounded()))%").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(r <= 0 ? .red : r < 10 ? .orange : .primary).frame(width: 34, alignment: .trailing)
            } else {
                Text(state.expired ? "Expired" : "No reading").font(.system(size: 10)).foregroundStyle(t.secondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.window.title): \(state.remaining.map { "\(Int($0.rounded()))% left" } ?? (state.expired ? "expired" : "no reading"))"
                            + (state.pace.map { ", \($0.summary)" } ?? ""))
    }
}

/// Full detail for the hover card: "% left" and reset, a bar with the even-pace marker, then the pace.
struct AccountWindowPace: View {
    let state: WindowState
    let tint: Color
    var now = Date()
    @Environment(\.colorScheme) private var s

    var body: some View {
        let t = Theme(s)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(state.window.title).font(.system(size: 12, weight: .semibold))
                if let r = state.remaining {
                    Text("\(Int(r.rounded()))% left").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(r <= 0 ? .red : r < 10 ? .orange : .primary)
                } else {
                    Text(state.expired ? "Expired" : "No reading").font(.system(size: 12)).foregroundStyle(t.secondary)
                }
                Spacer(minLength: 4)
                if state.remaining != nil, let reset = state.window.window.resetAt {
                    Text(resetText(reset)).font(.system(size: 10)).foregroundStyle(t.secondary).lineLimit(1)
                }
            }
            if let r = state.remaining { PaceBar(remaining: r, pace: state.pace, tint: state.fill(tint)).frame(height: 6) }
            if let p = state.pace {
                Text(p.summary + (p.projection(now: now).map { " · \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(state.urgent ? Color.orange : Color.secondary).lineLimit(1)
            }
        }
    }

    /// Within a day: "Resets in 3h 10m"; later: "Resets Fri 5:01 PM".
    private func resetText(_ reset: Date) -> String {
        reset.timeIntervalSince(now) < 86400
            ? "Resets in \(shortDuration(until: reset, from: now))"
            : "Resets \(reset.formatted(.dateTime.day().month(.abbreviated))) at \(reset.formatted(date: .omitted, time: .shortened))"
    }
}

/// "% left" fill with the even-pace marker (red when in deficit) and, for weekly windows, a tick per local midnight.
/// Drawn in one Canvas, so no compositing modifiers are needed for the punched-out marker.
struct PaceBar: View {
    let remaining: Double?
    let pace: QuotaPace?
    let tint: Color
    @Environment(\.colorScheme) private var s

    var body: some View {
        let t = Theme(s)
        Canvas { ctx, size in
            let h = size.height, r = h / 2
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: full, cornerRadius: r), with: .color(t.track))
            if let remaining, remaining > 0 {
                let w = max(h, size.width * min(100, remaining) / 100)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: r), with: .color(tint))
            }
            guard let pace else { return }
            // On a "% left" bar, a point in time sits at 100 - (share of the window elapsed).
            for mark in pace.dayMarks {
                let x = size.width * (100 - mark) / 100
                ctx.fill(Path(CGRect(x: x - 0.5, y: 1, width: 1, height: max(0, h - 2))), with: .color(.primary.opacity(0.28)))
            }
            let x = min(size.width - 1, max(1, size.width * pace.expectedRemaining / 100))
            var punch = ctx
            punch.blendMode = .destinationOut
            punch.fill(Path(CGRect(x: x - 2.5, y: 0, width: 5, height: h)), with: .color(.white))
            let color: Color = switch pace.stage {
            case .deficit: .red
            case .reserve, .onPace: .primary.opacity(0.85)
            }
            ctx.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: h), cornerRadius: 1), with: .color(color))
        }
        .accessibilityHidden(true)
    }
}
