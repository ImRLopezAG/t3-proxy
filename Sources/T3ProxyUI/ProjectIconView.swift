import AppKit
import SwiftUI
import T3ProxyCore

/// A T3 Code project's icon, drawn the way T3 Code draws it: the project's favicon when it has one, else its chosen
/// emoji, symbol or monogram, else the monogram T3 Code derives from the title (same letters, same color).
struct ProjectIconView: View {
    let project: T3CodeProject?
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    @State private var favicon: NSImage?

    var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else {
                switch icon {
                case .emoji(let e):
                    Text(e).font(.system(size: size * 0.8))
                case .lucide(let name, let color):
                    if let symbol = Self.symbol(for: name) {
                        Image(systemName: symbol).font(.system(size: size * 0.62, weight: .semibold))
                            .foregroundStyle(Self.color(color, scheme))
                            .frame(width: size, height: size)
                            .background(Self.color(color, scheme).opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                    } else {
                        monogram(T3ProjectMonogram.make(project?.title ?? "").text, color)
                    }
                case .monogram(let text, let color):
                    monogram(text, color)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: faviconKey) { await loadFavicon() }
    }

    private var icon: T3ProjectIcon {
        if let i = project?.projectIcon { return i }
        let m = T3ProjectMonogram.make(project?.title ?? "")
        return .monogram(text: m.text, color: m.color)
    }

    private func monogram(_ text: String, _ color: T3ProjectIconColor) -> some View {
        let c = Self.color(color, scheme)
        let one = text.count == 1
        return Text(text)
            .font(.system(size: size * (one ? 0.6 : 0.5), weight: .bold, design: .monospaced))
            .minimumScaleFactor(0.5).lineLimit(1)
            .foregroundStyle(c)
            .frame(width: size, height: size)
            .background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }

    // MARK: Favicon (local file inside the project, read off the main thread)

    /// Reloads when the project, its favicon path or its chosen icon changes.
    private var faviconKey: String {
        "\(scheme == .dark)|\(project?.id ?? "")|\(project?.workspaceRoot ?? "")|\(project?.faviconPath ?? "")|\(project?.projectIcon.map { "\($0)" } ?? "")"
    }

    private func loadFavicon() async {
        favicon = nil
        // An icon chosen in T3 Code (emoji, symbol, monogram) overrides the project's favicon.
        guard let root = project?.workspaceRoot, project?.projectIcon == nil else { return }
        let path = project?.faviconPath
        // Validated bytes (contained, regular, ≤ 4 MB), decoded here; the path is never reopened later.
        let data = await Task.detached(priority: .utility) { T3ProjectFavicon.load(workspaceRoot: root, faviconPath: path) }.value
        guard !Task.isCancelled, let data else { return }
        // SVGs go through WebKit, as in T3 Code (macOS's own SVG renderer drops clip rules and CSS); others decode here.
        if SVGRasterizer.isSVG(data) {
            let img = await SVGRasterizer.shared.render(data, side: max(32, size * 2), dark: scheme == .dark)
            guard !Task.isCancelled, let img else { return }
            img.size = NSSize(width: size, height: size)
            favicon = img
            return
        }
        guard let img = NSImage(data: data), img.isValid,
              img.size.width > 0, img.size.height > 0, img.size.width <= 4096, img.size.height <= 4096 else { return }
        img.size = NSSize(width: size, height: size)
        favicon = img
    }

    // MARK: Colors (Tailwind 600 in light mode, 400 in dark, as T3 Code)

    static func color(_ c: T3ProjectIconColor, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        let hex: UInt32 = switch c {
        case .gray: dark ? 0x9CA3AF : 0x4B5563
        case .red: dark ? 0xF87171 : 0xDC2626
        case .orange: dark ? 0xFB923C : 0xEA580C
        case .amber: dark ? 0xFBBF24 : 0xD97706
        case .yellow: dark ? 0xFACC15 : 0xCA8A04
        case .lime: dark ? 0xA3E635 : 0x65A30D
        case .green: dark ? 0x4ADE80 : 0x16A34A
        case .emerald: dark ? 0x34D399 : 0x059669
        case .teal: dark ? 0x2DD4BF : 0x0D9488
        case .cyan: dark ? 0x22D3EE : 0x0891B2
        case .sky: dark ? 0x38BDF8 : 0x0284C7
        case .blue: dark ? 0x60A5FA : 0x2563EB
        case .indigo: dark ? 0x818CF8 : 0x4F46E5
        case .violet: dark ? 0xA78BFA : 0x7C3AED
        case .purple: dark ? 0xC084FC : 0x9333EA
        case .fuchsia: dark ? 0xE879F9 : 0xC026D3
        case .pink: dark ? 0xF472B6 : 0xDB2777
        case .rose: dark ? 0xFB7185 : 0xE11D48
        }
        return Color(hex: hex)
    }

    /// Common Lucide names T3 Code offers, mapped to the closest SF Symbol; others fall back to the monogram.
    static func symbol(for lucide: String) -> String? {
        [
            "folder": "folder.fill", "folder-open": "folder.fill", "code": "chevron.left.forwardslash.chevron.right",
            "code-xml": "chevron.left.forwardslash.chevron.right", "terminal": "terminal.fill", "square-terminal": "terminal.fill",
            "rocket": "paperplane.fill", "globe": "globe", "box": "shippingbox.fill", "package": "shippingbox.fill",
            "database": "cylinder.split.1x2.fill", "server": "server.rack", "book": "book.closed.fill", "book-open": "book.fill",
            "star": "star.fill", "heart": "heart.fill", "zap": "bolt.fill", "bolt": "bolt.fill", "cpu": "cpu.fill",
            "smartphone": "iphone", "monitor": "display", "layers": "square.stack.3d.up.fill", "bot": "brain.head.profile",
            "brain": "brain", "sparkles": "sparkles", "flame": "flame.fill", "leaf": "leaf.fill", "music": "music.note",
            "camera": "camera.fill", "image": "photo.fill", "shield": "shield.fill", "lock": "lock.fill", "key": "key.fill",
            "settings": "gearshape.fill", "wrench": "wrench.fill", "hammer": "hammer.fill", "gamepad-2": "gamecontroller.fill",
            "cloud": "cloud.fill", "home": "house.fill", "house": "house.fill", "user": "person.fill", "users": "person.2.fill",
            "mail": "envelope.fill", "message-square": "message.fill", "chart-bar": "chart.bar.fill", "bar-chart": "chart.bar.fill",
            "shopping-cart": "cart.fill", "briefcase": "briefcase.fill", "graduation-cap": "graduationcap.fill",
            "flask-conical": "flask.fill", "puzzle": "puzzlepiece.fill", "palette": "paintpalette.fill", "pen-tool": "pencil.tip",
            "file-text": "doc.text.fill", "calendar": "calendar", "map": "map.fill", "compass": "safari.fill", "anchor": "sailboat.fill",
        ][lucide]
    }
}
