import AppKit
import SwiftUI

/// Details shown beside the menu-bar panel while the pointer rests on a row (accounts, threads).
///
/// The panel is a non-activating NSPanel, where SwiftUI popovers and `.help` cards are unreliable. The card is
/// its own borderless glass panel attached as a child window, positioned next to the main panel at the row's height
/// (left of the panel, or right when there's no room). AppKit tracking areas with `.activeAlways` drive it, so it
/// works whether or not the panel is key. Cards are passive by default; quota details opt into buttons.
@MainActor
final class HoverCardController {
    static let shared = HoverCardController()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    /// The row whose card is showing, and the row waiting for its delay.
    private weak var anchor: NSView?
    private weak var pending: NSView?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var interactive = false
    private let gap: CGFloat = 8

    func enter(_ view: NSView, interactive: Bool = false, content: @escaping () -> AnyView) {
        hideTask?.cancel(); hideTask = nil
        // Moving between rows while a card is up swaps it at once; the first card waits briefly.
        let delay: Duration = panel?.isVisible == true ? .milliseconds(60) : .milliseconds(450)
        showTask?.cancel()
        pending = view
        showTask = Task { [weak self, weak view] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let view, self.pending === view, Self.pointerInside(view) else { return }
            self.pending = nil
            self.show(content(), for: view, interactive: interactive)
        }
    }

    func exit(_ view: NSView) {
        // Leaving a row that is still waiting cancels its card, whichever card is showing.
        if pending === view { showTask?.cancel(); showTask = nil; pending = nil }
        guard anchor === view || anchor == nil else { return }
        scheduleHide()
    }

    /// Keyboard / VoiceOver: show this row's card now, or close it if it is the one showing.
    func toggle(_ view: NSView, interactive: Bool = false, content: () -> AnyView) {
        if anchor === view, panel?.isVisible == true { hide(); return }
        showTask?.cancel(); hideTask?.cancel(); pending = nil
        show(content(), for: view, interactive: interactive)
    }

    func cardEntered() { hideTask?.cancel(); hideTask = nil }
    func cardExited() { scheduleHide() }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            if self.interactive, let panel = self.panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) { return }
            if let anchor = self.anchor, Self.pointerInside(anchor) { return }
            self.hide()
        }
    }

    private static func pointerInside(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible else { return false }
        let rect = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    func hide() {
        showTask?.cancel(); showTask = nil
        anchor = nil; pending = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Called when an anchor leaves its window (tab switch, row removed).
    func detach(_ view: NSView) {
        if pending === view { showTask?.cancel(); showTask = nil; pending = nil }
        if anchor === view { hide() }
    }

    private func makePanel() -> (NSPanel, NSHostingView<AnyView>) {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = InteractiveHoverHost(rootView: AnyView(EmptyView()))
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = host
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 14
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        clip.addSubview(glass)
        p.contentView = clip
        return (p, host)
    }

    private func show(_ content: AnyView, for view: NSView, interactive: Bool) {
        guard let window = view.window, window.isVisible else { return }
        if panel == nil { (panel, host) = makePanel() }
        guard let panel, let host else { return }
        self.interactive = interactive
        panel.ignoresMouseEvents = !interactive
        anchor = view
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        host.rootView = AnyView(HoverCardViewport(content: content, maximumHeight: screen.height - 8) { [weak self, weak view] height in
            guard let self, let view, self.anchor === view else { return }
            self.positionPanel(size: NSSize(width: 328, height: height), for: view)
        }.id(ObjectIdentifier(view)))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        positionPanel(size: size, for: view)
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    private func positionPanel(size: NSSize, for view: NSView) {
        guard let panel, let window = view.window, window.isVisible else { return }
        let row = window.convertToScreen(view.convert(view.bounds, to: nil))
        let main = window.frame
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? main
        var x = main.minX - gap - size.width
        if x < screen.minX + 4 { x = main.maxX + gap }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        // Top of the card level with the top of the row, kept on screen.
        var y = row.maxY - size.height
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

private struct HoverCardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HoverCardViewport: View {
    let content: AnyView
    let maximumHeight: CGFloat
    let resized: (CGFloat) -> Void
    @State private var height: CGFloat = 300

    var body: some View {
        ScrollView {
            content.frame(width: 300, alignment: .leading).padding(14)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: HoverCardHeight.self, value: geometry.size.height)
                })
                .overlayScroller()
        }
        .frame(width: 328, height: min(height, maximumHeight))
        .onPreferenceChange(HoverCardHeight.self) { value in
            guard value > 0, abs(height - value) > 0.5 else { return }
            height = value
            resized(min(value, maximumHeight))
        }
    }
}

private final class InteractiveHoverHost: NSHostingView<AnyView> {
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
    }
    override func mouseEntered(with event: NSEvent) { HoverCardController.shared.cardEntered() }
    override func mouseExited(with event: NSEvent) { HoverCardController.shared.cardExited() }
}

