import AppKit
import Combine
import SwiftUI
import T3ProxyCore
import T3ProxyUI

/// The menu bar panel. A plain panel instead of NSPopover: NSPopover placed itself above the top
/// of a secondary display, clipping the header. This one is positioned explicitly under the icon.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // the management-key field needs typing
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc
}

/// Replies to a deferred quit exactly once, from whichever path gets there first.
@MainActor final class QuitGate {
    private var sender: NSApplication?
    init(_ sender: NSApplication) { self.sender = sender }
    func reply() { sender?.reply(toApplicationShouldTerminate: true); sender = nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel: MenuPanel = makePanel()
    private var settings: NSWindowController?
    private var clickMonitor: Any?
    private var nativeSubscriptions: Set<AnyCancellable> = []
    private var titleTimer: Timer?
    /// Where the panel's top edge sits; kept when the content height changes between tabs.
    private var anchorTop: CGFloat = 0

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Usage records popped from the hub's queue exist nowhere else: let an in-flight batch be saved (or spooled)
        // before quitting. A 3 s deadline races the save, so a stuck write can never hold the quit open.
        guard UsageRecorderModel.shared.enabled else { return .terminateNow }
        let gate = QuitGate(sender)
        Task { @MainActor in await UsageRecorderModel.shared.prepareForQuit(); gate.reply() }
        Task { @MainActor in try? await Task.sleep(for: .seconds(3)); gate.reply() }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // One menu bar item only, and only one running copy.
        let same = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if same.count > 1 { NSApp.terminate(nil); return }
        item.button?.image = statusIconImage()
        item.button?.toolTip = "T3 Proxy"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        monitor.$accounts.sink { [weak self] accounts in self?.updateMenuTitle(accounts) }.store(in: &nativeSubscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.updateMenuTitle(self.monitor.accounts) }
        }.store(in: &nativeSubscriptions)
        titleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.updateMenuTitle(self.monitor.accounts) }
        }
        NativePanelShortcut.shared.start { [weak self] in self?.toggle() }
        monitor.start()
        LiveQuotaModel.shared(for: monitor).start()
        Notifier.shared(for: monitor, live: LiveQuotaModel.shared(for: monitor)).start()
        RoutingGuard.shared(for: monitor).start()
        UsageModel.shared.start()
        // Opt-in and off by default; never runs while another recorder (Proxy Deck) owns the hub's usage queue.
        UsageRecorderModel.shared.start(monitor: monitor)
        let t3 = T3CodeModel.shared()
        t3.start()
        t3.$snapshot.combineLatest(t3.$status).map { $1.isConnected && T3ThreadBoard.needsAttention($0) }.removeDuplicates()
            .sink { [weak self] on in self?.item.button?.image = statusIconImage(attention: on) }
            .store(in: &nativeSubscriptions)
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.toggle() }
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }
    private func updateMenuTitle(_ accounts: [Account]) {
        let mode = NativeMenuBarMode(rawValue: UserDefaults.standard.string(forKey: "nativeMenuBarMode") ?? "") ?? .icon
        let pools = [Provider.claude, .codex].flatMap { p in QuotaWindowKind.allCases.map { pooledQuota(accounts, p, $0) } }
        let title = mode.title(pools: pools)
        item.button?.title = title.isEmpty ? "" : " " + title
        // Reserve the widest title for this mode, independent of current digits or missing values.
        let widest: String
        switch mode {
        case .icon: widest = ""
        case .lowest: widest = " 100%"
        case .providers: widest = " Claude 100% · Codex 100%"
        }
        let font = item.button?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (widest as NSString).size(withAttributes: [.font: font]).width
        item.length = ceil(18 + (widest.isEmpty ? 0 : 4 + textWidth) + 12)
    }
    /// Finder/Spotlight reopen must work even when the menu bar hides the icon.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        if !panel.isVisible { toggle() }
        return false
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.delegate = self
        let root = Root(monitor: monitor, openSettings: { [weak self] in self?.showSettings() })
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in self?.fit(size) }
        let host = NSHostingView(rootView: root)
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = host
        // The glass leaves a faint (~4% alpha) fill in its square corners, so the window shadow was
        // traced as a square: a dark square frame around the rounded panel. Clip to the rounded shape
        // so the corners are fully transparent and the shadow follows the glass.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        clip.addSubview(glass)
        p.contentView = clip
        glass.frame = clip.bounds
        return p
    }

    static let cornerRadius: CGFloat = 18

    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var f = panel.frame
        f.size = size
        f.origin.y = anchorTop - size.height
        panel.setFrame(f, display: true)
        refreshShadow()
    }

    /// Under the icon on whichever display shows it; when the icon is hidden (crowded or notched
    /// menu bar), at the top right of the display under the pointer.
    private func placement(width: CGFloat) -> (top: CGFloat, x: CGFloat) {
        if let b = item.button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            // Trust the icon's frame only when it sits in a display's menu-bar band (it reads (0,0)
            // before the menu bar has placed it).
            if let s = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) }),
               r.minY >= s.frame.maxY - 60, !underNotch(r, s) {
                return (min(r.minY, s.frame.maxY) - 6, clampX(r.midX - width / 2, width, s))
            }
        }
        let mouse = NSEvent.mouseLocation
        let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let bar = max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
        return (s.frame.maxY - bar - 6, clampX(s.frame.maxX - width - 12, width, s))
    }
    private func underNotch(_ r: NSRect, _ s: NSScreen) -> Bool {
        guard let l = s.auxiliaryTopLeftArea, let rr = s.auxiliaryTopRightArea else { return false }
        return r.midX > l.maxX && r.midX < rr.minX
    }
    private func clampX(_ x: CGFloat, _ width: CGFloat, _ s: NSScreen) -> CGFloat {
        min(max(x, s.frame.minX + 8), s.frame.maxX - width - 8)
    }

    /// A click on the icon first makes the panel resign key (closing it); don't reopen on that same click.
    private var closedAt = Date.distantPast

    /// Left click opens the panel; right-click (or Control-click) shows the standard menu with Quit.
    @objc func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            closePanel()
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit T3 Proxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            if let b = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b) }
        } else {
            toggle()
        }
    }
    @objc private func openSettingsFromMenu() { showSettings() }

    @objc func toggle() {
        if panel.isVisible { closePanel(); return }
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        Task { await monitor.refresh() }
        UsageModel.shared.refresh()
        let size = panel.contentView?.subviews.first?.fittingSize ?? panel.frame.size   // the glass inside the clip view
        let at = placement(width: size.width)
        anchorTop = at.top
        panel.setFrame(NSRect(x: at.x, y: at.top - size.height, width: size.width, height: size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        refreshShadow()
        // Clicks in other apps close it, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }
    /// A transparent window's shadow is traced from its pixels once and cached. Traced before the
    /// glass has drawn (or at an old size) it comes out square, a dark square frame around the
    /// rounded panel. Re-trace after each show/resize, once the new frame has been drawn.
    private func refreshShadow() {
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            guard let p = self?.panel, p.isVisible else { return }
            p.display(); p.invalidateShadow()
        }
    }

    private func closePanel() {
        if panel.isVisible { closedAt = Date() }
        HoverCards.hide()
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
    func windowDidResignKey(_ n: Notification) {
        if (n.object as? NSWindow) === panel { closePanel() }
    }

    /// Settings is a normal window, but the app stays menu-bar only (no Dock icon).
    func showSettings() {
        closePanel()
        if settings == nil { settings = makeSettingsWindowController(monitor: monitor) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}

struct Root: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var usage = UsageModel.shared
    let openSettings: () -> Void
    var body: some View {
        var content = PanelContent(reachability: monitor.reachability, management: monitor.management,
                                   endpoint: monitor.endpointLabel, accounts: monitor.accounts, updatedAt: monitor.accountsUpdatedAt)
        content.refreshing = monitor.refreshing
        content.days = usage.days
        // Token totals only when the recorder is keeping up; otherwise fall back to the hub's request counts.
        let hubRecent = Provider.allCases.map { summarize(monitor.accounts, $0).requests.suffix(2).reduce(0, +) }.reduce(0, +)
        if let r = usage.recent, r.isStale(hubRecentRequests: hubRecent) {
            content.tokensStaleSince = r.latestRecord ?? .distantPast
        } else {
            content.recent = usage.recent
        }
        switch usage.state {
        case .missing: content.usageNote = "No token history: the usage database wasn't found. Nothing is estimated."
        case .failed: content.usageNote = "Couldn't read the usage database. Nothing is estimated."
        case .loading: content.usageNote = "Loading token history…"
        case .loaded: if usage.days.allSatisfy({ $0.totals.requests == 0 }) { content.days = []; content.usageNote = "No requests recorded in the last year." }
        }
        content.quota = [Provider.claude, .codex].flatMap { p in QuotaWindowKind.allCases.map { pooledQuota(monitor.accounts, p, $0) } }
        return PanelView(content: content, actions: PanelActions(
            refresh: { Task { await monitor.refresh() }; usage.refresh() },
            setKey: { k in Task { _ = await monitor.setKey(k) } },
            removeKey: { monitor.removeKey() },
            quit: { NSApp.terminate(nil) },
            interval: Binding(get: { monitor.interval }, set: { monitor.interval = $0 }),
            openSettings: openSettings,
            tokenRange: Binding(get: { usage.range }, set: { usage.range = $0 })))
            .onChange(of: monitor.refreshing) { _, busy in if !busy { usage.refreshRecent() } }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
    // Design comparison only. Rendered images carry the SAMPLE banner.
    MainActor.assumeIsolated {
        let dir = URL(fileURLWithPath: args[i + 1])
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tab in PanelTab.allCases { for dark in [true, false] {
            let name = "\(tab == .active ? "accounts" : tab.rawValue.lowercased())-\(dark ? "dark" : "light").png"
            try! SamplePreview.render(SamplePreview.content(), tab: tab, dark: dark, to: dir.appendingPathComponent(name))
        } }
        // Honest state for what a user without a key sees.
        try! SamplePreview.renderCards(to: dir)
        try! SamplePreview.renderThreads(to: dir)
        let empty = PanelContent(reachability: .live, management: .noKey, endpoint: ProxyEndpoint.configured().label, accounts: [], updatedAt: nil)
        try! SamplePreview.render(empty, tab: .overview, dark: true, to: dir.appendingPathComponent("nokey-dark.png"))
        try! SamplePreview.render(empty, tab: .overview, dark: false, to: dir.appendingPathComponent("nokey-light.png"))
        let down = PanelContent(reachability: .offline, management: .noKey, endpoint: ProxyEndpoint.configured().label, accounts: [], updatedAt: nil)
        try! SamplePreview.render(down, tab: .overview, dark: true, to: dir.appendingPathComponent("offline-dark.png"))
        try! SamplePreview.renderGettingStarted(to: dir)
    }
    exit(0)
}
if args.contains("--probe") {
    // Unauthenticated health only; no key is read or sent.
    let sem = DispatchSemaphore(value: 0)
    Task.detached { print(await ProxyClient().health() ? "proxy: live" : "proxy: offline"); sem.signal() }
    sem.wait(); exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
