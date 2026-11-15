import AppKit
import Combine
import QuartzCore
import T3ProxyCore

/// Holographic layered orb. Each shell is a loop of pre-rendered true-3D projections (see AgentOrbRenderer)
/// played by Core Animation in the render server: no display link, timer or per-frame app work.
/// Idle and Reduce Motion carry no animations at all. Effects are bounded animations layered on top of
/// the base state; when they end, the layer model values (base tint, base motion) show through unchanged.
@MainActor public final class AgentCoreView: NSView {
    private let orb = CALayer()          // container: scale/shake for effects
    private let halo = CAGradientLayer()
    private let shells: [AgentOrbPart: CALayer] = Dictionary(uniqueKeysWithValues: AgentOrbPart.allCases.map { ($0, CALayer()) })
    private let nucleus = CAGradientLayer()
    private let rings = [CAShapeLayer(), CAShapeLayer()]   // effect energy rings
    private var state: AgentActivity = .idle
    private var attention = false
    private var reduced = false
    private var preferences: AgentIconPreferences?
    private var rendered: (pixels: Int, dark: Bool, tint: Int, animated: Bool)?

    func configure(_ preferences: AgentIconPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        update(state: state, attention: attention, reduceMotion: reduced)
    }

    private func selectedColor(_ tint: AgentOrbTint) -> AgentIconColor? {
        guard let preferences else { return nil }
        if preferences.colorMode == .custom {
            switch tint {
            case .blue: return preferences.activeColor
            case .orange: return preferences.attentionColor
            case .red: return preferences.errorColor
            }
        }
        guard tint == .blue else { return nil }
        var foreground = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = NSColor.labelColor.usingColorSpace(.sRGB) ?? (dark ? .white : .black)
        }
        return AgentIconColor(foreground)
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.addSublayer(orb)
        for g in [halo, nucleus] {
            g.type = .radial; g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
        }
        orb.addSublayer(halo)
        for part in [AgentOrbPart.inner, .core, .outer, .ring] {
            let shell = shells[part]!
            shell.contentsGravity = .resizeAspect
            orb.addSublayer(shell)
            if part == .core { orb.addSublayer(nucleus) }
        }
        nucleus.locations = [0, 0.35, 1]
        for ring in rings { ring.fillColor = nil; ring.opacity = 0; root.addSublayer(ring) }
        update(state: .idle, attention: false, reduceMotion: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var pixels: Int { max(8, Int((bounds.width * (window?.backingScaleFactor ?? 2)).rounded())) }
    /// Waiting, or any state while a thread needs you, is orange; everything else is blue.
    private var baseTint: AgentOrbTint { state == .waiting || attention ? .orange : .blue }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rendered = nil; restyle() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); restyle() }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        orb.frame = bounds
        orb.sublayers?.forEach { $0.frame = bounds; $0.contentsScale = scale }
        let s = bounds.width / 18
        nucleus.frame = bounds.insetBy(dx: 6.4 * s, dy: 6.4 * s)
        halo.frame = bounds.insetBy(dx: -1 * s, dy: -1 * s)
        for (i, ring) in rings.enumerated() {
            ring.frame = bounds
            ring.lineWidth = max(0.8, (i == 0 ? 0.55 : 0.35) * s)
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: (1.2 + CGFloat(i) * 0.8) * s, dy: (1.2 + CGFloat(i) * 0.8) * s), transform: nil)
        }
        CATransaction.commit()
        restyle()
    }

    private static func color(_ c: SIMD3<Float>, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: a)
    }

    private func glow(_ tint: AgentOrbTint) -> (halo: [CGColor], nucleus: [CGColor]) {
        let (_, mid, front) = AgentOrbRenderer.palette(tint, dark: dark, color: selectedColor(tint))
        let haloA: CGFloat = dark ? 0.42 : 0.28
        return ([Self.color(mid, haloA), Self.color(mid, haloA * 0.28), Self.color(mid, 0)],
                [Self.color(front, 1), Self.color(mid, 0.8), Self.color(mid, 0)])
    }

    private func applyTint(_ tint: AgentOrbTint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let g = glow(tint)
        halo.colors = g.halo; halo.locations = [0, 0.45, 1]
        nucleus.colors = g.nucleus
        for (part, layer) in shells { layer.contents = AgentOrbRenderer.still(part, pixels: pixels, dark: dark, tint: tint, color: selectedColor(tint)) }
        let (_, mid, front) = AgentOrbRenderer.palette(tint, dark: dark, color: selectedColor(tint))
        rings[0].strokeColor = Self.color(dark ? front : mid, 1)
        rings[1].strokeColor = Self.color(mid, 0.8)
        CATransaction.commit()
    }

    /// Model values for the base state. Only rebuilt when size, appearance, tint or motion actually change.
    private func restyle() {
        guard bounds.width > 0 else { return }
        let animate = state != .idle && !reduced
        let want = (pixels, dark, baseTint.rawValue, animate)
        if let r = rendered, r == want { return }
        rendered = want
        applyTint(baseTint)
        if animate { startMotion() }
    }

    public func update(state: AgentActivity, attention: Bool, reduceMotion: Bool) {
        self.state = state; self.attention = attention; reduced = reduceMotion
        stopAll()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rings.forEach { $0.opacity = 0 }
        shells[.ring]?.isHidden = state != .subagent
        orb.opacity = state == .idle ? 0.6 : 1
        CATransaction.commit()
        rendered = nil
        restyle()
    }

    private func stopAll() {
        func strip(_ l: CALayer) { l.removeAllAnimations(); l.sublayers?.forEach(strip) }
        if let layer { strip(layer) }
    }

    private func spinAnimation(_ part: AgentOrbPart, tint: AgentOrbTint, period: Double) -> CAKeyframeAnimation? {
        let frames = AgentOrbRenderer.frames(part, pixels: pixels, dark: dark, tint: tint, color: selectedColor(tint))
        guard frames.count > 1 else { return nil }
        let spin = CAKeyframeAnimation(keyPath: "contents")
        spin.values = frames + [frames[0]]
        spin.calculationMode = .linear
        spin.duration = period
        spin.repeatCount = .infinity
        return spin
    }

    private static let streamingPeriods: [AgentOrbPart: Double] = [.outer: 7, .inner: 5, .core: 2.4, .ring: 2.2]

    /// Shell spin: each layer cycles through its own true-3D frames; inner counter-rotates against outer.
    /// With attention, the strongest active motion is kept and only the colour turns orange.
    private func startMotion() {
        stopAll()
        let fast = state == .streaming, waiting = state == .waiting
        let periods: [AgentOrbPart: Double] = fast ? Self.streamingPeriods
            : waiting ? [.outer: 40, .inner: 30, .core: 12, .ring: 6] : [.outer: 22, .inner: 15, .core: 6, .ring: 3.2]
        for (part, layer) in shells where !(part == .ring && state != .subagent) {
            if let spin = spinAnimation(part, tint: baseTint, period: periods[part] ?? 20) { layer.add(spin, forKey: "spin") }
        }
        // Breathing core light on the visible nucleus + halo. Waiting breathes slow and deep.
        let breath = CAKeyframeAnimation(keyPath: "opacity")
        breath.values = fast ? [0.6, 1, 0.7, 1, 0.6] : waiting ? [0.3, 1, 0.3] : [0.6, 1, 0.6]
        breath.duration = fast ? 0.9 : waiting ? 2.2 : 3.2
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        nucleus.add(breath, forKey: "breath")
        halo.add(breath, forKey: "breath")
    }

    /// Bounded one-shot effects (≤ 1.5 s). They never touch model values when animating, so the base
    /// tint and any running spin show through untouched once they end. Reduce Motion: static frame only,
    /// cleared by the next `update`.
    public func play(_ effect: AgentEffect, reduceMotion: Bool) {
        let now = CACurrentMediaTime()
        func anim(_ path: String, _ values: [Any], _ times: [NSNumber]? = nil, duration: Double, delay: Double = 0) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values; a.keyTimes = times; a.duration = duration
            a.beginTime = now + delay; a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }
        guard !reduceMotion else {
            switch effect {
            case .error: applyTint(.red)
            case .report: CATransaction.begin(); CATransaction.setDisableActions(true); rings[0].opacity = 1; CATransaction.commit()
            case .finished: CATransaction.begin(); CATransaction.setDisableActions(true); rings[1].opacity = 1; CATransaction.commit()
            }
            return
        }
        switch effect {
        case .report:
            // Energy arrives: two rings collapse inward one after another, then the core blooms ice-white.
            for (i, ring) in rings.enumerated() {
                let d = Double(i) * 0.18
                ring.add(anim("transform.scale", [1.35, 0.12], duration: 0.6, delay: d), forKey: "converge")
                ring.add(anim("opacity", [0, 1, 0], [0, 0.35, 1], duration: 0.6, delay: d), forKey: "convergeFade")
            }
            nucleus.add(anim("transform.scale", [1, 1, 2.8, 1], [0, 0.4, 0.6, 1], duration: 1.4), forKey: "bloom")
            nucleus.add(anim("opacity", [1, 1, 1, 1], duration: 1.4), forKey: "bloomOpacity")
            halo.add(anim("opacity", [0.5, 0.5, 1, 0.6], [0, 0.4, 0.6, 1], duration: 1.4), forKey: "bloomHalo")
            orb.add(anim("transform.scale", [1, 0.9, 1.06, 1], [0, 0.42, 0.62, 1], duration: 1.4), forKey: "gather")
        case .finished:
            // Graceful opening: outer shell lifts away and fades, inner shell drifts, core glows; then reassembles.
            let open: [(AgentOrbPart, Double)] = [(.outer, 1.32), (.ring, 1.4), (.inner, 1.16), (.core, 0.8)]
            for (part, scale) in open {
                shells[part]?.add(anim("transform.scale", [1, scale, scale, 1], [0, 0.35, 0.55, 1], duration: 1.5), forKey: "open")
                shells[part]?.add(anim("opacity", [1, part == .core ? 1 : 0.25, part == .core ? 1 : 0.25, 1], [0, 0.35, 0.55, 1], duration: 1.5), forKey: "openFade")
            }
            rings[1].add(anim("transform.scale", [0.7, 1.25], duration: 0.9), forKey: "release")
            rings[1].add(anim("opacity", [0, 0.9, 0], [0, 0.25, 1], duration: 0.9), forKey: "releaseFade")
            nucleus.add(anim("transform.scale", [1, 1.6, 1.6, 1], [0, 0.35, 0.55, 1], duration: 1.5), forKey: "settle")
        case .error:
            // Whole orb turns red with streaming energy for one bounded burst, plus a short shake.
            let duration = 1.4
            for (part, layer) in shells where !(part == .ring && state != .subagent) {
                guard let spin = spinAnimation(part, tint: .red, period: Self.streamingPeriods[part] ?? 5) else { continue }
                spin.repeatCount = Float(duration / spin.duration); spin.beginTime = now
                layer.add(spin, forKey: "errorSpin")   // overrides base contents only while running
            }
            let g = glow(.red)
            halo.add(anim("colors", [g.halo, g.halo], duration: duration), forKey: "errorHalo")
            nucleus.add(anim("colors", [g.nucleus, g.nucleus], duration: duration), forKey: "errorCore")
            nucleus.add(anim("opacity", [0.5, 1, 0.5, 1, 0.5, 1], duration: duration), forKey: "errorFlicker")
            let s = bounds.width / 18
            orb.add(anim("transform.translation.x", [0, -1.1 * s, 1.1 * s, -0.6 * s, 0.3 * s, 0], duration: 0.45), forKey: "shake")
        }
    }

    /// Rasterized once from the same 3D geometry (depth → alpha). Idle needs neither layers nor timers.
    public static func templateImage() -> NSImage { idleTemplate }
    private static let idleTemplate: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for pixels in [18, 36, 54, 216] {
            if let cg = AgentOrbRenderer.templateComposite(pixels: pixels) {
                let rep = NSBitmapImageRep(cgImage: cg); rep.size = NSSize(width: 18, height: 18)
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true; return image
    }()
}