/// Tracks the pointer over its frame and asks the controller for a card.
private final class HoverAnchorView: NSView {
    var content: () -> AnyView = { AnyView(EmptyView()) }
    var interactive = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { HoverCardController.shared.enter(self, interactive: interactive, content: content) }
    override func mouseExited(with event: NSEvent) { HoverCardController.shared.exit(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { HoverCardController.shared.detach(self) }
    }
    // Purely a sensor: clicks, scrolls and menus go to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Lets the SwiftUI side reach its anchor view (for the accessibility action).
@MainActor private final class HoverAnchorBox { weak var view: HoverAnchorView? }

private struct HoverAnchor: NSViewRepresentable {
    let box: HoverAnchorBox
    let content: () -> AnyView
    let interactive: Bool
    func makeNSView(context: Context) -> HoverAnchorView { let v = HoverAnchorView(); v.content = content; v.interactive = interactive; box.view = v; return v }
    func updateNSView(_ v: HoverAnchorView, context: Context) { v.content = content; v.interactive = interactive; box.view = v }
}

private struct HoverCardModifier<Card: View>: ViewModifier {
    let card: () -> Card
    var interactive = false
    var clickToOpen = false
    @State private var box = HoverAnchorBox()
    func body(content: Content) -> some View {
        let anchored = content
            .background(HoverAnchor(box: box, content: { AnyView(card()) }, interactive: interactive))
            // Keyboard and VoiceOver users get the same card through an action.
            .accessibilityAction(named: "Show Details") {
                toggle()
            }
        if clickToOpen { anchored.onTapGesture { toggle() } } else { anchored }
    }
    private func toggle() {
        if let v = box.view { HoverCardController.shared.toggle(v, interactive: interactive) { AnyView(card()) } }
    }
}

extension View {
    /// Shows `card` beside the menu-bar panel while the pointer rests on this view.
    @ViewBuilder func hoverCard<Card: View>(enabled: Bool = true, interactive: Bool = false, clickToOpen: Bool = false,
                                          @ViewBuilder _ card: @escaping () -> Card) -> some View {
        if enabled { modifier(HoverCardModifier(card: card, interactive: interactive, clickToOpen: clickToOpen)) } else { self }
    }
}

/// macOS overlay scrollers: thin, and only while scrolling, whatever "Show scroll bars" says.
private final class OverlayScrollerView: NSView {
    // Read in deinit, which is nonisolated; only touched on the main thread otherwise.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
    }
    func apply() {
        guard let scroll = enclosingScrollView else { return }
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller?.controlSize = .small
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayScrollerView { OverlayScrollerView() }
    func updateNSView(_ v: OverlayScrollerView, context: Context) { v.apply() }
}

extension View {
    /// Put on a ScrollView's content: makes that scroll view use thin overlay scrollers.
    func overlayScroller() -> some View { background(OverlayScroller()) }
}

/// For the app shell: close any hover card together with the panel.
@MainActor public enum HoverCards { public static func hide() { HoverCardController.shared.hide() } }
