import Foundation

public enum OAuthMethod: Sendable { case browser, deviceCode, importFile }

/// Proxy Deck's cards, in dashboard order. Hosts are exact, never wildcard matches.
public enum OAuthProvider: String, Sendable, CaseIterable, Identifiable {
    case claude, codex, antigravity, xai, devin, kimi
    case kimiAI = "kimi-ai"
    case meta, vertex
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: "Claude"; case .codex: "Codex"; case .antigravity: "Antigravity"
        case .xai: "xAI"; case .devin: "Devin"; case .kimi, .kimiAI: "Kimi"
        case .meta: "Muse (Meta)"; case .vertex: "Vertex AI"
        }
    }
    public var method: OAuthMethod {
        switch self {
        case .kimi, .kimiAI, .meta: .deviceCode
        case .vertex: .importFile
        default: .browser
        }
    }
    public var subtitle: String {
        switch self {
        case .kimi: "kimi.com · Device code"
        case .kimiAI: "kimi.ai · Device code"
        case .meta: "Device code"
        case .vertex: "Service-account JSON"
        default: "Browser sign-in"
        }
    }
    public var markName: String { self == .kimiAI ? "kimi" : rawValue }
    /// Exact hosts (no subdomain wildcard) the hub's authorization URL may point at.
    public var authHosts: Set<String> {
        switch self {
        case .claude: ["claude.ai", "console.anthropic.com"]
        case .codex: ["auth.openai.com"]
        case .antigravity: ["accounts.google.com"]
        // CLIProxyAPI v8.0.45: xai_auth_test.go's verification URI; Devin's DefaultAppBaseURL.
        case .xai: ["accounts.x.ai"]
        case .devin: ["app.devin.ai"]
        case .kimi: ["auth.kimi.com"]
        case .kimiAI: ["auth.kimi.ai"]
        case .meta: ["auth.meta.com"]
        case .vertex: []
        }
    }
    /// The word the hub's v0 oauth-callback expects.
    var callbackName: String { self == .claude ? "anthropic" : rawValue }
}

public enum OAuthError: Error, Equatable {
    case invalidState
    /// The hub's authorization URL is not https on an expected host. It is never opened.
    case untrustedURL
    case invalidRedirect
    case invalidDeviceCode, invalidImport, invalidLocation, confirmationRequired, unsupportedMethod
}

/// A started hub session. `url` passed `OAuthRules.authURL`.
public struct OAuthSession: Sendable, Equatable {
    public var provider: OAuthProvider
    public var url: URL
    public var state: String
    public var expiresIn: TimeInterval?
    public var userCode: String? = nil
    /// Poll the hub's session status, never the provider's token endpoint.
    public var pollInterval: TimeInterval = 2
}

public enum OAuthStatus: Sendable, Equatable {
    case wait, ok
    case error(String)
}

