import AppKit
import Testing
import T3ProxyCore
@testable import T3ProxyUI

@Suite @MainActor struct AgentIconPreferencesTests {
    @Test func defaultsAndInvalidPreferencesKeepThemeMatching() throws {
        let defaults = try #require(UserDefaults(suiteName: "t3-icon-test-\(UUID())"))
        defaults.set("unrecognized", forKey: "agentIcon.style")
        defaults.set("unrecognized", forKey: "agentIcon.colors")
        defaults.set("invalid", forKey: "agentIcon.activeColor")
        let preferences = AgentIconPreferences(defaults: defaults)
        #expect(preferences.style == .orb)
        #expect(preferences.colorMode == .menuBar)
        #expect(preferences.activeColor == AgentIconColor(hex: "389EFF"))
    }

    @Test func classicChoiceAndIndependentColorsPersist() throws {
        let name = "t3-icon-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("classic", forKey: "agentIcon.style")
        defaults.set("custom", forKey: "agentIcon.colors")
        defaults.set("B64DFF", forKey: "agentIcon.activeColor")
        defaults.set("EDAE25", forKey: "agentIcon.attentionColor")
        defaults.set("FF375F", forKey: "agentIcon.errorColor")
        let preferences = AgentIconPreferences(defaults: defaults)
        #expect(preferences.style == .classic)
        #expect(preferences.colorMode == .custom)
        #expect(preferences.activeColor.hex == "B64DFF")
        #expect(preferences.attentionColor.hex == "EDAE25")
        #expect(preferences.errorColor.hex == "FF375F")
        #expect(AgentIconPreferences(defaults: defaults) == preferences)
        #expect(AgentStatusIcon.classicImage(attention: false).isTemplate)
        #expect(AgentStatusIcon.classicImage(attention: false).size == NSSize(width: 22, height: 18))
    }

    @Test func customPaletteChangesRealOrbPixelsAndThemeIgnoresIt() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        core.appearance = NSAppearance(named: .darkAqua)
        let name = "t3-icon-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "agentIcon.colors")
        defaults.set("00FF00", forKey: "agentIcon.activeColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        core.update(state: .working, attention: false, reduceMotion: true)
        let green = try #require(firstImage(core.layer!))
        defaults.set("FF00FF", forKey: "agentIcon.activeColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        let purple = try #require(firstImage(core.layer!))
        #expect(green.dataProvider?.data != purple.dataProvider?.data)
        defaults.set("menuBar", forKey: "agentIcon.colors")
        core.configure(AgentIconPreferences(defaults: defaults))
        let theme = try #require(firstImage(core.layer!))
        defaults.set("0000FF", forKey: "agentIcon.activeColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        #expect(theme.dataProvider?.data == firstImage(core.layer!)?.dataProvider?.data)
        #expect(!hasAnimations(core.layer!))
    }

    @Test func appearanceAndSemanticColorsUseDistinctPixels() throws {
        let core = AgentCoreView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        let name = "t3-icon-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        core.configure(AgentIconPreferences(defaults: defaults))
        core.appearance = NSAppearance(named: .darkAqua)
        core.update(state: .working, attention: false, reduceMotion: true)
        let dark = try #require(firstImage(core.layer!))
        core.appearance = NSAppearance(named: .aqua)
        core.update(state: .working, attention: false, reduceMotion: true)
        #expect(dark.dataProvider?.data != firstImage(core.layer!)?.dataProvider?.data)

        defaults.set("custom", forKey: "agentIcon.colors")
        defaults.set("00FF00", forKey: "agentIcon.activeColor")
        defaults.set("FF00FF", forKey: "agentIcon.attentionColor")
        defaults.set("00FFFF", forKey: "agentIcon.errorColor")
        core.configure(AgentIconPreferences(defaults: defaults))
        core.update(state: .working, attention: false, reduceMotion: true)
        let active = try #require(firstImage(core.layer!))
        core.update(state: .working, attention: true, reduceMotion: true)
        let attention = try #require(firstImage(core.layer!))
        core.play(.error, reduceMotion: true)
        let error = try #require(firstImage(core.layer!))
        #expect(active.dataProvider?.data != attention.dataProvider?.data)
        #expect(error.dataProvider?.data != attention.dataProvider?.data)
        #expect(error.dataProvider?.data != active.dataProvider?.data)
        #expect(!hasAnimations(core.layer!))
    }

    @Test func defaultsNotificationSwitchesExistingStatusButton() async throws {
        let name = "t3-icon-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        let icon = AgentStatusIcon(button: button, defaults: defaults)
        icon.apply(AgentActivityUpdate(state: .working))
        let view = try #require(button.subviews.compactMap { $0 as? AgentCoreView }.first)
        #expect(!view.isHidden)

        defaults.set("classic", forKey: "agentIcon.style")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        // Drain the main queue delivery used by the production observer, without a timed sleep.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(view.isHidden)
        #expect(button.image?.size == NSSize(width: 22, height: 18))
        #expect(button.image?.isTemplate == true)
        #expect(!hasAnimations(view.layer!))

        defaults.set("orb", forKey: "agentIcon.style")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!view.isHidden)
        #expect(button.image?.size == NSSize(width: 18, height: 18))
    }

    @Test func arbitraryCustomColorsEvictOldAtlasesWithinMemoryBudget() throws {
        let original = try #require(AgentOrbRenderer.frames(.outer, pixels: 72, dark: true,
                                                          color: AgentIconColor(hex: "000007")).first)
        for value in 0..<50 {
            let color = AgentIconColor(hex: String(format: "%02X3F7F", value))
            #expect(AgentOrbRenderer.frames(.outer, pixels: 72, dark: true, color: color).count == 72)
            #expect(AgentOrbRenderer.cacheBytes <= 64 * 1024 * 1024)
        }
        let rebuilt = try #require(AgentOrbRenderer.frames(.outer, pixels: 72, dark: true,
                                                         color: AgentIconColor(hex: "000007")).first)
        #expect(original !== rebuilt)
        #expect(original.dataProvider?.data == rebuilt.dataProvider?.data)
    }

    private func firstImage(_ layer: CALayer) -> CGImage? {
        if let image = layer.contents { return (image as! CGImage) }
        return (layer.sublayers ?? []).compactMap { firstImage($0) }.first
    }
    private func hasAnimations(_ layer: CALayer) -> Bool {
        !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains { hasAnimations($0) }
    }
}
