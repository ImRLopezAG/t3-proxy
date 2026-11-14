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
