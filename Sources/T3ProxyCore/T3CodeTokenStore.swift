import Foundation
import Security

/// A separate Keychain item from the CLIProxyAPI management key. Reads, including denial, are cached.
public struct T3CodeTokenStore: KeyStore {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var loaded = false
        var token: String?
    }
    private static let cache = Cache()
    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.t3proxy.t3code-session",
         kSecAttrAccount as String: "t3code"]
    }
    public init() {}
    public func load() -> String? {
        let cache = Self.cache
        cache.lock.lock(); defer { cache.lock.unlock() }
        if cache.loaded { return cache.token }
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        cache.token = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache.loaded = true
        return cache.token
    }
    public func save(_ key: String) -> Bool {
        let cache = Self.cache
        cache.lock.lock(); defer { cache.lock.unlock() }
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        cache.loaded = true; cache.token = ok ? key : nil
        return ok
    }
    /// Removes the local copy only. Revoke the CLI session separately before forgetting its ID.
    public func remove() {
        let cache = Self.cache
        cache.lock.lock(); defer { cache.lock.unlock() }
        SecItemDelete(base as CFDictionary)
        cache.loaded = true; cache.token = nil
    }
}

public struct T3CodeIssuedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sessionID: String
    public let token: String
    public let expiresAt: Date
    public var description: String { "T3 Code session (redacted)" }
    public var debugDescription: String { description }
}

/// Captures stdout in memory and discards stderr. Never puts a token in argv, a file, or an error.
/// Uses --json so the caller can retain the nonsecret session ID needed for explicit revocation.
public struct T3CodeTokenCLI: Sendable {
    public let executable: URL
    public init(executable: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bin/t3")) {
        self.executable = executable
    }
    public func issue(ttl: String = "30d") async throws -> T3CodeIssuedSession {
        let executable = executable
        return try await Task.detached {
            let data = try Self.run(executable, arguments: ["auth", "session", "issue",
                "--scope", "orchestration:read", "--scope", "orchestration:operate",
                "--label", "T3 Proxy", "--ttl", ttl, "--json"])
            return try Self.parseIssued(data)
        }.value
    }
    public func revoke(sessionID: String) async throws {
        guard !sessionID.isEmpty, !sessionID.hasPrefix("-"), !sessionID.contains(where: \.isWhitespace) else {
            throw T3CodeError.cliFailed
        }
        let executable = executable
        try await Task.detached {
            _ = try Self.run(executable, arguments: ["auth", "session", "revoke", sessionID])
        }.value
    }
    static func parseIssued(_ data: Data) throws -> T3CodeIssuedSession {
        struct Issued: Decodable { let sessionId: String; let token: String; let expiresAt: Date; let scopes: [String] }
        guard let value = try? T3CodeWire.decode(Issued.self, from: data), !value.sessionId.isEmpty,
              !value.token.isEmpty, !value.token.contains(where: \.isWhitespace),
              Set(value.scopes) == ["orchestration:read", "orchestration:operate"] else { throw T3CodeError.cliFailed }
        return .init(sessionID: value.sessionId, token: value.token, expiresAt: value.expiresAt)
    }
    private static func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw T3CodeError.cliFailed }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw T3CodeError.cliFailed }
        return data
    }
}
