import SwiftUI
import AppKit
import T3ProxyCore

/// Provider tints and the live dot; everything else defers to system semantic colors.
struct Theme {
    let dark: Bool
    init(_ s: ColorScheme) { dark = s == .dark }
    // System semantic colors so the popover's Liquid Glass material shows through.
    var primary: Color { .primary }
    var secondary: Color { .secondary }
    var divider: Color { Color(nsColor: .separatorColor) }
    var track: Color { Color(nsColor: .quaternaryLabelColor) }
    let live = Color(hex: 0x22DD33)
    func tint(_ p: Provider) -> Color {
        switch p {
        case .claude: return Color(hex: dark ? 0xF58A4B : 0xE8743B)
        case .codex: return Color(hex: dark ? 0x5FEA7F : 0x3DBB55)
        case .other: return secondary
        }
    }
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}

enum Marks {
    private static let bundle: Bundle? = {
        let name = "T3Proxy_T3ProxyUI.bundle"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)]
        return candidates.compactMap { $0 }.compactMap(Bundle.init(url:)).first
    }()
    static func image(_ file: String, ext: String = "pdf") -> NSImage? {
        guard let u = bundle?.url(forResource: "Resources/\(file)", withExtension: ext) ?? bundle?.url(forResource: file, withExtension: ext) else { return nil }
        return NSImage(contentsOf: u)
    }
}

struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 17
    /// The hub's provider word, used when `provider` is `.other` (xai, kimi, …).
    var name: String? = nil
    @Environment(\.colorScheme) private var scheme

    private struct Mark { let file: String; var ext = "svg"; var mono = false; var tile = false; var claudeTint = false }

    /// Brand marks (lobehub/icons, MIT). Monochrome ones follow the text colour; colour ones keep theirs.
    /// Kimi's colour mark is dark, so it sits on a white tile like Proxy Deck.
    private static let others: [String: Mark] = {
        let xai = Mark(file: "xai", mono: true), kimi = Mark(file: "kimi", tile: true)
        let meta = Mark(file: "meta"), vertex = Mark(file: "vertex"), gemini = Mark(file: "gemini")
        let claude = Mark(file: "claude", ext: "pdf", mono: true, claudeTint: true), openai = Mark(file: "openai", ext: "pdf", mono: true)
        return [
            "xai": xai, "grok": xai, "devin": Mark(file: "devin", mono: true), "antigravity": Mark(file: "antigravity"),
            "kimi": kimi, "kimi-ai": kimi, "meta": meta, "muse": meta, "vertex": vertex, "vertexai": vertex,
            "gemini": gemini, "gemini-cli": gemini, "qwen": Mark(file: "qwen"),
            "anthropic": claude, "claude": claude, "openai": openai, "codex": openai,
        ]
    }()

    var body: some View {
        let t = Theme(scheme)
        if provider != .other, let img = Marks.image(provider == .claude ? "claude" : "openai") {
            Image(nsImage: img).resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(provider == .claude ? t.tint(.claude) : t.primary).frame(width: size, height: size)
        } else if let n = name?.lowercased(), let m = Self.others[n], let img = Marks.image(m.file, ext: m.ext) {
            if m.tile {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(.white).frame(width: size, height: size)
                    .overlay(Image(nsImage: img).resizable().renderingMode(.original).scaledToFit().padding(size * 0.17))
            } else {
                Image(nsImage: img).resizable().renderingMode(m.mono ? .template : .original).scaledToFit()
                    .foregroundStyle(m.claudeTint ? t.tint(.claude) : t.primary).frame(width: size, height: size)
            }
        } else {
            Circle().stroke(t.secondary, lineWidth: 1.5).frame(width: size * 0.8, height: size * 0.8).frame(width: size, height: size)
        }
    }
}

/// The single menu bar icon: "T3" over the route line from the app icon, as a template image.
/// The menu-bar glyph. With `attention`, an orange dot sits at the top right; the size never changes.
/// A template image can't carry colour, so that variant draws in the label colour of the current appearance.
public func statusIconImage(attention: Bool = false) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
        let ink: NSColor = attention ? .labelColor : .black
        let font = NSFont.systemFont(ofSize: 11.5, weight: .heavy)
        let s = NSAttributedString(string: "T3", attributes: [.font: font, .foregroundColor: ink])
        let w = s.size().width
        s.draw(at: NSPoint(x: (22 - w) / 2, y: -0.5))
        ink.set()
        let p = NSBezierPath()
        p.lineWidth = 1.2
        p.move(to: NSPoint(x: 3.5, y: 14))
        p.line(to: NSPoint(x: 8, y: 14))
        p.curve(to: NSPoint(x: 11, y: 16), controlPoint1: NSPoint(x: 9.5, y: 14), controlPoint2: NSPoint(x: 9.5, y: 16))
        p.curve(to: NSPoint(x: 14, y: 14), controlPoint1: NSPoint(x: 12.5, y: 16), controlPoint2: NSPoint(x: 12.5, y: 14))
        p.line(to: NSPoint(x: 18.5, y: 14))
        p.stroke()
        for x in [3.0, 19.0] { NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: 12.5, width: 3, height: 3)).fill() }
        if attention {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 0.5, width: 5, height: 5)).fill()
        }
        return true
    }
    img.isTemplate = !attention
    img.accessibilityDescription = attention ? "T3 Proxy, a thread needs you" : "T3 Proxy"
    return img
}
