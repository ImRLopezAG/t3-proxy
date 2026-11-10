import AppKit
import CryptoKit
import WebKit

/// Draws SVG project icons the way T3 Code does: with WebKit.
///
/// macOS's own SVG renderer (NSImage, Quick Look) ignores `clip-rule="evenodd"` in clip paths and CSS such as
/// `prefers-color-scheme`, so icons like a ring cut from a disc render as a filled disc. Here one hidden, off-screen
/// web view rasterizes one icon at a time. The SVG is shown through an `<img>`, which WebKit renders in its static
/// image mode (no scripts, no external loads); JavaScript is off, the data store is non-persistent, and every
/// navigation other than the initial page is refused. Results are cached per (bytes, size, appearance).
@MainActor
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    static let shared = SVGRasterizer()

    private var web: WKWebView?
    private var window: NSWindow?
    private var queue: [(key: String, data: Data, side: CGFloat, dark: Bool, done: (NSImage?) -> Void)] = []
    private var busy = false
    private var current: ((NSImage?) -> Void)?
    private var currentSide: CGFloat = 0
    private var timeout: Task<Void, Never>?
    private var cache: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage?) -> Void]] = [:]

    static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(1024), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }

    func render(_ data: Data, side: CGFloat, dark: Bool) async -> NSImage? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "\(digest)|\(Int(side))|\(dark)"
        if let hit = cache[key] { return hit }
        return await withCheckedContinuation { (c: CheckedContinuation<NSImage?, Never>) in
            if waiting[key] != nil { waiting[key]?.append { c.resume(returning: $0) }; return }
            waiting[key] = [{ c.resume(returning: $0) }]
            queue.append((key, data, side, dark, { [weak self] image in
                guard let self else { return }
                if let image { self.cache[key] = image }
                for w in self.waiting.removeValue(forKey: key) ?? [] { w(image) }
            }))
            next()
        }
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        let web = webView()
        web.appearance = NSAppearance(named: job.dark ? .darkAqua : .aqua)
        web.setFrameSize(NSSize(width: job.side, height: job.side))
        window?.setContentSize(NSSize(width: job.side, height: job.side))
        currentSide = job.side
        current = job.done
        let px = Int(job.side)
        let html = """
            <!doctype html><html><head><meta name="color-scheme" content="\(job.dark ? "dark" : "light")">\
            <style>html,body{margin:0;padding:0;background:transparent}img{display:block;width:\(px)px;height:\(px)px;object-fit:contain}</style>\
            </head><body><img src="data:image/svg+xml;base64,\(job.data.base64EncodedString())"></body></html>
            """
        web.loadHTMLString(html, baseURL: nil)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
    }

    private func finish(_ image: NSImage?) {
        timeout?.cancel(); timeout = nil
        let done = current
        current = nil; busy = false
        done?(image)
        next()
    }

    private func webView() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        // WebKit only draws views that are in a window: an invisible one far off screen, never shown to the user.
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 32, height: 32), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.alphaValue = 0
        win.ignoresMouseEvents = true; win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        win.contentView = w
        win.orderBack(nil)
        web = w; window = win
        return w
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the page we load ourselves (about:blank with the inline HTML).
        decisionHandler(action.request.url?.scheme == "about" || action.request.url == nil ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: currentSide, height: currentSide)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated { self?.finish(image) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(nil) }
}
