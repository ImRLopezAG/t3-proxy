import AppKit
import simd

/// Rasterizes the holographic orb from real 3D geometry: broken translucent plates with circuit traces on
/// staggered shells, inner wire blocks, a torus-knot core and an orbiting ring. Each frame is a true
/// perspective projection; depth drives the selected colour palette, alpha and stroke weight.
/// Frames are rendered once per (part, pixel size, appearance) and played by Core Animation.
enum AgentOrbPart: Int, CaseIterable { case outer, inner, core, ring }
/// Blue is the base identity; orange means "needs you"; red is the bounded error effect.
enum AgentOrbTint: Int, CaseIterable { case blue, orange, red }

@MainActor enum AgentOrbRenderer {
    static let frameCount = 72
    private struct Key: Hashable { let part: AgentOrbPart; let pixels: Int; let dark: Bool; let tint: AgentOrbTint }
    private static var cache: [Key: [CGImage]] = [:]
    private static var models: [Int: Model] = [:]

    static func frames(_ part: AgentOrbPart, pixels: Int, dark: Bool, tint: AgentOrbTint = .blue) -> [CGImage] {
        let key = Key(part: part, pixels: pixels, dark: dark, tint: tint)
        if let hit = cache[key] { return hit }
        let made = (0..<frameCount).compactMap {
            render(part, pixels: pixels, dark: dark, tint: tint, angle: Float($0) / Float(frameCount) * 2 * .pi)
        }
        cache[key] = made
        return made
    }

    /// Static still used for Reduce Motion; avoids building the whole sequence.
    static func still(_ part: AgentOrbPart, pixels: Int, dark: Bool, tint: AgentOrbTint = .blue) -> CGImage? {
        if let hit = cache[Key(part: part, pixels: pixels, dark: dark, tint: tint)]?.first { return hit }
        return render(part, pixels: pixels, dark: dark, tint: tint, angle: 0)
    }

