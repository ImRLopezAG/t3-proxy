import AppKit

@MainActor
enum AppScrollbars {
    static func apply(to view: NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
                if scroller.controlSize != .small { scroller.controlSize = .small }
            }
        }
        for child in view.subviews { apply(to: child) }
    }
}
