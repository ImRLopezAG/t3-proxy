import Foundation
import CryptoKit
import Security

public struct ClientKeyReference: Sendable, Equatable, Identifiable {
    public var id: String { reference }
    public let reference: String
    public let masked: String
}
public struct RoutingConfig: Sendable, Equatable {
    public let revision: String
    public let aliases: [String: [ModelAlias]]
    public let excluded: [String: [String]]
    public let clientKeys: [ClientKeyReference]
}
public enum ClientKeyChange: Sendable {
    case add(String)
    case remove(reference: String)
}

/// Opaque, process-local HMAC references; existing secrets never leave this file's projections.
private enum ClientReferences {
    static let secret = SymmetricKey(size: .bits256)
    static func ref(_ index: Int, _ key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("client:\(index):\(key)".utf8), using: secret)
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(index):\(mac)"
    }
}

public enum ClientKeyGenerator {
    /// 256 random bits, hex encoded: no modulo bias and safe in a shell/config value.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RoutingError.randomFailed }
        return "sk-" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct RoutingDocument {
    let revision: String
    let aliases: [String: [ModelAlias]]
    let excluded: [String: [String]]
    let keys: [String]
    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyError.incompatible }
        revision = ConfigSummary.revision(data)
        if let accessValue = root["access"], !(accessValue is NSNull) {
            guard let access = accessValue as? [String: Any] else { throw ProxyError.incompatible }
            if let list = access["api-keys"], !(list is NSNull) { guard let strings = list as? [String] else { throw ProxyError.incompatible }; keys = strings }
            else { keys = [] }
        } else if let list = root["api-keys"] as? [String] { keys = list }
        else { keys = [] }
        guard keys.count <= 200 else { throw RoutingError.tooManyKeys }
        var a: [String: [ModelAlias]] = [:], e: [String: [String]] = [:]
        if let value = root["oauth"], !(value is NSNull) {
            guard let oauth = value as? [String: Any] else { throw ProxyError.incompatible }
            if let value = oauth["model-alias"], !(value is NSNull) {
                guard let groups = value as? [String: Any] else { throw ProxyError.incompatible }
                for (p, value) in groups {
                    try RoutingValidation.provider(p)
                    let data = try JSONSerialization.data(withJSONObject: value)
                    let list = try JSONDecoder().decode([ModelAlias].self, from: data)
                    a[p] = try RoutingValidation.aliases(list)
                }
            }
            if let value = oauth["excluded-models"], !(value is NSNull) {
                guard let groups = value as? [String: [String]] else { throw ProxyError.incompatible }
                for (p, list) in groups { try RoutingValidation.provider(p); e[p] = try RoutingValidation.modelNames(list) }
            }
        }
        aliases = a; excluded = e
    }
    var projection: RoutingConfig {
        RoutingConfig(revision: revision, aliases: aliases, excluded: excluded,
                      clientKeys: keys.enumerated().filter { !$0.element.isEmpty }.map {
            ClientKeyReference(reference: ClientReferences.ref($0.offset, $0.element), masked: ConfigMask.key($0.element))
        })
    }
}

extension ManagementClient {
    /// Preserve transport certainty for guard recovery; timeouts/connection loss remain ambiguous.
    public func resumeGuardCredential(name: String, key: String) async throws {
        guard gate.permits(key) else { throw ManagementError.locked }
        try checkName(name)
        var request = URLRequest(url: endpoint.base.appendingPathComponent("v8/management/credentials/status"))
        request.timeoutInterval = 30
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "disabled": false])
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(error.code) {
            throw GuardTransportError.offline
        } catch { throw ProxyError.unreachable }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard (200..<300).contains(code) else { throw ProxyError.http(code) }
    }
    public func routingConfig(key: String) async throws -> RoutingConfig {
        try RoutingDocument(await send("GET", "v8/management/config", nil, key: key)).projection
    }

    /// Exactly two writable OAuth paths, never a caller-supplied dotted path. Re-read, check the
    /// revision, and send only the changed provider leaves (siblings survive the merge patch).
    public func applyModelRouting(provider: String, aliases: [ModelAlias], excluded: [String], revision: String, key: String) async throws {
        try RoutingValidation.provider(provider)
        let aliases = try RoutingValidation.aliases(aliases), excluded = try RoutingValidation.modelNames(excluded)
        let current = try RoutingDocument(await send("GET", "v8/management/config", nil, key: key))
        guard current.revision == revision else { throw ConfigError.stale }
        var oauth: [String: any Sendable] = [:]
        if (current.aliases[provider] ?? []) != aliases {
            let list: [[String: any Sendable]] = aliases.map { a in
                var row: [String: any Sendable] = ["name": a.name, "alias": a.alias]
                if a.fork == true { row["fork"] = true }
                return row
            }
            oauth[RoutingConfigField.aliases.rawValue] = [provider: list]
        }
        if (current.excluded[provider] ?? []) != excluded { oauth[RoutingConfigField.excluded.rawValue] = [provider: excluded] }
        guard !oauth.isEmpty else { throw ConfigError.nothingChanged }
        try await send("PATCH", "v8/management/config", ["oauth": oauth], key: key)
    }

    /// Resolve masked references against the fresh config, never against masked strings or cached
    /// plaintext. Both the entire config revision and the individual reference must still match.
    public func changeClientKey(_ change: ClientKeyChange, revision: String, key: String) async throws {
        if case .add(let value) = change { try RoutingValidation.clientKey(value) }
        let current = try RoutingDocument(await send("GET", "v8/management/config", nil, key: key))
        guard current.revision == revision else { throw ConfigError.stale }
        var list = current.keys
        switch change {
        case .add(let value):
            guard list.count < 200 else { throw RoutingError.tooManyKeys }
            guard !list.contains(value) else { throw RoutingError.invalidKey }
            list.append(value)
        case .remove(let ref):
            guard let i = list.indices.first(where: { ClientReferences.ref($0, list[$0]) == ref }), !list[i].isEmpty else { throw RoutingError.staleReference }
            list.remove(at: i)
        }
        try await send("PATCH", "v8/management/config", ["access": ["api-keys": list]], key: key)
    }

    public func applyPriority(_ change: PriorityChange, key: String) async throws {
        guard let current = try await credentials(key: key).first(where: { $0.name == change.credential.name }),
              current.priority == change.credential.priority, current.authIndex == change.credential.authIndex,
              current.updatedMarker == change.credential.updatedMarker else { throw RoutingError.staleCredential }
        try await setPriority(change.priority, name: current.name, key: key)
    }
}
