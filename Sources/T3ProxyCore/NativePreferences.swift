import Foundation

public enum NativeMenuBarMode: String, CaseIterable, Sendable {
    case icon, lowest, providers
    public var label: String {
        switch self { case .icon: "Icon only"; case .lowest: "Icon and lowest remaining quota"; case .providers: "Icon and quota per provider" }
    }
    public func title(pools: [QuotaPool]) -> String {
        func percent(_ values: [QuotaPool]) -> String {
            guard let value = values.compactMap(\.remaining).filter(\.isFinite).min() else { return "—" }
            return "\(Int(min(100, max(0, value)).rounded(.down)))%"
        }
        let supported = pools.filter { $0.provider == .claude || $0.provider == .codex }
        switch self {
        case .icon: return ""
        case .lowest: return percent(supported)
        case .providers: return [Provider.claude, .codex].map { p in "\(p.title) \(percent(supported.filter { $0.provider == p }))" }.joined(separator: " · ")
        }
    }
}

/// Carbon modifier bits, independent of AppKit so persistence can be fixture-tested.
public struct NativeHotKey: Codable, Equatable, Sendable {
    public static let command: UInt32 = 1 << 8, shift: UInt32 = 1 << 9, option: UInt32 = 1 << 11, control: UInt32 = 1 << 12
    public static let defaultsKey = "nativePanelHotKey"
    // ⌥⌘P toggles Finder's path bar; include Control to avoid that standard shortcut.
    public static let defaultShortcut = NativeHotKey(keyCode: 35, modifiers: command | option | control, key: "P")
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String
    public init(keyCode: UInt32, modifiers: UInt32, key: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.key = key }
    public var isValid: Bool {
        keyCode <= 127 && modifiers & (Self.command | Self.control | Self.option) != 0 &&
        modifiers & ~(Self.command | Self.shift | Self.option | Self.control) == 0 && !key.isEmpty && key.count <= 16
    }
    public var label: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key.uppercased()
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return .defaultShortcut }
        if data.isEmpty { return nil }
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return .defaultShortcut }
        return value
    }
    public static func save(_ value: Self?, to defaults: UserDefaults = .standard) {
        guard value?.isValid != false else { return }
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: defaultsKey)
    }
}

public func nativeUsageAccountLabel(_ key: String, provider: Provider, accounts: [Account]) -> String {
    guard !key.isEmpty else { return "API key" }
    guard let account = accounts.first(where: { $0.provider == provider && $0.authIndex.map(PlanCache.accountKey) == key }) else { return String(key.emailHidden.prefix(12)) }
    return (account.nickname ?? account.name).emailHidden
}
