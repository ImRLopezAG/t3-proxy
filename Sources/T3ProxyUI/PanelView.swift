import SwiftUI
import T3ProxyCore

public struct PanelContent {
    public var reachability: Reachability
    public var management: ManagementState
    public var endpoint: String
    public var accounts: [Account]
    public var updatedAt: Date?
    public var refreshing = false
    /// Pooled recorded quota per provider and window, from `pooledQuota` over the live accounts.
    public var quota: [QuotaPool] = []
    /// Daily token history (local days, oldest first) from `UsageModel`; empty with `usageNote` when unavailable.
    public var days: [UsageDay] = []
    public var usageNote: String?
    /// Recent token buckets for the Overview hero; nil falls back to the hub's request counts.
    public var recent: RecentUsage?
    /// Set when token recording has fallen behind the hub; the hero then shows requests and says why.
    public var tokensStaleSince: Date?
    public var isSample = false
    public init(reachability: Reachability, management: ManagementState, endpoint: String, accounts: [Account], updatedAt: Date?) {
        self.reachability = reachability; self.management = management; self.endpoint = endpoint
        self.accounts = accounts; self.updatedAt = updatedAt
    }
    var hasAccounts: Bool { updatedAt != nil }
    var active: Int { accounts.filter { !$0.held }.count }
    var held: Int { accounts.filter(\.held).count }
}

public enum PanelTab: String, CaseIterable { case overview = "Overview", active = "Accounts", threads = "Threads" }
public let panelWidth: CGFloat = 360

public struct PanelActions {
    var refresh: () -> Void, setKey: (String) -> Void, removeKey: () -> Void, quit: () -> Void
    var openSettings: () -> Void
    var interval: Binding<TimeInterval>
    var tokenRange: Binding<TokenRange>
    public init(refresh: @escaping () -> Void, setKey: @escaping (String) -> Void, removeKey: @escaping () -> Void, quit: @escaping () -> Void,
                interval: Binding<TimeInterval>, openSettings: @escaping () -> Void = {}, tokenRange: Binding<TokenRange> = .constant(.today)) {
        self.refresh = refresh; self.setKey = setKey; self.removeKey = removeKey; self.quit = quit; self.interval = interval
        self.openSettings = openSettings; self.tokenRange = tokenRange
    }
}

public struct PanelView: View {
    let content: PanelContent
    let actions: PanelActions
    @State var tab: PanelTab
    @Environment(\.colorScheme) private var scheme
    public init(content: PanelContent, actions: PanelActions, tab: PanelTab = .overview) {
        self.content = content; self.actions = actions; _tab = State(initialValue: tab)
    }
    public var body: some View {
        let t = Theme(scheme)
        VStack(alignment: .leading, spacing: 10) {
            header(t)
            if content.isSample {
                // ImageRenderer cannot draw AppKit's segmented picker. Use a still with the same labels.
                HStack(spacing: 0) {
                    ForEach(PanelTab.allCases, id: \.self) { item in
                        Text(item.rawValue).font(.system(size: 10.5, weight: item == tab ? .semibold : .regular))
                            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(item == tab ? (scheme == .dark ? Color(hex: 0x555555) : Color.white) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }.padding(2).background(scheme == .dark ? Color(hex: 0x303030) : Color(hex: 0xDCDCDC), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Picker("View", selection: $tab) {
                    ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            if content.isSample {
                Text("SAMPLE DATA · NOT LIVE").font(.caption2.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 3).background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
            // Tabs sit straight on the panel's glass, on the same edges as the header and the tab picker.
            Group {
                switch tab {
                case .overview: OverviewTab(c: content, range: actions.tokenRange, openSettings: actions.openSettings)
                case .active: ActiveTab(c: content)
                case .threads: ThreadsTab(c: content, openSettings: actions.openSettings)
                }
            }
            Rule()
            footer(t)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(width: panelWidth)
        .foregroundStyle(.primary)
    }

    private func header(_ t: Theme) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("T3 Proxy").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(dotColor(t)).frame(width: 8, height: 8)
                    Text(statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.body.weight(.medium)).frame(width: 18, height: 18)
            }.buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Settings").accessibilityLabel("Settings")
        }
    }
    private var statusLine: String {
        switch content.reachability {
        case .live: return "Live · \(content.endpoint)"
        case .offline: return "Offline · \(content.endpoint)"
        case .unknown: return "Checking · \(content.endpoint)"
        }
    }
    private func dotColor(_ t: Theme) -> Color {
        content.reachability == .live ? t.live : content.reachability == .offline ? .red : .gray
    }
    @ViewBuilder private func footer(_ t: Theme) -> some View {
        if tab == .threads { ThreadsFooter() } else { proxyFooter(t) }
    }
    private func proxyFooter(_ t: Theme) -> some View {
        HStack(spacing: 8) {
            Label(content.hasAccounts ? "\(content.active) active · \(content.held) held" : "Accounts not connected", systemImage: "person.2")
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Circle().fill(content.hasAccounts ? t.live : .gray).frame(width: 7, height: 7)
                updated
            }
            Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(content.refreshing)
                .help("Refresh").accessibilityLabel("Refresh")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var updated: some View {
        if let d = content.updatedAt, !content.isSample {
            Text("Updated \(d, style: .relative) ago").lineLimit(1)
        } else if content.isSample { Text("Updated just now") } else { Text("No account data") }
    }
}

/// Same layout as the accounts footer: counts on the left, the last-update time and refresh on the right.
struct ThreadsFooter: View {
    @ObservedObject private var model = T3CodeModel.shared()
    @Environment(\.colorScheme) private var s
    var body: some View {
        let t = Theme(s)
        HStack(spacing: 8) {
            Label(model.notice ?? threadsFooter(model), systemImage: "bubble.left.and.bubble.right").lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Circle().fill(model.status.isConnected ? t.live : .gray).frame(width: 7, height: 7)
                if let d = model.updatedAt, model.status.isConnected { Text("Updated \(d, style: .relative) ago").lineLimit(1) }
                else { Text("No thread data").lineLimit(1) }
            }
            Button { model.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.busy || !model.hasSession)
                .help("Reconnect").accessibilityLabel("Reconnect")
        }
        .font(.caption).foregroundStyle(.secondary)
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            model.notice = nil
        }
    }
}

struct Rule: View { @Environment(\.colorScheme) var s
    var body: some View { Rectangle().fill(Theme(s).divider).frame(height: 1) } }
struct VRule: View { @Environment(\.colorScheme) var s
    var body: some View { Rectangle().fill(Theme(s).divider).frame(width: 1) } }
struct SectionTitle: View { let text: String
    var body: some View { Text(text).font(.headline) } }
struct Pill: View { let text: String; @Environment(\.colorScheme) var s
    var body: some View { Text(text).font(.caption.bold()).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 2)
        .background(.quaternary, in: Capsule()) } }

/// Empty/explanatory state shown where the proxy has no verified data.
struct Note: View { let text: String; @Environment(\.colorScheme) var s
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true) } }
