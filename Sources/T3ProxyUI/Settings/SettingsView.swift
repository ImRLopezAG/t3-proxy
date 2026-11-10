import SwiftUI
import AppKit
import T3ProxyCore

/// Sidebar sections. Each pane lives in its own file (`<Name>Pane.swift`) and takes the Monitor.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case gettingStarted = "Getting Started"
    case connection = "Connection"
    case accounts = "Accounts"
    case addAccount = "Add Account"
    case quota = "Quota"
    case routing = "Routing"
    case notifications = "Notifications"
    case t3code = "T3 Code"
    case usage = "Usage"
    case config = "Config"
    case logs = "Logs"
    case system = "About Proxy"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .gettingStarted: "list.bullet.clipboard"
        case .connection: "network"
        case .accounts: "person.2"
        case .addAccount: "person.badge.plus"
        case .quota: "gauge.with.dots.needle.50percent"
        case .routing: "arrow.triangle.branch"
        case .notifications: "bell.badge"
        case .t3code: "terminal"
        case .usage: "chart.bar.xaxis"
        case .config: "slider.horizontal.3"
        case .logs: "doc.text.magnifyingglass"
        case .system: "info.circle"
        }
    }
}

/// Lets other surfaces (the menu-bar panel) choose the pane Settings opens to.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsPane? = .connection
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
            List(SettingsPane.allCases, selection: $router.pane) { p in
                Label(p.rawValue, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch router.pane ?? .connection {
            case .gettingStarted: GettingStartedPane(monitor: monitor)
            case .connection: ConnectionPane(monitor: monitor)
            case .accounts: AccountsPane(model: accounts, monitor: monitor)
            case .addAccount: AddAccountPane(monitor: monitor)
            case .quota: QuotaPane(monitor: monitor, live: LiveQuotaModel.shared(for: monitor))
            case .routing: RoutingPane(monitor: monitor)
            case .notifications: NotificationsPane(monitor: monitor)
            case .t3code: T3CodePane(monitor: monitor)
            case .usage: UsagePane(monitor: monitor)
            case .config: ConfigPane(monitor: monitor)
            case .logs: LogsPane(monitor: monitor)
            case .system: SystemPane(monitor: monitor)
            }
        }
    }
}

/// A regular titled, resizable window hosting `SettingsView`. Keep one instance and call `showWindow(_:)`.
@MainActor
public func makeSettingsWindowController(monitor: Monitor) -> NSWindowController {
    let host = NSHostingController(rootView: SettingsView(monitor: monitor))
    host.sceneBridgingOptions = [.all]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.contentViewController = host
    window.title = "T3 Proxy Settings"
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 980, height: 600))
    window.contentMinSize = NSSize(width: 880, height: 460)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("T3ProxySettings.v2")   // new name: older saved frames were too narrow for the tables
    window.center()
    return NSWindowController(window: window)
}
