import Foundation

/// Hub log reads, ported from Proxy Deck's logs.* ops. Every text that leaves these functions has
/// been through `LogRedactor` (configured secrets, the management key, credential-shaped strings)
/// before it is capped, and redaction fails closed: no secret list, no log text.
public enum LogsError: Error, Equatable {
    case invalidName, invalidRequestID, invalidCursor
    /// The answer was larger than Proxy Deck accepts.
    case tooLarge
    /// The hub has file logging off (its 400 "logging to file disabled").
    case loggingOff
}

public struct LogsTail: Sendable, Equatable {
    public var enabled: Bool
    public var lines: [String]
    public var latest: Int?
    public var cursor: String?
    public var reset: Bool
}

public struct LogFile: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var size: Int?
    public var modified: Date?
}

public struct LogText: Sendable, Equatable {
    public var name: String
    public var text: String
    public var truncated: Bool
}

public enum LogLimits {
    public static let maxLines = 5000
    public static let maxLine = 4000
    public static let textMax = 1_000_000
    public static let maxResponse = 8 * 1024 * 1024
    public static let logName = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$"#
    public static let requestID = #"^[A-Za-z0-9_-]{1,64}$"#

    static func matches(_ s: String, _ re: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }
    public static func isLogName(_ s: String) -> Bool { matches(s, logName) && !s.contains("..") }
    public static func isRequestID(_ s: String) -> Bool { matches(s, requestID) }

    /// Proxy Deck's validCursor(): base64url JSON naming one log file, an offset and a fingerprint, nothing else.
    public static func validCursor(_ v: String?) -> String? {
        guard let v, matches(v, #"^[A-Za-z0-9_-]{1,2048}={0,2}$"#) else { return nil }
        var b = v.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "=", with: "")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let allowed: Set = ["v", "file", "offset", "size", "modTime", "modTimeUnixNano", "latestTimestamp", "fingerprint"]
        guard Set(c.keys).isSubset(of: allowed) else { return nil }
        func int(_ x: Any?) -> Bool {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            let dv = n.doubleValue
            return dv >= 0 && dv == dv.rounded() && dv <= 9_007_199_254_740_991
        }
        // Nanosecond times exceed 2^53 (live 8.0.55), so that field only needs to be a non-negative Int64.
        func int64(_ x: Any?) -> Bool {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return false }
            return n.int64Value >= 0
        }
        guard (c["v"] as? NSNumber)?.intValue == 1, let file = c["file"] as? String, isLogName(file),
              int(c["offset"]), int(c["size"]), int(c["modTime"]), c["modTimeUnixNano"] == nil || int64(c["modTimeUnixNano"]),
              int(c["latestTimestamp"]), let fp = c["fingerprint"] as? String, matches(fp, #"^[A-Za-z0-9_-]{0,64}$"#)
        else { return nil }
        return v
    }

    /// Lines cut after redaction, as Proxy Deck's capLogs().
    public static func capLine(_ l: String) -> String { l.count > maxLine ? String(l.prefix(maxLine)) + "…" : l }
    public static func capText(_ t: LogText) -> LogText {
        t.text.count > textMax ? LogText(name: t.name, text: String(t.text.prefix(textMax)), truncated: true) : t
    }
}

/// Proxy Deck's configSecrets() + redact().
public enum LogRedactor {
    static let tokenKeys = #"access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?key|api[_-]?key|client[_-]?secret|password|authorization|credit[_-]?id|redeem[_-]?request[_-]?id"#

