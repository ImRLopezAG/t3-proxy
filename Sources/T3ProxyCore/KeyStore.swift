import Foundation
import Security

public protocol KeyStore: Sendable {
    func load() -> String?
    func save(_ key: String) -> Bool
    func remove()
}

/// Stores only T3 Proxy's own copy. Never reads other apps' items or config files.
///
/// The Keychain is read once per launch and the result is kept in memory: every read can block
/// the calling thread on a macOS access prompt (each new ad-hoc build is a "new app" to the
/// Keychain), and the Monitor asks for the key on every request.
public struct KeychainKeyStore: KeyStore {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var loaded = false
        var value: String?
    }
    private static let cache = Cache()

    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "dev.t3proxy.management-key",
                                       kSecAttrAccount as String: "cliproxyapi"] }
    public init() {}

    public func load() -> String? {
        let c = Self.cache
        c.lock.lock(); defer { c.lock.unlock() }
        if c.loaded { return c.value }
        var q = base; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        c.value = status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        // Denied prompts are cached too (no prompt every refresh); saving a key in Settings replaces it.
        c.loaded = true
        return c.value
    }

    public func save(_ key: String) -> Bool {
        let c = Self.cache
        c.lock.lock(); defer { c.lock.unlock() }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        // The old item is already gone either way; stay resolved so nothing re-reads (and re-prompts).
        c.loaded = true; c.value = ok ? key : nil
        return ok
    }

    public func remove() {
        let c = Self.cache
        c.lock.lock(); defer { c.lock.unlock() }
        SecItemDelete(base as CFDictionary)
        c.loaded = true; c.value = nil
    }
}
