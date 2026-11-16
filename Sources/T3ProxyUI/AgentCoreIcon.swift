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
    private var delegated = false
    private var working = false
    private var snoozed = false
    private var errorActive = false
    private var staticEffect = false
    private struct SurfaceStyle: Equatable {
        let pixels: Int; let dark: Bool; let tint: AgentOrbTint; let color: AgentIconColor?
    }
    private var rendered: [AgentOrbPart: SurfaceStyle] = [:]
    private var phases: [AgentOrbPart: Double] = [:]

    func configure(_ preferences: AgentIconPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        restyle()
    }

    private func selectedColor(_ tint: AgentOrbTint) -> AgentIconColor? {
        if let preferences, preferences.colorMode == .custom && !(state == .idle && !needsYou && !errorActive) {
            switch tint {
            case .blue: return preferences.activeColor
            case .orange: return preferences.attentionColor
            case .red: return preferences.errorColor
            }
        }
        if preferences == nil && state != .idle { return nil }
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
        halo.name = "orb.halo"; nucleus.name = "orb.nucleus"
        for part in [AgentOrbPart.inner, .core, .outer, .ring] {
            let shell = shells[part]!
            shell.name = "orb.\(part)"
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
    private var needsYou: Bool { state == .waiting || attention }
    private func dormant(_ part: AgentOrbPart) -> Bool {
        snoozed && !errorActive && (part == .core || (part == .inner && !needsYou))
    }
    /// Concurrent concerns occupy separate surfaces: work outside, attention inside, error at the core.
    private func tint(for part: AgentOrbPart) -> AgentOrbTint {
        if errorActive && (part == .inner || part == .core || state == .idle) { return .red }
        if needsYou && (part == .inner || part == .core || (!working && !delegated)) { return .orange }
        return .blue
    }
    private func surfaceColor(_ part: AgentOrbPart, tint: AgentOrbTint) -> AgentIconColor? {
        if dormant(part) { return AgentIconColor(hex: dark ? "B8C5D1" : "53616E") }
        if part == .ring && delegated && tint != .red {
            return preferences?.colorMode == .custom ? preferences?.backgroundColor : AgentIconColor(hex: "A57BFF")
        }
        return selectedColor(tint)
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
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

    private func phase(of layer: CALayer, fallback: Double) -> Double {
        guard let spin = layer.animation(forKey: "spin"), spin.duration > 0 else { return fallback }
        let turns = (layer.convertTime(CACurrentMediaTime(), from: nil) - spin.beginTime) / spin.duration
        return turns - floor(turns)
    }

    private func period(for part: AgentOrbPart) -> Double {
        if state == .streaming || errorActive { return Self.streamingPeriods[part] ?? 7 }
        let slow = !working
        return (slow ? [.outer: 40.0, .inner: 30, .core: 12, .ring: 6]
                     : [.outer: 22.0, .inner: 15, .core: 6, .ring: 3.2])[part] ?? 20
    }

    /// Build atlases before sampling time; expensive first-use rendering must not advance the pose.
    /// Each surface has its own local clock. Unchanged animations stay installed.
    private func restyle() {
        guard bounds.width > 0 else { return }
        let animate = (state != .idle || errorActive) && !reduced
        let styles = Dictionary(uniqueKeysWithValues: AgentOrbPart.allCases.map { part in
            let tint = tint(for: part)
            return (part, SurfaceStyle(pixels: pixels, dark: dark, tint: tint, color: surfaceColor(part, tint: tint)))
        })
        var atlases: [AgentOrbPart: [CGImage]] = [:]
        for part in AgentOrbPart.allCases {
            let style = styles[part]!
            let shell = shells[part]!
            let spinning = animate && !dormant(part) && (part != .ring || delegated)
            if rendered[part] != style || (spinning && shell.animation(forKey: "spin") == nil) {
                atlases[part] = spinning
                    ? AgentOrbRenderer.frames(part, pixels: pixels, dark: dark, tint: style.tint, color: style.color)
                    : []
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for part in AgentOrbPart.allCases {
            let shell = shells[part]!, style = styles[part]!
            let spinning = animate && !dormant(part) && (part != .ring || delegated)
            let spin = shell.animation(forKey: "spin")
            let changed = rendered[part] != style
            guard changed || (spinning ? spin?.duration != period(for: part) : spin != nil) else { continue }
            let pose = phase(of: shell, fallback: phases[part] ?? 0)
            phases[part] = pose
            let frames = atlases[part] ?? (spin as? CAKeyframeAnimation)?.values?.map { $0 as! CGImage } ?? []
            if animate && changed && rendered[part] != nil {
                let fade = CATransition(); fade.type = .fade; fade.duration = 0.24
                shell.add(fade, forKey: "palette")
            }
            shell.removeAnimation(forKey: "spin")
            if !frames.isEmpty {
                shell.contents = frames[min(Int(pose * Double(AgentOrbRenderer.frameCount)), frames.count - 1)]
            } else {
                shell.contents = AgentOrbRenderer.still(part, pixels: pixels, dark: dark, tint: style.tint,
                                                       color: style.color, phase: pose)
            }
            if spinning && !frames.isEmpty {
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = Array(frames.prefix(AgentOrbRenderer.frameCount)) + [frames[0]]
                animation.calculationMode = .linear; animation.duration = period(for: part)
                animation.repeatCount = .infinity
                animation.beginTime = shell.convertTime(CACurrentMediaTime(), from: nil) - pose * animation.duration
                shell.add(animation, forKey: "spin")
            }
        }
        rendered = styles
        let glowTint: AgentOrbTint = errorActive ? .red : needsYou ? .orange : .blue
        let g = glow(glowTint)
        if animate { CATransaction.setDisableActions(false); CATransaction.setAnimationDuration(0.24) }
        halo.colors = needsYou ? glow(.orange).halo : g.halo
        halo.locations = [0, 0.45, 1]; nucleus.colors = g.nucleus
        let (_, mid, front) = AgentOrbRenderer.palette(glowTint, dark: dark, color: selectedColor(glowTint))
        rings[0].strokeColor = Self.color(dark ? front : mid, 1); rings[1].strokeColor = Self.color(mid, 0.8)
        nucleus.opacity = snoozed && state == .idle && !errorActive ? 0.18 : 1
        halo.opacity = snoozed && state == .idle && !errorActive ? 0.08 : 1
        CATransaction.commit()
        updateBreathing(animate: animate)
    }

    public func update(state: AgentActivity, attention: Bool, reduceMotion: Bool) {
        update(AgentActivityUpdate(state: state, needsAttention: attention), reduceMotion: reduceMotion)
    }

    public func update(_ activity: AgentActivityUpdate, reduceMotion: Bool) {
        let state = activity.state, attention = activity.needsAttention
        self.state = state; self.attention = attention; reduced = reduceMotion
        working = activity.hasWorkingThread; delegated = activity.hasDelegatedWork
        snoozed = activity.snoozedThreadCount > 0
        if staticEffect { finishEffect() }
        if reduced || (state == .idle && !errorActive) {
            for (part, shell) in shells { phases[part] = phase(of: shell, fallback: phases[part] ?? 0) }
            stopAll()
            rendered = [:]
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let ring = shells[.ring] {
            let target: Float = delegated ? 1 : 0
            if ring.opacity != target && !reduced && state != .idle {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = ring.presentation()?.opacity ?? ring.opacity; fade.toValue = target; fade.duration = 0.24
                ring.add(fade, forKey: "visibility")
            }
            ring.isHidden = false; ring.opacity = target
        }
        orb.opacity = state == .idle && !errorActive ? 0.6 : 1
        CATransaction.commit()
        restyle()
    }

    private func stopAll() {
        func strip(_ l: CALayer) { l.removeAllAnimations(); l.sublayers?.forEach(strip) }
        if let layer { strip(layer) }
    }

    private static let streamingPeriods: [AgentOrbPart: Double] = [.outer: 7, .inner: 5, .core: 2.4, .ring: 2.2]

    /// Shell spin: each layer cycles through its own true-3D frames; inner counter-rotates against outer.
    /// With attention, the strongest active motion is kept and only the colour turns orange.
    private func updateBreathing(animate: Bool) {
        guard animate else { nucleus.removeAnimation(forKey: "breath"); halo.removeAnimation(forKey: "breath"); return }
        let fast = state == .streaming, waiting = needsYou
        // One shared brightness curve preserves brightness as the breathing speed changes.
        let breath = CAKeyframeAnimation(keyPath: "opacity")
        breath.values = [0.55, 1, 0.55]
        breath.duration = fast ? 0.9 : waiting ? 2.2 : 3.2
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for layer in [nucleus, halo] {
            if layer.animation(forKey: "breath")?.duration == breath.duration { continue }
            let old = layer.animation(forKey: "breath")
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            let turns = old.map { (now - $0.beginTime) / $0.duration } ?? 0
            breath.beginTime = now - (turns - floor(turns)) * breath.duration
            layer.add(breath, forKey: "breath")
        }
    }

    /// Remove only overlays. State, palette and speed restoration use the same phase-preserving path.
    public func finishEffect() {
        for layer in [orb, halo, nucleus] + Array(shells.values) + rings {
            for key in layer.animationKeys() ?? [] where !["spin", "breath", "visibility", "palette"].contains(key) {
                layer.removeAnimation(forKey: key)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rings.forEach { $0.opacity = 0 }
        CATransaction.commit()
        errorActive = false; staticEffect = false
        restyle()
        if state == .idle || reduced { stopAll() }
    }

    /// Bounded one-shot effects (≤ 1.5 s). They never touch model values when animating, so the base
    /// tint and any running spin show through untouched once they end. Reduce Motion: static frame only,
    /// cleared by the next `update`.
    public func play(_ effect: AgentEffect, reduceMotion: Bool) {
        finishEffect()
        errorActive = effect == .error
        staticEffect = reduceMotion
        if errorActive { restyle() }
        guard !reduceMotion else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if effect == .report { rings[0].opacity = 1 }
            if effect == .finished { rings[1].opacity = 1 }
            CATransaction.commit()
            return
        }
        let now = CACurrentMediaTime()
        func add(_ layer: CALayer, _ key: String, _ path: String, _ values: [Any],
                 _ times: [NSNumber]? = nil, duration: Double, delay: Double = 0, additive: Bool = false) {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values; a.keyTimes = times; a.duration = duration
            a.beginTime = layer.convertTime(now + delay, from: nil); a.fillMode = .backwards
            a.isAdditive = additive
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: key)
        }
        switch effect {
        case .report:
            // Incoming energy converges on the core; underlying shell rotation keeps going.
            for (i, ring) in rings.enumerated() {
                let d = Double(i) * 0.18
                add(ring, "converge", "transform.scale", [1.35, 0.12], duration: 0.6, delay: d)
                add(ring, "convergeFade", "opacity", [0, 1, 0], [0, 0.35, 1], duration: 0.6, delay: d)
            }
            add(nucleus, "bloom", "transform.scale", [1, 1, 2.8, 1], [0, 0.4, 0.6, 1], duration: 1.4)
            add(nucleus, "bloomOpacity", "opacity", [0, 0, 0.5, 0], [0, 0.4, 0.6, 1], duration: 1.4, additive: true)
            add(halo, "bloomHalo", "opacity", [0, 0, 0.4, 0], [0, 0.4, 0.6, 1], duration: 1.4, additive: true)
            add(orb, "gather", "transform.scale", [1, 0.9, 1.06, 1], [0, 0.42, 0.62, 1], duration: 1.4)
        case .finished:
            for (part, scale) in [(AgentOrbPart.outer, 1.32), (.ring, 1.4), (.inner, 1.16), (.core, 0.8)] {
                let shell = shells[part]!
                add(shell, "open", "transform.scale", [1, scale, scale, 1], [0, 0.35, 0.55, 1], duration: 1.5)
                // Additive opacity preserves an absent delegated ring throughout the effect.
                add(shell, "openFade", "opacity", [0, part == .core ? 0 : -0.75, part == .core ? 0 : -0.75, 0],
                    [0, 0.35, 0.55, 1], duration: 1.5, additive: true)
            }
            add(rings[1], "release", "transform.scale", [0.7, 1.25], duration: 0.9)
            add(rings[1], "releaseFade", "opacity", [0, 0.9, 0], [0, 0.25, 1], duration: 0.9)
            add(nucleus, "settle", "transform.scale", [1, 1.6, 1.6, 1], [0, 0.35, 0.55, 1], duration: 1.5)
        case .error:
            // Speed and colour enter/leave through restyle(), preserving phase at both boundaries.
            add(nucleus, "errorFlicker", "opacity", [0, 0.4, -0.2, 0.4, -0.2, 0], duration: 1.4, additive: true)
        }
    }

    /// Static template for callers that need an NSImage representation of the orb.
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
                    self.effectTask?.cancel(); self.view.finishEffect()
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
        effectTask?.cancel(); view.finishEffect()
        view.configure(next)
        refresh()
    }
    public func apply(_ next: AgentActivityUpdate) {
        let changed = update.state != next.state || update.needsAttention != next.needsAttention
            || update.hasWorkingThread != next.hasWorkingThread || update.hasDelegatedWork != next.hasDelegatedWork
            || update.snoozedThreadCount != next.snoozedThreadCount || update.hasWaitingThread != next.hasWaitingThread
        update = next
        let status = "T3 Proxy — \(next.label)"
        button?.toolTip = status + (next.threadTitle.map { "\n\($0)" } ?? "")
        button?.setAccessibilityLabel(status)
        if changed { refresh() }
        guard preferences.style == .orb, let effect = next.effect else { return }
        effectTask?.cancel(); display()
        view.play(effect, reduceMotion: reduced)
        effectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.view.finishEffect(); self.refresh()
        }
    }
    public func layout() {
        guard let button, let cell = button.cell as? NSButtonCell else { return }
        view.frame = cell.imageRect(forBounds: button.bounds)
        view.needsLayout = true
    }
    private func refresh() {
        view.update(preferences.style == .classic ? AgentActivityUpdate() : update, reduceMotion: reduced)
        display()
    }
    private func display() {
        if preferences.style == .classic {
            view.isHidden = true
            button?.image = Self.classicImage(attention: update.needsAttention)
            layout()
            return
        }
        // Keep the same geometry at its last angle through idle; a template/live swap used to snap.
        // The static layers follow menu-bar foreground appearance and do no recurring work.
        view.isHidden = false
        button?.image = NSImage(size: NSSize(width: 18, height: 18))
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
