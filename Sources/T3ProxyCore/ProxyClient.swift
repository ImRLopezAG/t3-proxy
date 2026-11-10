import Foundation

public enum ProxyError: Error, Equatable { case unreachable, unauthorized, http(Int), incompatible }

/// The hub's port setting. The host is always 127.0.0.1; only the port is configurable.
public enum HubPort {
    public static let key = "hub.port"
    public static let defaultPort = 8317
    public static let range = 1024...65535
    public static func isValid(_ p: Int) -> Bool { range.contains(p) }
    /// Strict parse of user input: digits only, in range.
    public static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 5, t.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(t), isValid(p) else { return nil }
        return p
    }
    /// The stored port, or 8317 when unset or invalid.
    public static func current(_ d: UserDefaults = .standard) -> Int {
        guard let v = d.object(forKey: key) else { return defaultPort }
        let p = (v as? Int) ?? (v as? String).flatMap(parse) ?? defaultPort
        return isValid(p) ? p : defaultPort
    }
    /// Saves a valid port (the default removes the setting). Returns false and stores nothing for an invalid one.
    @discardableResult
    public static func save(_ p: Int, _ d: UserDefaults = .standard) -> Bool {
        guard isValid(p) else { return false }
        if p == defaultPort { d.removeObject(forKey: key) } else { d.set(p, forKey: key) }
        return true
    }
}

public struct ProxyEndpoint: Sendable, Equatable {
    public let port: Int
    /// Out-of-range ports fall back to 8317.
    public init(port: Int = HubPort.defaultPort) { self.port = HubPort.isValid(port) ? port : HubPort.defaultPort }
    /// The endpoint from the user's setting (Settings → Connection).
    public static func configured(_ d: UserDefaults = .standard) -> ProxyEndpoint { .init(port: HubPort.current(d)) }
    /// Always loopback; the management key must never leave this machine.
    public var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var label: String { "127.0.0.1:\(port)" }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Ephemeral, no proxies, no cache or cookies, redirects refused.
func loopbackSession(timeout: TimeInterval, protocolClasses: [AnyClass]?) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = timeout
    c.connectionProxyDictionary = [:]
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    if let protocolClasses { c.protocolClasses = protocolClasses }
    return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
}

/// Read-only. Exposes only `GET /` and `GET /v0/management/auth-files`.
/// `usage-queue` is deliberately absent: reading it pops records for other consumers.
public struct ProxyClient: Sendable {
    public let endpoint: ProxyEndpoint
    let session: URLSession
    /// Shared with ManagementClient by Monitor.
    public var gate = AuthGate()

    public init(endpoint: ProxyEndpoint = .configured(), protocolClasses: [AnyClass]? = nil) {
        self.endpoint = endpoint
        session = loopbackSession(timeout: 8, protocolClasses: protocolClasses)
    }

    /// Unauthenticated root route: does not touch the failed-attempt counter.
    public func health() async -> Bool {
        guard let (data, resp) = try? await session.data(from: endpoint.base),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("CLI Proxy API")
    }

    public func accounts(key: String) async throws -> [Account] {
        guard gate.permits(key) else { throw ManagementError.locked }
        var r = URLRequest(url: endpoint.base.appendingPathComponent("v0/management/auth-files"))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw ProxyError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard code == 200 else { throw ProxyError.http(code) }
        guard let env = try? JSONDecoder().decode(AuthFilesEnvelope.self, from: data) else { throw ProxyError.incompatible }
        return env.files.map(Account.init)
    }
}
