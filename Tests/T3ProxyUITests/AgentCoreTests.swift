import AppKit
import QuartzCore
import Testing
import T3ProxyCore
@testable import T3ProxyUI

@Suite @MainActor struct AgentCoreTests {
    @Test func idleAndReduceMotionHaveNoLayerAnimations() {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .idle, attention: false, reduceMotion: false)
        #expect(!animated(core.layer!))
        for state in AgentActivity.allCases {
            core.update(state: state, attention: true, reduceMotion: true)
            for effect in AgentEffect.allCases { core.play(effect, reduceMotion: true) }
            #expect(!animated(core.layer!))
        }
        core.update(state: .working, attention: false, reduceMotion: false)
        #expect(animated(core.layer!))
        core.update(state: .idle, attention: false, reduceMotion: false)
        #expect(!animated(core.layer!))
    }
    @Test func activeEffectsAndInputPassThrough() {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        #expect(core.hitTest(NSPoint(x: 9, y: 9)) == nil)
        for state in [AgentActivity.working, .streaming, .subagent, .waiting] {
            core.update(state: state, attention: false, reduceMotion: false)
            #expect(animated(core.layer!))
        }
        for effect in AgentEffect.allCases {
            core.update(state: .idle, attention: false, reduceMotion: false)
            core.play(effect, reduceMotion: false)
            #expect(animated(core.layer!))
        }
        #expect(AgentCoreView.templateImage().isTemplate)
        #expect(AgentCoreView.templateImage().size == NSSize(width: 18, height: 18))
    }
    private func animated(_ layer: CALayer) -> Bool {
        !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains { animated($0) }
    }

    @Test func menuBarAtlasesKeepStateColorsAndReuseFrames() throws {
        for tint in AgentOrbTint.allCases {
            let start = ContinuousClock.now
            for part in AgentOrbPart.allCases {
                let frames = AgentOrbRenderer.frames(part, pixels: 36, dark: true, tint: tint)
                #expect(frames.count == 72)
                #expect(frames.allSatisfy { $0.width == 36 && $0.height == 36 })
                let first = try #require(frames.first)
                let again = AgentOrbRenderer.frames(part, pixels: 36, dark: true, tint: tint)
                #expect(first === again.first)
                let color = channels(first)
                switch tint {
                case .blue: #expect(color.blue > color.red)
                case .orange: #expect(color.red > color.green && color.green > color.blue)
                case .red: #expect(color.red > color.green && color.red > color.blue)
                }
            }
            print("18pt @2x atlas \(tint): \(start.duration(to: .now))")
        }
    }

    @Test func reducedErrorAndAttentionRestoreTheirBaseColor() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .working, attention: true, reduceMotion: true)
        let orange = try #require(orbImage(core.layer!))
        let orangeColor = channels(orange)
        #expect(orangeColor.red > orangeColor.green && orangeColor.green > orangeColor.blue)
        core.play(.error, reduceMotion: true)
        let redColor = channels(try #require(orbImage(core.layer!)))
        #expect(redColor.red > redColor.green * 2)
        #expect(!animated(core.layer!))
        core.update(state: .working, attention: true, reduceMotion: true)
        #expect(orbImage(core.layer!)?.dataProvider?.data == orange.dataProvider?.data)
        core.update(state: .working, attention: false, reduceMotion: true)
        let blueColor = channels(try #require(orbImage(core.layer!)))
        #expect(blueColor.blue > blueColor.red)
        #expect(!animated(core.layer!))
    }

    private func orbImage(_ layer: CALayer) -> CGImage? {
        if let image = layer.contents { return (image as! CGImage) }
        return (layer.sublayers ?? []).compactMap { orbImage($0) }.first
    }

    private func channels(_ image: CGImage) -> (red: Double, green: Double, blue: Double) {
        let rep = NSBitmapImageRep(cgImage: image)
        var result = (red: 0.0, green: 0.0, blue: 0.0)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                result.red += color.redComponent * color.alphaComponent
                result.green += color.greenComponent * color.alphaComponent
                result.blue += color.blueComponent * color.alphaComponent
            }
        }
        return result
    }
}

