import SwiftUI
import AppKit
import T3ProxyCore

enum SettingsDestination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", accounts = "Accounts", connectors = "Connectors", plugins = "Plugins", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .dashboard: "chart.xyaxis.line"
        case .accounts: "person.2"
        case .connectors: "app.connected.to.app.below.fill"
        case .plugins: "puzzlepiece.extension"
        case .settings: "slider.horizontal.3"
        }
    }
    var landing: SettingsPane {
        switch self {
        case .dashboard: .dashboard
        case .accounts: .accounts
        case .connectors: .connectors
        case .plugins: .plugins
        case .settings: .preferences
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case app = "T3 Proxy", t3code = "T3 Code", hub = "CLIProxyAPI", routing = "Routing", deck = "Deck Migration"
    var id: Self { self }
    var landing: SettingsPane {
        switch self {
        case .app: .preferences
        case .t3code: .t3code
        case .hub: .connection
        case .routing: .routing
        case .deck: .proxyDeck
        }
    }
}

/// Semantic routes are also used by setup links and the compact menu-bar panel.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard", preferences = "General", recording = "History"
    case gettingStarted = "Setup", connection = "Connection", accounts = "Accounts", addAccount = "Add Account"
    case quota = "Quota", routing = "Policies", routingEngine = "Engine", notifications = "Notifications"
    case t3code = "T3 Code", usage = "Usage", config = "Configuration", plugins = "Plugins"
    case connectors = "Connectors", logs = "Diagnostics", proxyDeck = "Deck Migration", system = "Updates"
    var id: Self { self }
    var destination: SettingsDestination {
        switch self {
        case .dashboard, .quota, .usage: .dashboard
        case .accounts, .addAccount: .accounts
        case .connectors: .connectors
        case .plugins: .plugins
        default: .settings
        }
    }
    var tab: SettingsTab {
        switch self {
        case .connection, .config, .logs, .system: .hub
        case .t3code: .t3code
        case .routing, .routingEngine: .routing
        case .proxyDeck: .deck
        default: .app
        }
    }
}

@MainActor final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsPane? = .dashboard
    var destination: SettingsDestination { (pane ?? .dashboard).destination }
    var tab: SettingsTab { (pane ?? .preferences).tab }
    var addingAccount: Bool {
        get { pane == .addAccount }
        set { pane = newValue ? .addAccount : .accounts }
    }
}

public struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var accounts: AccountsModel
    @ObservedObject private var router = SettingsRouter.shared

    public init(monitor: Monitor) {
        self.monitor = monitor
        _accounts = StateObject(wrappedValue: AccountsModel(monitor: monitor))
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsDestination?>(get: { router.destination }, set: { if let value = $0 { router.pane = value.landing } })) {
                ForEach(SettingsDestination.allCases) { destination in
                    Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
                        .padding(.vertical, 4)
                }
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Circle().fill(monitor.reachability == .live ? .green : .secondary).frame(width: 6, height: 6)
                    Text(monitor.endpointLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(16)
            }
        } detail: {
            switch router.destination {
            case .dashboard: DashboardPane(monitor: monitor, live: LiveQuotaModel.shared(for: monitor))
            case .accounts: AccountsPane(model: accounts, monitor: monitor)
            case .plugins: PluginsPane(monitor: monitor)
            case .connectors: ConnectorsPane()
            case .settings: PreferencesPane(monitor: monitor)
            }
        }
    }
}

struct PreferencesPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var deck = ProxyDeckMigrationModel.shared

    private var pages: [SettingsPane] {
        switch router.tab {
        case .app: [.preferences, .notifications, .recording, .gettingStarted]
        case .hub: [.connection, .config, .system, .logs]
        case .routing: [.routing, .routingEngine]
        default: []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings category", selection: Binding(get: { router.tab }, set: { router.pane = $0.landing })) {
                ForEach(SettingsTab.allCases.filter { $0 != .deck || deck.proxyDeckState != .absent || router.tab == .deck }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(20)
            if !pages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pages) { page in
                        Button { router.pane = page } label: {
                            Text(page.rawValue).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(router.pane == page ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(router.pane == page ? .primary : .secondary)
                        .accessibilityAddTraits(router.pane == page ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            Group {
                switch router.pane ?? .preferences {
                case .preferences: appPreferences
                case .notifications: NotificationsPane(monitor: monitor)
                case .recording: Form { UsageRecordingSection() }.formStyle(.grouped)
                case .gettingStarted: GettingStartedPane(monitor: monitor)
                case .connection: ConnectionPane(monitor: monitor)
                case .config: ConfigPane(monitor: monitor)
                case .system: SystemPane(monitor: monitor)
                case .logs: LogsPane(monitor: monitor)
                case .t3code: T3CodePane(monitor: monitor)
                case .routing: RoutingPane(monitor: monitor)
                case .routingEngine: ConfigPane(monitor: monitor, scope: .routing)
                case .proxyDeck: ProxyDeckPane()
                default: appPreferences
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
    }

    private var appPreferences: some View {
        Form {
            NativeConnectionSections()
            Section("Refresh") {
                Picker("Read hub every", selection: $monitor.interval) {
                    Text("30 seconds").tag(TimeInterval(30)); Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120)); Text("5 minutes").tag(TimeInterval(300))
                }
            }
            Section("About T3 Proxy") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
                Button("Quit T3 Proxy") { NSApp.terminate(nil) }
                Text("The proxy keeps running when you quit this app.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

@MainActor public func makeSettingsWindowController(monitor: Monitor) -> NSWindowController {
    let host = NSHostingController(rootView: SettingsView(monitor: monitor))
    host.sceneBridgingOptions = [.all]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.contentViewController = host
    window.title = "T3 Proxy"
    window.toolbarStyle = .unified
    window.contentMinSize = NSSize(width: 880, height: 560)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("T3ProxySettings.v3")
    window.center()
    return NSWindowController(window: window)
}