public enum OAuthRules {
    public static let importMaxBytes = 256_000
    private static let stateRE = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9_-]{8,128}\z"#)
    private static let versionRE = try! NSRegularExpression(pattern: #"^v?\d{1,4}\.\d{1,4}\.\d{1,4}([-+][A-Za-z0-9.-]{1,32})?$"#)
    /// Hub messages short and specific enough to show as-is (Proxy Deck's OAUTH_ERRORS).
    private static let shownErrors = [#"^session cancell?ed$"#, #"^unknown or expired state$"#,
                                      #"^(authorization|authentication) (timed out|failed|denied)$"#,
                                      #"^access denied$"#, #"^state mismatch$"#]

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Proxy Deck's STATE.
    public static func isValidState(_ s: String) -> Bool { matches(stateRE, s) }
    public static func isValidVersion(_ s: String) -> Bool { matches(versionRE, s) }

    public static func isValidUserCode(_ s: String) -> Bool {
        s.range(of: #"\A[A-Za-z0-9-]{4,32}\z"#, options: .regularExpression) != nil
    }

    public static func validateImport(_ data: Data, name: String) throws {
        guard ManagementRules.isValidFileName(name), data.count <= importMaxBytes,
              String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw OAuthError.invalidImport }
    }

    public static func isValidLocation(_ location: String) -> Bool {
        location.isEmpty || location.range(of: #"\A[a-z0-9-]{1,40}\z"#, options: .regularExpression) != nil
    }

    /// https only, host exactly in the provider's allowlist, default port, no user info.
    public static func authURL(_ raw: String, for p: OAuthProvider) -> URL? {
        guard raw.utf16.count <= 8192, let c = URLComponents(string: raw), let url = c.url,
              c.scheme?.lowercased() == "https", let host = c.host?.lowercased(),
              p.authHosts.contains(host), c.port == nil || c.port == 443,
              c.user == nil, c.password == nil else { return nil }
        return url
    }

    /// Proxy Deck's oauth.callback check: http(s), at most 4096 characters, carries code, state or error.
    public static func isValidRedirect(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf16.count <= 4096, let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https", c.host != nil else { return false }
        let names = Set((c.queryItems ?? []).map(\.name))
        return !names.isDisjoint(with: ["code", "state", "error"])
    }

    static func statusMessage(_ e: String?) -> String {
        if let e, shownErrors.contains(where: { e.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return e }
        return "The hub reported that sign-in did not finish."
    }
}

/// What `/v8/management/server/latest-version` reveals: the hub's own version (X-CPA-Version header) and the newest release.
public struct HubVersionInfo: Sendable, Equatable {
    public var current: String?
    public var latest: String?
}

extension ManagementClient {
    /// `GET /v8/management/oauth/auth-url?provider=…&is_webui=true`. Creates a session on the hub.
    public func startOAuth(_ p: OAuthProvider, key: String) async throws -> OAuthSession {
        guard p.method != .importFile else { throw OAuthError.unsupportedMethod }
        var query = [("provider", p.rawValue)]
        if p.method == .browser { query.append(("is_webui", "true")) }
        let (data, _) = try await request("GET", "v8/management/oauth/auth-url",
                                          query, key: key)
        struct R: Decodable {
            var url: String?; var state: String?; var expires_in: Double?; var interval: Double?
            var user_code: String?; var verification_uri: String?; var verification_uri_complete: String?; var flow: String?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let state = r.state else { throw ProxyError.incompatible }
        guard OAuthRules.isValidState(state) else { throw OAuthError.invalidState }
        let rawURL = r.verification_uri_complete ?? r.verification_uri ?? r.url
        guard let url = rawURL.flatMap({ OAuthRules.authURL($0, for: p) }) else {
            // The session exists on the hub; end it rather than leave it open.
            _ = try? await cancelOAuth(state: state, key: key)
            throw OAuthError.untrustedURL
        }
        let userCode = r.user_code.flatMap { OAuthRules.isValidUserCode($0) ? $0 : nil }
        if (p.method == .deviceCode || r.flow == "device" || r.user_code != nil), userCode == nil {
            _ = try? await cancelOAuth(state: state, key: key)
            throw OAuthError.invalidDeviceCode
        }
        let ttl = r.expires_in.flatMap { $0 > 0 && $0 < 86_400 ? $0 : nil }
        let interval = r.interval.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? max(2, $0) : nil } ?? 2
        return OAuthSession(provider: p, url: url, state: state, expiresIn: ttl, userCode: userCode, pollInterval: interval)
    }

    /// `GET /v8/management/oauth/status?state=…`.
    public func oauthStatus(state: String, key: String) async throws -> OAuthStatus {
        guard OAuthRules.isValidState(state) else { throw OAuthError.invalidState }
        let (data, _) = try await request("GET", "v8/management/oauth/status", [("state", state)], key: key)
        struct R: Decodable { var status: String?; var error: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw ProxyError.incompatible }
        switch r.status {
        case "ok": return .ok
        case "wait": return .wait
        default: return .error(OAuthRules.statusMessage(r.error))
        }
    }

    /// `DELETE /v8/management/oauth/session?state=…`. Returns the hub's `cancelled` flag.
    @discardableResult
    public func cancelOAuth(state: String, key: String) async throws -> Bool {
        guard OAuthRules.isValidState(state) else { throw OAuthError.invalidState }
        let (data, _) = try await request("DELETE", "v8/management/oauth/session", [("state", state)], key: key)
        struct R: Decodable { var cancelled: Bool? }
        return (try? JSONDecoder().decode(R.self, from: data))?.cancelled == true
    }

    /// `POST /v0/management/oauth-callback` with the redirect URL pasted from the browser.
    public func submitOAuthCallback(_ p: OAuthProvider, redirectURL: String, key: String) async throws {
        guard p.method == .browser else { throw OAuthError.unsupportedMethod }
        let raw = redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OAuthRules.isValidRedirect(raw) else { throw OAuthError.invalidRedirect }
        try await send("POST", "v0/management/oauth-callback", ["provider": p.callbackName, "redirect_url": raw], key: key)
    }

    /// Checked bytes only; callers must present confirmation before passing `confirmed: true`.
    public func importOAuthFile(_ data: Data, name: String, location: String = "", confirmed: Bool = false, key: String) async throws {
        guard confirmed else { throw OAuthError.confirmationRequired }
        try OAuthRules.validateImport(data, name: name)
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OAuthRules.isValidLocation(location) else { throw OAuthError.invalidLocation }
        let boundary = "T3Proxy-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(data)
        append("\r\n")
        if !location.isEmpty {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"location\"\r\n\r\n\(location)\r\n")
        }
        append("--\(boundary)--\r\n")
        let (reply, _) = try await request("POST", "v8/management/oauth/import", [("provider", "vertex")], key: key,
                                          body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard (try? JSONSerialization.jsonObject(with: reply)) is [String: Any] else { throw ProxyError.incompatible }
    }

    /// `GET /v8/management/server/latest-version`. The hub may ask GitHub; read only.
    public func versions(key: String) async throws -> HubVersionInfo {
        let (data, resp) = try await request("GET", "v8/management/server/latest-version", [], key: key, timeout: 20)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let latest = (obj?["latest-version"] ?? obj?["latest_version"] ?? obj?["version"]) as? String
        let current = resp.value(forHTTPHeaderField: "X-CPA-Version")
        return HubVersionInfo(current: current.flatMap { OAuthRules.isValidVersion($0) ? $0 : nil },
                              latest: latest.flatMap { OAuthRules.isValidVersion($0) ? $0 : nil })
    }

    /// `send` with a query string and the response headers. Same gate, auth and lock rules.
    func request(_ method: String, _ path: String, _ query: [(String, String)], key: String,
                 timeout: TimeInterval = 30, body: Data? = nil, contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard gate.permits(key) else { throw ManagementError.locked }
        var c = URLComponents(url: endpoint.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var r = URLRequest(url: c.url!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw ProxyError.unreachable }
        guard let http = resp as? HTTPURLResponse else { throw ProxyError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ProxyError.http(http.statusCode) }
        return (data, http)
    }
}