/// Owns the artwork within the existing status button. No display link, frame timer or extra item.
@MainActor public final class AgentStatusIcon {
    private weak var button: NSStatusBarButton?
    private let view = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    private var update = AgentActivityUpdate()
    private var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var effectTask: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []
    private var overlay = false
    private let defaults: UserDefaults
    private var preferences: AgentIconPreferences
    public init(button: NSStatusBarButton, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = AgentIconPreferences(defaults: defaults)
        self.button = button
        view.configure(preferences)
        button.addSubview(view)
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: button)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }.store(in: &observations)
        button.postsFrameChangedNotifications = true
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self.effectTask?.cancel(); self.overlay = false
                    self.refresh()
                }
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadPreferences() }
            }.store(in: &observations)
        refresh()
    }
    private func reloadPreferences() {
        let next = AgentIconPreferences(defaults: defaults)
        guard preferences != next else { return }
        preferences = next
        effectTask?.cancel(); overlay = false
        view.configure(next)
        refresh()
    }
    public func apply(_ next: AgentActivityUpdate) {
        let changed = update.state != next.state || update.needsAttention != next.needsAttention
        update = next
        let status = "T3 Proxy — \(next.state.label)" + (next.needsAttention && next.state != .waiting ? " · Needs you" : "")
        button?.toolTip = status + (next.threadTitle.map { "\n\($0)" } ?? "")
        button?.setAccessibilityLabel(status)
        if changed { refresh() }
        guard preferences.style == .orb, let effect = next.effect else { return }
        effectTask?.cancel(); overlay = true; display()
        view.play(effect, reduceMotion: reduced)
        effectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.overlay = false; self.refresh()
        }
    }
    public func layout() {
        guard let button, let cell = button.cell as? NSButtonCell else { return }
        view.frame = cell.imageRect(forBounds: button.bounds)
        view.needsLayout = true
    }
    private func refresh() {
        view.update(state: preferences.style == .classic ? .idle : update.state, attention: update.needsAttention, reduceMotion: reduced)
        display()
    }
    private func display() {
        if preferences.style == .classic {
            view.isHidden = true
            button?.image = Self.classicImage(attention: update.needsAttention)
            layout()
            return
        }
        let idle = update.state == .idle && !overlay && !update.needsAttention
        view.isHidden = idle
        button?.image = idle ? AgentCoreView.templateImage() : NSImage(size: NSSize(width: 18, height: 18))
        layout()
    }

    public static func classicImage(attention: Bool = false) -> NSImage {
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
}