    /// Single composite (outer + inner + core) with alpha boosted for a legible menu-bar template.
    static func templateComposite(pixels: Int) -> CGImage? {
        guard let ctx = context(pixels) else { return nil }
        for part in [AgentOrbPart.outer, .inner, .core] {
            draw(part, in: ctx, pixels: pixels, dark: true, tint: .blue, angle: 0.6, boost: 1.9)
        }
        let r = CGFloat(pixels) * 0.045
        // Broken rim: keeps a coherent round silhouette in the template.
        let c = CGFloat(pixels) / 2, rr = CGFloat(pixels) * 0.43
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(max(1, CGFloat(pixels) / 70)); ctx.setLineCap(.round)
        for (a, b) in [(0.15, 1.35), (1.7, 2.6), (2.9, 4.3), (4.65, 5.9)] {
            ctx.addArc(center: CGPoint(x: c, y: c), radius: rr, startAngle: a, endAngle: b, clockwise: false); ctx.strokePath()
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(pixels) / 2 - r, y: CGFloat(pixels) / 2 - r, width: 2 * r, height: 2 * r))
        return ctx.makeImage()
    }

    // MARK: Geometry

    struct Trace { var points: [SIMD3<Float>]; var tone: Float; var width: Float }
    struct Plate { var points: [SIMD3<Float>]; var tone: Float }
    struct Model { var parts: [AgentOrbPart: (traces: [Trace], plates: [Plate], dots: [SIMD3<Float>])] = [:] }

    private struct RNG {
        var state: UInt64
        mutating func next() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
        mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
    }

    private static func sph(_ r: Float, _ th: Float, _ ph: Float) -> SIMD3<Float> {
        SIMD3(r * sin(th) * cos(ph), r * cos(th), r * sin(th) * sin(ph))
    }

    /// A broken panel of a spherical shell: translucent plate, a lit edge or two and circuit walks inside.
    private static func panel(_ rng: inout RNG, radius: Float, traces: Int, into t: inout [Trace], plates: inout [Plate]) {
        let th0 = acos(rng.range(-0.88, 0.88)), ph0 = rng.range(0, 2 * .pi)
        let dth = rng.range(0.2, 0.46), dph = rng.range(0.28, 0.7) / max(sin(th0), 0.45)
        let r = radius * rng.range(0.9, 1.07)
        let tone = rng.range(0.25, 1)
        var outline: [SIMD3<Float>] = []
        for i in 0...4 { outline.append(sph(r, th0, ph0 + dph * Float(i) / 4)) }
        for i in 0...4 { outline.append(sph(r, th0 + dth, ph0 + dph * Float(4 - i) / 4)) }
        plates.append(Plate(points: outline, tone: tone))
        // Lit edges: top always, one side sometimes — keeps the panel reading as a broken slab.
        t.append(Trace(points: Array(outline[0...4]), tone: tone + 0.25, width: 1.1))
        if rng.next() < 0.5 {
            t.append(Trace(points: (0...3).map { sph(r, th0 + dth * Float($0) / 3, ph0) }, tone: tone, width: 0.9))
        }
        for _ in 0..<traces {
            var th = th0 + rng.range(0.1, 0.9) * dth, ph = ph0 + rng.range(0.05, 0.9) * dph
            var lat = rng.next() < 0.55
            var pts = [sph(r, th, ph)]
            for _ in 0..<Int(rng.range(2, 8)) {
                if rng.next() < 0.3 { lat.toggle() }
                if lat { ph = min(ph0 + dph, ph + rng.range(0.05, 0.22) * dph) }
                else { th = min(th0 + dth, max(th0, th + rng.range(-0.25, 0.25) * dth)) }
                pts.append(sph(r, th, ph))
            }
            t.append(Trace(points: pts, tone: rng.range(0.3, 1), width: 0.7))
        }
    }

    private static func arc(_ rng: inout RNG, radius: Float, span: ClosedRange<Float>, tone: Float, width: Float) -> Trace {
        let n = simd_normalize(SIMD3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1)))
        var u = simd_normalize(simd_cross(n, SIMD3(0, 1, 0.3)))
        let v = simd_cross(n, u)
        let start = rng.range(0, 2 * .pi), len = rng.range(span.lowerBound, span.upperBound)
        u = simd_normalize(u)
        let steps = max(8, Int(len * 20))
        let pts = (0...steps).map { i -> SIMD3<Float> in
            let a = start + len * Float(i) / Float(steps)
            return radius * (cos(a) * u + sin(a) * v)
        }
        return Trace(points: pts, tone: tone, width: width)
    }

    private static func model(detail high: Bool) -> Model {
        if let m = models[high ? 1 : 0] { return m }
        var m = Model()
        var rng = RNG(state: 0x7A3)
        // Outer shell: broken plates + long sweeping arcs that hold the round silhouette at 18 pt.
        var t: [Trace] = [], p: [Plate] = [], d: [SIMD3<Float>] = []
        for _ in 0..<(high ? 46 : 22) { panel(&rng, radius: 1, traces: high ? 7 : 1, into: &t, plates: &p) }
        for _ in 0..<(high ? 7 : 4) { t.append(arc(&rng, radius: 1.03, span: 1.2...2.6, tone: 0.85, width: high ? 1.2 : 1.3)) }
        if high { for _ in 0..<160 { d.append(sph(rng.range(0.9, 1.06), acos(rng.range(-1, 1)), rng.range(0, 2 * .pi))) } }
        m.parts[.outer] = (t, p, d)
        // Inner shell + wire blocks: the "structure" seen through the gaps.
        t = []; p = []; d = []
        for _ in 0..<(high ? 20 : 9) { panel(&rng, radius: 0.64, traces: high ? 4 : 0, into: &t, plates: &p) }
        for _ in 0..<(high ? 12 : 3) {
            let s = SIMD3(rng.range(0.08, 0.2), rng.range(0.08, 0.3), rng.range(0.08, 0.2))
            let c = SIMD3(rng.range(-0.3, 0.3), rng.range(-0.3, 0.3), rng.range(-0.3, 0.3))
            let tone = rng.range(0.2, 0.6)
            let corners = (0..<8).map { i in c + s * SIMD3(Float(i & 1) - 0.5, Float((i >> 1) & 1) - 0.5, Float((i >> 2) & 1) - 0.5) }
            for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)] {
                t.append(Trace(points: [corners[a], corners[b]], tone: tone, width: 0.6))
            }
            let floors = high ? Int(s.y / 0.04) : 0
            for f in stride(from: 1, to: floors, by: 1) {
                let y = c.y - s.y / 2 + s.y * Float(f) / Float(floors)
                t.append(Trace(points: [SIMD3(c.x - s.x / 2, y, c.z + s.z / 2), SIMD3(c.x + s.x / 2, y, c.z + s.z / 2)], tone: tone, width: 0.5))
            }
        }
        m.parts[.inner] = (t, p, d)
        // Core: (2,5) torus knot plus a few spokes reaching to the inner shell.
        t = []; d = []
        let knot = (0...(high ? 240 : 90)).map { i -> SIMD3<Float> in
            let a = Float(i) / Float(high ? 240 : 90) * 2 * .pi, cr: Float = 0.17 + 0.06 * cos(5 * a)
            return SIMD3(cr * cos(2 * a), 0.06 * sin(5 * a), cr * sin(2 * a))
        }
        t.append(Trace(points: knot, tone: 1, width: high ? 1.1 : 1.0))
        for _ in 0..<(high ? 14 : 4) {
            let th = acos(rng.range(-1, 1)), ph = rng.range(0, 2 * .pi)
            t.append(Trace(points: [sph(0.24, th, ph), sph(rng.range(0.55, 0.95), th, ph)], tone: 0.35, width: 0.5))
        }
        if high { for _ in 0..<70 { d.append(sph(rng.range(0.03, 0.3), acos(rng.range(-1, 1)), rng.range(0, 2 * .pi))) } }
        m.parts[.core] = (t, [], d)
        // Ring: multi-strand broken band, only shown for subagents.
        t = []
        for s in 0..<(high ? 4 : 2) {
            let r: Float = 1.1 + Float(s) * 0.035
            var a = rng.range(0, 2 * .pi); let end = a + 2 * .pi * rng.range(0.55, 0.9)
            while a < end {
                let seg = rng.range(0.15, 0.6)
                let pts = (0...8).map { i -> SIMD3<Float> in let q = a + seg * Float(i) / 8; return SIMD3(r * cos(q), 0, r * sin(q)) }
                t.append(Trace(points: pts, tone: rng.range(0.5, 1), width: 0.9))
                a += seg + rng.range(0.03, 0.14)
            }
        }
        m.parts[.ring] = (t, [], [])
        models[high ? 1 : 0] = m
        return m
    }

    // MARK: Rendering

    /// Depth ramp (back → mid → front). Dark: additive, ending in near-white. Light: deep inks that read on a pale bar.
    static func palette(_ tint: AgentOrbTint, dark: Bool) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        switch (tint, dark) {
        case (.blue, true): return ([0.08, 0.22, 0.78], [0.22, 0.62, 1.0], [0.86, 0.96, 1.0])
        case (.blue, false): return ([0.10, 0.30, 0.75], [0.0, 0.40, 0.92], [0.0, 0.24, 0.66])
        case (.orange, true): return ([0.86, 0.28, 0.04], [1.0, 0.60, 0.14], [1.0, 0.90, 0.70])
        case (.orange, false): return ([0.70, 0.30, 0.02], [0.92, 0.45, 0.0], [0.72, 0.30, 0.0])
        case (.red, true): return ([0.62, 0.04, 0.08], [1.0, 0.22, 0.18], [1.0, 0.80, 0.76])
        case (.red, false): return ([0.62, 0.06, 0.08], [0.85, 0.10, 0.10], [0.62, 0.02, 0.04])
        }
    }

    private static func context(_ pixels: Int) -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func render(_ part: AgentOrbPart, pixels: Int, dark: Bool, tint: AgentOrbTint, angle: Float) -> CGImage? {
        guard let ctx = context(pixels) else { return nil }
        draw(part, in: ctx, pixels: pixels, dark: dark, tint: tint, angle: angle, boost: 1)
        return ctx.makeImage()
    }

    private static func rotation(_ part: AgentOrbPart, angle: Float) -> simd_float3x3 {
        func rx(_ a: Float) -> simd_float3x3 { simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))]) }
        func ry(_ a: Float) -> simd_float3x3 { simd_float3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))]) }
        func rz(_ a: Float) -> simd_float3x3 { simd_float3x3(rows: [SIMD3(cos(a), -sin(a), 0), SIMD3(sin(a), cos(a), 0), SIMD3(0, 0, 1)]) }
        switch part {
        case .outer: return rz(-0.18) * rx(0.32) * ry(angle)
        case .inner: return rz(0.25) * rx(-0.2) * ry(-angle)
        case .core: return rx(0.9) * ry(angle) * rz(0.3)
        case .ring: return rz(-0.45) * rx(1.12) * ry(angle)
        }
    }

    private static func draw(_ part: AgentOrbPart, in ctx: CGContext, pixels: Int, dark: Bool, tint: AgentOrbTint, angle: Float, boost: Float) {
        let high = pixels >= 80
        guard let geo = model(detail: high).parts[part] else { return }
        let rot = rotation(part, angle: angle)
        let size = Float(pixels), radius = size * 0.36, cam: Float = 6
        let weight = max(0.55, size / 200)
        func project(_ v: SIMD3<Float>) -> (CGPoint, Float) {
            let w = rot * v
            let s = cam / (cam - w.z)
            return (CGPoint(x: CGFloat(size / 2 + w.x * s * radius), y: CGFloat(size / 2 + w.y * s * radius)), max(0, min(1, (w.z + 1.1) / 2.2)))
        }
        func color(depth z: Float, tone: Float, alpha: Float) -> CGColor {
            let k = max(0, min(1, z * 0.85 + tone * 0.3))
            let (back, mid, front) = palette(tint, dark: dark)
            let c = k < 0.6 ? simd_mix(back, mid, SIMD3(repeating: k / 0.6)) : simd_mix(mid, front, SIMD3(repeating: (k - 0.6) / 0.4))
            let depthAlpha = 0.16 + 0.84 * pow(z, 1.4)
            return CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(min(1, alpha * depthAlpha * boost * (dark ? 1 : 1.6))))
        }
        let partAlpha: Float = [.outer: 0.95, .inner: 0.62, .core: 1, .ring: 0.85][part] ?? 1
        ctx.setBlendMode(dark ? .plusLighter : .normal)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // Translucent plates first, so traces sit on top of their own glassy slab.
        for plate in geo.plates {
            let pts = plate.points.map(project)
            let z = pts.map(\.1).reduce(0, +) / Float(pts.count)
            ctx.beginPath(); ctx.addLines(between: pts.map(\.0)); ctx.closePath()
            ctx.setFillColor(color(depth: z, tone: plate.tone * 0.6, alpha: (high ? 0.11 : 0.16) * partAlpha))
            ctx.fillPath()
        }
        for trace in geo.traces {
            let pts = trace.points.map(project)
            let z = pts.map(\.1).reduce(0, +) / Float(pts.count)
            let path = CGMutablePath(); path.addLines(between: pts.map(\.0))
            let width = CGFloat(weight * trace.width * (0.65 + 0.6 * z))
            if dark && high {   // soft bloom halo under each trace
                ctx.addPath(path); ctx.setLineWidth(width * 3.2)
                ctx.setStrokeColor(color(depth: z, tone: trace.tone, alpha: 0.12 * partAlpha)); ctx.strokePath()
            }
            ctx.addPath(path); ctx.setLineWidth(width)
            ctx.setStrokeColor(color(depth: z, tone: trace.tone, alpha: (high ? 0.8 : 0.9) * partAlpha)); ctx.strokePath()
        }
        for dot in geo.dots {
            let (p, z) = project(dot)
            let r = CGFloat(weight * (0.5 + 0.9 * z))
            ctx.setFillColor(color(depth: z, tone: 1, alpha: 0.9 * partAlpha))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }
}
