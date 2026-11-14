import Foundation
import Security
import Darwin

public enum ServiceProvider: String, Codable, CaseIterable, Sendable { case remoteMCP, stdio }
public enum MCPAuthentication: String, Codable, CaseIterable, Sendable { case none, bearer, oauth }
public enum MCPClientTarget: String, Codable, CaseIterable, Sendable { case codex, claude }
public struct ServiceConnection: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var provider: ServiceProvider
    public var name: String
    public var identity: String?
    public var endpoint: String?
    public var enabled: Bool
    public var authentication: MCPAuthentication
    public var command: String?
    public var arguments: [String]
    public var environmentNames: [String]
    public var targets: [MCPClientTarget]
    public var serverName: String { "t3_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public init(id: UUID = UUID(), provider: ServiceProvider, name: String, identity: String? = nil, endpoint: String? = nil, enabled: Bool = true,
                authentication: MCPAuthentication = .none, command: String? = nil, arguments: [String] = [], environmentNames: [String] = [], targets: [MCPClientTarget] = [.codex, .claude]) {
        self.id = id; self.provider = provider; self.name = name; self.identity = identity; self.endpoint = endpoint; self.enabled = enabled
        self.authentication = authentication; self.command = command; self.arguments = arguments; self.environmentNames = environmentNames; self.targets = targets
    }
    public static func validEndpoint(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host))
    }
}

public enum ServiceConnectionError: Error, LocalizedError {
    case storage, authentication, invalidArguments, unsupported, network, responseTooLarge, remote(Int), busy, cancelled
    public var errorDescription: String? {
        switch self {
        case .storage: "Connection storage is unavailable."
        case .authentication: "Service authorization is missing or expired. Reconnect this account in T3 Proxy."
        case .invalidArguments: "Choose a valid MCP connection and supply the required arguments."
        case .unsupported: "This endpoint or operation is unsupported. Use a supported MCP endpoint or executable."
        case .network: "The service did not return a valid response."
        case .responseTooLarge: "The service response exceeds the 12 MB transfer limit."
        case .remote(let status): "The service returned HTTP \(status)."
        case .busy: "Another connection operation is in progress. Try again after it finishes."
        case .cancelled: "Authorization was cancelled or timed out."
        }
    }
}

/// Metadata only. Credentials are separate Keychain items, keyed by an immutable connection UUID.
public struct ServiceConnectionStore: Sendable {
    public let directory: URL
    public static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/T3 Proxy/Connectors") }
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
    public func load() throws -> [ServiceConnection] {
        let url = directory.appendingPathComponent("connections.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ServiceConnection].self, from: Data(contentsOf: url))
    }
    public func save(_ connection: ServiceConnection) throws {
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              connection.provider != .remoteMCP || ServiceConnection.validEndpoint(connection.endpoint ?? ""),
              connection.provider != .stdio || (connection.command?.hasPrefix("/") == true && connection.authentication != .oauth),
              connection.environmentNames.allSatisfy({ $0.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil }),
              !connection.targets.isEmpty else { throw ServiceConnectionError.invalidArguments }
        try change { values in values.removeAll { $0.id == connection.id }; values.append(connection) }
    }
    public func remove(_ id: UUID) throws { try change { $0.removeAll { $0.id == id } } }
    private func change(_ update: (inout [ServiceConnection]) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServiceConnectionError.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ServiceConnectionError.busy }
        defer { flock(fd, LOCK_UN) }
        var values = try load(); update(&values)
        let data = try JSONEncoder().encode(values)
        let url = directory.appendingPathComponent("connections.json")
        try ConnectorFiles.write(data, to: url)
    }
}

public struct ConnectorCredential: Codable, Sendable {
    public var accessToken: String
    public var environment: [String: String]
    public init(accessToken: String = "", environment: [String: String] = [:]) { self.accessToken = accessToken; self.environment = environment }
}

public struct ConnectorCredentialStore: Sendable {
    private let account: String
    public init(account: String) { self.account = account }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.t3proxy.connectors", kSecAttrAccount as String: account] }
    public func load() throws -> ConnectorCredential? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ServiceConnectionError.authentication }
        return try JSONDecoder().decode(ConnectorCredential.self, from: data)
    }
    public func save(_ credential: ConnectorCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ServiceConnectionError.storage }
        var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ServiceConnectionError.storage }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceConnectionError.storage }
    }
}

