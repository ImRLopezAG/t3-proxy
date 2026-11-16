import AppKit

enum AgentIconStyle: String { case orb, classic }
enum AgentIconColorMode: String { case menuBar, custom }

struct AgentIconColor: Equatable, Hashable {
    let hex: String
    init(hex: String) {
        let value = hex.uppercased()
        self.hex = value.count == 6 && value.allSatisfy { $0.isASCII && $0.isHexDigit } ? value : "389EFF"
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemBlue
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        hex = String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
    var rgb: SIMD3<Float> {
        let value = UInt32(hex, radix: 16)!
        return SIMD3(Float(value >> 16 & 255), Float(value >> 8 & 255), Float(value & 255)) / 255
    }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}

struct AgentIconPreferences: Equatable {
    var style: AgentIconStyle
    var colorMode: AgentIconColorMode
    var activeColor: AgentIconColor
    var backgroundColor: AgentIconColor
    var attentionColor: AgentIconColor
    var errorColor: AgentIconColor

    init(defaults: UserDefaults = .standard) {
        style = AgentIconStyle(rawValue: defaults.string(forKey: "agentIcon.style") ?? "") ?? .orb
        colorMode = AgentIconColorMode(rawValue: defaults.string(forKey: "agentIcon.colors") ?? "") ?? .menuBar
        activeColor = AgentIconColor(hex: defaults.string(forKey: "agentIcon.activeColor") ?? "389EFF")
        backgroundColor = AgentIconColor(hex: defaults.string(forKey: "agentIcon.backgroundColor") ?? "A57BFF")
        attentionColor = AgentIconColor(hex: defaults.string(forKey: "agentIcon.attentionColor") ?? "FF9924")
        errorColor = AgentIconColor(hex: defaults.string(forKey: "agentIcon.errorColor") ?? "FF382E")
    }
}