    private static let patterns: [(NSRegularExpression, String)] = {
        let ci: NSRegularExpression.Options = [.caseInsensitive]
        let list: [(String, NSRegularExpression.Options, String)] = [
            // Quoted keys first: JSON, JSON inside a JSON string (\"k\":\"v\"), single-quoted.
            (#""(\#(tokenKeys))"(\s*:\s*)"(?:[^"\\]|\\.)*""#, ci, #""$1"$2"[redacted]""#),
            (#"\\"(\#(tokenKeys))\\"(\s*:\s*)\\"(?:(?!\\")[^\n])*\\""#, ci, #"\\"$1\\"$2\\"[redacted]\\""#),
            (#"'(\#(tokenKeys))'(\s*:\s*)'(?:[^'\\]|\\.)*'"#, ci, #"'$1'$2'[redacted]'"#),
            // Cookie headers: the rest of the line, quoted values included; every pair can be a credential.
            (#"\b((?:set-)?cookie)(["']?\s*:\s*)[^\r\n]*"#, ci, "$1$2[redacted]"),
            // OAuth callback parameters (plain or percent-encoded separators).
            (#"(?:(?<=[?&])|(?<=%3F)|(?<=%26))(code|state|code_verifier|id_token|access_token|refresh_token)(=|%3D)[^&\s"'#]+"#, ci, "$1$2[redacted]"),
            // Header-style values, scheme included.
            (#"\b((?:x-)?api[-_]?key|x-goog-api-key|authorization|cookie|set-cookie|x-management-key)(["']?\s*[:=]\s*["']?)(?:(?:Bearer|Basic)\s+)?(?:\[redacted\]|[^\s"',;]{4,})"#, ci, "$1$2[redacted]"),
            (#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}"#, ci, "$1 [redacted]"),
            (#"\b(sk|rk|pk)-[A-Za-z0-9_-]{8,}"#, [], "[redacted]"),
            // Unquoted keys: key: value, key=value, URL query params.
            (#"\b(\#(tokenKeys))\b(["']?\s*[:=]\s*["']?)(?!\[redacted\])(?:(?:Bearer|Basic)\s+)?[^\s"'&,;}]+"#, ci, "$1$2[redacted]"),
            (#"\b(key)=[^&\s"']+"#, ci, "$1=[redacted]"),
            // Codex reset-credit ids, wherever they appear (credit lists use a plain "id").
            (#"\bRateLimitResetCredit_[A-Za-z0-9_-]+"#, [], "[redacted]"),
        ]
        return list.map { (try! NSRegularExpression(pattern: $0.0, options: $0.1), $0.2) }
    }()

    /// Known secrets (longest first) replaced whole, then credential-shaped strings. Run before any truncation.
    public static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        for s in secrets where !s.isEmpty { out = out.replacingOccurrences(of: s, with: "[redacted]") }
        for (re, template) in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return Privacy.hideEmails(out)
    }

    /// Every secret string in the hub config, longest first. Throws when the body is not a config
    /// tree: redaction must fail closed, never fall back to an empty list.
    public static func configSecrets(_ data: Data) throws -> [String] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyError.incompatible }
        let access = body["access"]
        if access != nil, !(access is [String: Any]) { throw ProxyError.incompatible }
        for keys in [body["api-keys"], (access as? [String: Any])?["api-keys"]] {
            if let k = keys, !(k is NSNull), !(k is [Any]), !(k is [String: Any]) { throw ProxyError.incompatible }
        }
        var out = Set<String>()
        func add(_ s: String) { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.insert(t) } }
        func walk(_ v: Any, _ key: String, _ inKeys: Bool) {
            if let s = v as? String {
                if inKeys || key.range(of: #"(^|-)(api-key|secret-key|key|token|password)$"#, options: .regularExpression) != nil { add(s) }
                proxyCredentials(s).forEach(add)
            } else if let a = v as? [Any] { a.forEach { walk($0, key, inKeys) } }
            else if let d = v as? [String: Any] { for (k, x) in d { walk(x, k, inKeys || k == "api-keys") } }
        }
        walk(body, "", false)
        return sorted(out)
    }

    static func sorted(_ s: Set<String>) -> [String] { s.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 } }

    /// Proxy-URL credentials: the whole user:pass and each part, as written and URL-decoded/encoded.
    static func proxyCredentials(_ v: String) -> [String] {
        guard let r = v.range(of: #"^[A-Za-z0-9+.-]+://[^@/\s]+@"#, options: .regularExpression),
              let start = v[r].range(of: "://")?.upperBound else { return [] }
        let info = String(v[start..<v.index(before: r.upperBound)])
        var parts = [info]
        if let colon = info.firstIndex(of: ":") { parts += [String(info[..<colon]), String(info[info.index(after: colon)...])] } else { parts.append(info) }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        var out = [info]
        for raw in parts {
            out.append(raw)
            if let dec = raw.removingPercentEncoding {
                out.append(dec)
                if let enc = dec.addingPercentEncoding(withAllowedCharacters: allowed) { out.append(enc) }
            }
        }
        return out
    }
}

extension ManagementClient {
    /// The secrets to scrub: every configured secret plus the management key. Re-read on every log read.
    func logSecrets(key: String) async throws -> [String] {
        let data = try await send("GET", "v8/management/config", nil, key: key)
        return LogRedactor.sorted(Set(try LogRedactor.configSecrets(data) + [key]))
    }

    /// No cursor: the newest `limit` lines. With the hub's cursor: only lines after it.
    public func logsTail(cursor: String? = nil, limit: Int? = nil, key: String) async throws -> LogsTail {
        if cursor != nil, LogLimits.validCursor(cursor) == nil { throw LogsError.invalidCursor }
        var q: [URLQueryItem] = []
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        if let limit { q.append(.init(name: "limit", value: String(min(max(limit, 1), LogLimits.maxLines)))) }
        let secrets = try await logSecrets(key: key)
        let (code, data) = try await fetch("v8/management/observability/logs", query: q, key: key, allow400: true)
        if code == 400 {
            struct E: Decodable { var error: String?; var message: String? }
            let e = try? JSONDecoder().decode(E.self, from: data)
            let msg = (e?.error ?? e?.message ?? "").trimmingCharacters(in: .whitespaces)
            if msg.range(of: "^logging to file disabled$", options: [.regularExpression, .caseInsensitive]) != nil {
                return LogsTail(enabled: false, lines: [], latest: nil, cursor: nil, reset: false)
            }
            throw ProxyError.http(400)
        }
        struct T: Decodable {
            var lines: L<[L<String>]>?, latest: L<Double>?, latest2: L<Double>?, cursor: L<String>?, reset: L<Bool>?
            enum CodingKeys: String, CodingKey {
                case lines, latest = "latest-timestamp", latest2 = "latest_timestamp", cursor = "next-cursor", reset = "cursor-reset"
            }
        }
        guard let t = try? JSONDecoder().decode(T.self, from: data) else { throw ProxyError.incompatible }
        let lines = (t.lines?.v ?? []).compactMap(\.v).suffix(LogLimits.maxLines)
            .map { LogLimits.capLine(LogRedactor.redact($0, secrets: secrets)) }
        let latest = t.latest?.v ?? t.latest2?.v ?? 0
        return LogsTail(enabled: true, lines: Array(lines), latest: latest > 0 && latest < 1e15 ? Int(latest) : nil,
                        cursor: LogLimits.validCursor(t.cursor?.v), reset: t.reset?.v == true)
    }

    /// Error log files, newest first.
    public func errorLogs(key: String) async throws -> [LogFile] {
        let (_, data) = try await fetch("v8/management/observability/logs/errors", key: key)
        struct F: Decodable { var name: L<String>?, size: L<Double>?, modified: L<Double>? }
        struct Env: Decodable { var files: [L<F>] }
        guard let env = try? JSONDecoder().decode(Env.self, from: data) else { throw ProxyError.incompatible }
        return env.files.compactMap(\.v).compactMap { f -> LogFile? in
            guard let n = f.name?.v, LogLimits.isLogName(n) else { return nil }
            let m = f.modified?.v ?? 0
            return LogFile(name: n, size: f.size?.v.flatMap { $0 >= 0 && $0 < 1e15 ? Int($0) : nil },
                           modified: m > 0 && m < 1e13 ? Date(timeIntervalSince1970: m) : nil)
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    public func errorLog(name: String, key: String) async throws -> LogText {
        guard LogLimits.isLogName(name) else { throw LogsError.invalidName }
        return try await text("v8/management/observability/logs/errors/\(name)", name: name, key: key)
    }

    public func requestLog(id: String, key: String) async throws -> LogText {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard LogLimits.isRequestID(id) else { throw LogsError.invalidRequestID }
        return try await text("v8/management/observability/logs/requests/\(id)", name: id, key: key)
    }

    /// Deletes the hub's log files. Returns how many, when the hub says.
    @discardableResult
    public func clearLogs(key: String) async throws -> Int? {
        let data = try await send("DELETE", "v8/management/observability/logs", nil, key: key)
        struct R: Decodable { var removed: L<Int>?, deleted: L<Int>? }
        let r = try? JSONDecoder().decode(R.self, from: data)
        return r?.removed?.v ?? r?.deleted?.v
    }

    // MARK: -

    private func text(_ path: String, name: String, key: String) async throws -> LogText {
        let secrets = try await logSecrets(key: key)
        let (_, data) = try await fetch(path, key: key)
        let raw = String(decoding: data, as: UTF8.self)
        return LogLimits.capText(LogText(name: name, text: LogRedactor.redact(raw, secrets: secrets), truncated: false))
    }

    /// GET with a query string and a response cap. Same gate and 401/403 lock as `send`.
    private func fetch(_ path: String, query: [URLQueryItem] = [], key: String, allow400: Bool = false) async throws -> (Int, Data) {
        guard gate.permits(key) else { throw ManagementError.locked }
        var c = URLComponents(url: endpoint.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 30)
        r.httpMethod = "GET"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw ProxyError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard (200..<300).contains(code) || (allow400 && code == 400) else { throw ProxyError.http(code) }
        guard data.count <= LogLimits.maxResponse else { throw LogsError.tooLarge }
        return (code, data)
    }
}