extension AgentCoreTests {
    @Test func snoozeUsesDormantSurfacesWithoutSymbolsOrRestartingWork() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.layoutSubtreeIfNeeded()
        core.update(.init(snoozedThreadCount: 2), reduceMotion: false)
        #expect(core.layer?.sublayers?.contains { $0.name == "orb.snooze" } == false)
        let orb = try #require(core.layer?.sublayers?.first)
        let nucleus = try #require(orb.sublayers?.first { $0.name == "orb.nucleus" })
        #expect(nucleus.opacity < 0.3)
        #expect(!animated(core.layer!))
        core.update(.init(state: .working), reduceMotion: false)
        let outer = try #require(orb.sublayers?.first { $0.name == "orb.outer" })
        try freeze(outer, phase: 0.63)
        core.update(.init(state: .working, snoozedThreadCount: 1), reduceMotion: false)
        #expect(abs(try phase(outer) - 0.63) < 0.00001)
        for part in ["inner", "core"] {
            let dormant = try #require(orb.sublayers?.first { $0.name == "orb.\(part)" })
            #expect(dormant.animation(forKey: "spin") == nil)
            let silver = channels(try #require(dormant.contents) as! CGImage)
            #expect(abs(silver.red - silver.blue) < silver.blue * 0.35)
        }
        core.update(.init(state: .subagent, hasWorkingThread: true, snoozedThreadCount: 1, hasWaitingThread: true), reduceMotion: true)
        #expect(!animated(core.layer!))
        core.update(.init(state: .subagent, needsAttention: true, hasWorkingThread: true,
                          snoozedThreadCount: 1, hasWaitingThread: true), reduceMotion: false)
        let inner = try #require(orb.sublayers?.first { $0.name == "orb.inner" })
        let center = try #require(orb.sublayers?.first { $0.name == "orb.core" })
        let ring = try #require(orb.sublayers?.first { $0.name == "orb.ring" })
        #expect(inner.animation(forKey: "spin") != nil && ring.animation(forKey: "spin") != nil)
        #expect(center.animation(forKey: "spin") == nil)
        let attention = channels(try #require(inner.contents) as! CGImage)
        #expect(attention.red > attention.green && attention.green > attention.blue)
        let silver = channels(try #require(center.contents) as! CGImage)
        #expect(abs(silver.red - silver.blue) < silver.blue * 0.35)
    }

    @Test func threeConcurrentStatesKeepThreeSeparateColors() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.appearance = NSAppearance(named: .darkAqua)
        let name = "t3-three-state-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "agentIcon.colors")
        defaults.set("0000FF", forKey: "agentIcon.activeColor")
        defaults.set("00FF00", forKey: "agentIcon.backgroundColor")
        defaults.set("FF9900", forKey: "agentIcon.attentionColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        core.update(.init(state: .subagent, needsAttention: true, hasWorkingThread: true), reduceMotion: true)
        let orb = try #require(core.layer?.sublayers?.first)
        func color(_ part: String) throws -> (red: Double, green: Double, blue: Double) {
            let shell = try #require(orb.sublayers?.first { $0.name == "orb.\(part)" })
            return channels(try #require(shell.contents) as! CGImage)
        }
        let outer = try color("outer"), inner = try color("inner"), ring = try color("ring")
        #expect(outer.blue > outer.red && outer.blue > outer.green)
        #expect(inner.red > inner.green && inner.green > inner.blue)
        #expect(ring.green > ring.red && ring.green > ring.blue)
        let halo = try #require(orb.sublayers?.first { $0.name == "orb.halo" } as? CAGradientLayer)
        let attentionColors = halo.colors as? [CGColor]
        core.play(.error, reduceMotion: true)
        #expect(halo.colors as? [CGColor] == attentionColors)
        #expect(!animated(core.layer!))
    }

    @Test func errorEntryAndExitKeepEveryShellPhaseWithLocalClocks() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.layer?.speed = 0.7; core.layer?.beginTime = 23; core.layer?.timeOffset = 12
        core.update(state: .subagent, attention: true, reduceMotion: false)
        let shells = spinningLayers(core.layer!)
        for shell in shells { try freeze(shell, phase: 0.81) }
        core.play(.error, reduceMotion: false)
        for shell in shells { #expect(abs(try phase(shell) - 0.81) < 0.00001) }
        core.finishEffect()
        for shell in shells { #expect(abs(try phase(shell) - 0.81) < 0.00001) }
    }

    @Test func mixedStatesUseIndependentSurfacesAndConfiguredColors() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.appearance = NSAppearance(named: .darkAqua)
        let name = "t3-mixed-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "agentIcon.colors")
        defaults.set("00FF00", forKey: "agentIcon.activeColor")
        defaults.set("FF00FF", forKey: "agentIcon.attentionColor")
        defaults.set("FF0000", forKey: "agentIcon.errorColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        let activity = AgentActivityUpdate(state: .subagent, needsAttention: true, hasWorkingThread: true, hasDelegatedWork: true)
        core.update(activity, reduceMotion: true)
        let orb = try #require(core.layer?.sublayers?.first)
        func surface(_ name: String) throws -> CGImage {
            let layer = try #require(orb.sublayers?.first { $0.name == "orb.\(name)" })
            return try #require(layer.contents) as! CGImage
        }
        let outer = try surface("outer"), inner = try surface("inner")
        let workColor = channels(outer), attentionColor = channels(inner)
        #expect(workColor.green > workColor.red && workColor.green > workColor.blue)
        #expect(attentionColor.red > attentionColor.green && attentionColor.blue > attentionColor.green)
        #expect(orb.sublayers?.last?.opacity == 1)
        core.play(.error, reduceMotion: true)
        #expect(try surface("outer").dataProvider?.data == outer.dataProvider?.data)
        let errorColor = channels(try surface("inner"))
        #expect(errorColor.red > errorColor.green && errorColor.red > errorColor.blue)
        core.finishEffect()
        #expect(try surface("inner").dataProvider?.data == inner.dataProvider?.data)
        #expect(!animated(core.layer!))
    }

    @Test func idleAndResumeRetainPoseAndAttentionDoesNotCancelReport() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .working, attention: false, reduceMotion: false)
        let shells = spinningLayers(core.layer!)
        for shell in shells { try freeze(shell, phase: 0.29) }
        core.play(.report, reduceMotion: false)
        core.update(state: .working, attention: true, reduceMotion: false)
        let orb = try #require(core.layer?.sublayers?.first)
        let nucleus = try #require(orb.sublayers?.first { $0.name == "orb.nucleus" })
        #expect(nucleus.animation(forKey: "bloom") != nil)
        core.finishEffect()
        core.update(state: .idle, attention: false, reduceMotion: false)
        #expect(!animated(core.layer!))
        core.update(state: .working, attention: false, reduceMotion: false)
        for shell in shells { #expect(abs(try phase(shell) - 0.29) < 0.00001) }
    }

    @Test func activityAndAttentionUpdatesKeepNonzeroShellPhases() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .working, attention: false, reduceMotion: false)
        let shells = spinningLayers(core.layer!)
        #expect(shells.count >= 3)
        for shell in shells { try freeze(shell, phase: 0.37) }
        for (state, attention) in [(AgentActivity.working, false), (.subagent, false),
                                   (.subagent, true), (.waiting, true), (.streaming, false)] {
            core.update(state: state, attention: attention, reduceMotion: false)
            for shell in shells {
                #expect(abs(try phase(shell) - 0.37) < 0.00001)
            }
        }
    }

    @Test func reportCleanupDoesNotRestartBaseRotation() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .subagent, attention: false, reduceMotion: false)
        let shells = spinningLayers(core.layer!)
        for shell in shells { try freeze(shell, phase: 0.63) }
        core.play(.report, reduceMotion: false)
        core.update(state: .subagent, attention: false, reduceMotion: false)
        for shell in shells { #expect(abs(try phase(shell) - 0.63) < 0.00001) }
    }

    @Test func subagentRingFadesInsteadOfAppearingInOneFrame() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.update(state: .working, attention: false, reduceMotion: false)
        core.update(state: .subagent, attention: false, reduceMotion: false)
        let orb = try #require(core.layer?.sublayers?.first)
        let ring = try #require(orb.sublayers?.last)
        #expect(!ring.isHidden)
        #expect(ring.animation(forKey: "visibility")?.duration ?? 0 > 0)
        core.update(state: .waiting, attention: true, reduceMotion: true)
        #expect(!animated(core.layer!))
    }

    private func spinningLayers(_ root: CALayer) -> [CALayer] {
        (root.animation(forKey: "spin") == nil ? [] : [root])
            + (root.sublayers ?? []).flatMap(spinningLayers)
    }

    private func freeze(_ layer: CALayer, phase: Double) throws {
        let animation = try #require(layer.animation(forKey: "spin")?.copy() as? CAAnimation)
        layer.speed = 0; layer.timeOffset = 1000
        animation.beginTime = 1000 - phase * animation.duration
        layer.add(animation, forKey: "spin")
    }

    private func phase(_ layer: CALayer) throws -> Double {
        let animation = try #require(layer.animation(forKey: "spin"))
        let value = (layer.convertTime(CACurrentMediaTime(), from: nil) - animation.beginTime) / animation.duration
        return value - floor(value)
    }
}
