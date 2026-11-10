import Foundation
import CryptoKit
import CoreFoundation

public struct T3LimitsRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var port: UInt16
    public init(method: String, path: String, headers: [String: String], body: Data = Data(), port: UInt16 = 8318) {
        self.method = method; self.path = path; self.body = body; self.port = port
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}
public struct T3LimitsResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json; charset=utf-8"
    public static func error(_ status: Int, _ message: String) -> Self { json(["error": message], status: status) }
    static func json(_ value: Any, status: Int = 200) -> Self {
        .init(status: status, body: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("{}".utf8))
    }
}

/// Raw management envelopes, never provider credentials. Implementations must share the app's AuthGate.
public protocol T3LimitsHub: Sendable {
    func authFiles(key: String) async throws -> Data
    func call(_ target: LiveQuotaTarget, authIndex: String, accountID: String?, data: String?, key: String) async throws -> Data
    func resetQuota(authIndex: String, key: String) async throws -> Data
}
private struct LimitsHTTPFailure: Error { let body: Data }
private enum LimitsFailure: Error { case accountList }

extension ManagementClient: T3LimitsHub {
    /// Same session, redirect refusal and rejected-key gate as other management operations.
    private func limitsSend(_ method: String, _ path: String, _ body: [String: any Sendable]?, key: String) async throws -> Data {
        guard gate.permits(key) else { throw ManagementError.locked }
        var request = URLRequest(url: endpoint.base.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.boundedFetch(session, request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { gate.reject(key); throw ProxyError.unauthorized }
        guard status == 200 else { throw LimitsHTTPFailure(body: data) }
        return data
    }
    static let limitsResponseCap = 8_000_000
    /// Streams the hub's answer, stopping as soon as it passes the cap (never buffering more), within 45 s overall.
    private static func boundedFetch(_ session: URLSession, _ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                let bytes: URLSession.AsyncBytes, response: URLResponse
                do { (bytes, response) = try await session.bytes(for: request) } catch { throw ProxyError.unreachable }
                if response.expectedContentLength > Int64(limitsResponseCap) { bytes.task.cancel(); throw LiveQuotaError.responseTooLarge }
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > limitsResponseCap { bytes.task.cancel(); throw LiveQuotaError.responseTooLarge }
                    }
                } catch let e as LiveQuotaError { throw e } catch { throw ProxyError.unreachable }
                return (data, response)
            }
            group.addTask { try await Task.sleep(for: .seconds(45)); throw ProxyError.unreachable }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProxyError.unreachable }
            return first
        }
    }

    public func authFiles(key: String) async throws -> Data { try await limitsSend("GET", "v0/management/auth-files", nil, key: key) }
    public func call(_ target: LiveQuotaTarget, authIndex: String, accountID: String?, data: String?, key: String) async throws -> Data {
        guard [.claudeUsage, .codexUsage, .codexCredits, .codexConsume].contains(target),
              T3LimitsHandler.validData(data, target: target) else { throw LiveQuotaError.invalidCredit }
        var body: [String: any Sendable] = ["authIndex": authIndex, "method": target.method, "url": target.url,
                                           "header": try target.headers(accountID: accountID)]
        if let data { body["data"] = data }
        return try await limitsSend("POST", "v0/management/api-call", body, key: key)
    }
    public func resetQuota(authIndex: String, key: String) async throws -> Data {
        try await limitsSend("POST", "v0/management/reset-quota", ["auth_index": authIndex], key: key)
    }
}
public struct T3LocalLogin: Sendable {
    public var email: String
    public var orgID: String
    public init(email: String, orgID: String) { self.email = email; self.orgID = orgID }
    /// Decodes only the two fields needed for subscription matching. Never emits either identity.
    public static func read(file: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")) -> Self? {
        struct Login: Decodable {
            struct Account: Decodable { var emailAddress: String?; var organizationUuid: String? }
            var oauthAccount: Account?
        }
        guard let data = try? Data(contentsOf: file), let a = try? JSONDecoder().decode(Login.self, from: data).oauthAccount,
              let email = limitsString(a.emailAddress), let org = PlanCache.orgFingerprint(a.organizationUuid) else { return nil }
        return .init(email: email, orgID: org)
    }
}
private func limitsString(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

public struct T3LimitsHandler: Sendable {
    public static let prefix = "/t3/v0/management/"
    public static let bodyLimit = 16_384
    private let key: @Sendable () async throws -> String
    private let hub: any T3LimitsHub
    private let plans: @Sendable () -> [String: PlanInfo]
    private let localLogin: @Sendable () -> T3LocalLogin?
    public init(key: @escaping @Sendable () async throws -> String, hub: any T3LimitsHub,
                plans: @escaping @Sendable () -> [String: PlanInfo] = { PlanCache.load() },
                localLogin: @escaping @Sendable () -> T3LocalLogin? = { T3LocalLogin.read() }) {
        self.key = key; self.hub = hub; self.plans = plans; self.localLogin = localLogin
    }
    struct Listed { var index: String; var provider: String; var accountID: String?; var out: [String: Any]; var disabled: Bool }
    static func listing(_ files: [[String: Any]], plans: [String: PlanInfo], local: T3LocalLogin?) -> [Listed] {
        func provider(_ f: [String: Any]) -> String { (limitsString(f["provider"]) ?? limitsString(f["type"]) ?? "").lowercased() }
        let matches = files.filter { f in
            guard let local, provider(f) == "claude", f["disabled"] as? Bool != true, let idx = limitsString(f["auth_index"]) else { return false }
            return plans[PlanCache.accountKey(idx)]?.freshOrgID() == local.orgID
                && limitsString(f["email"])?.lowercased() == local.email.lowercased()
        }
        let merged = matches.count == 1 ? limitsString(matches[0]["auth_index"]) : nil
        var used = Set<String>()
        return files.compactMap { f in
            let p = provider(f)
            guard ["claude", "codex"].contains(p), let idx = limitsString(f["auth_index"]), let id = limitsString(f["id"]) else { return nil }
            let disabled = f["disabled"] as? Bool == true
            var out: [String: Any] = ["id": id, "auth_index": idx, "provider": p, "disabled": disabled]
            var accountID: String?
            if p == "codex" {
                let token = f["id_token"] as? [String: Any] ?? [:]
                var allowed: [String: String] = [:]
                for k in ["chatgpt_account_id", "chatgpt_plan_type", "plan_type"] { allowed[k] = limitsString(token[k]) }
                out["id_token"] = allowed; accountID = allowed["chatgpt_account_id"]
                out["email"] = limitsString(f["email"])
            } else {
                let plan = plans[PlanCache.accountKey(idx)]?.plan
                let title = plan?.split(separator: " ").map { String($0.prefix(1)).uppercased() + $0.dropFirst() }.joined(separator: " ")
                let base = nickname(f["note"]) ?? title.map { "Claude " + $0 } ?? "Claude account"
                var name = base, n = 2
                while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                used.insert(name.lowercased()); out["id"] = name
                if idx == merged { out["email"] = local?.email }
            }
            return Listed(index: idx, provider: p, accountID: accountID, out: out, disabled: disabled)
        }
    }
    // Same Unicode stripping and code-point length cap as normalize.ts, including bidi controls.
    static func nickname(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let stripped = s.replacingOccurrences(of: #"[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = String(String.UnicodeScalarView(stripped.unicodeScalars.prefix(60))).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
    static func validData(_ data: String?, target: LiveQuotaTarget) -> Bool {
        guard target == .codexConsume else { return data == nil }
        guard let data, data.utf16.count <= 1000, let o = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              Set(o.keys) == ["redeem_request_id", "credit_id"] else { return false }
        return o.values.allSatisfy { ($0 as? String)?.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil }
    }
    public func handle(_ req: T3LimitsRequest) async -> T3LimitsResponse {
        guard req.headers["origin"] == nil else { return .error(403, "Origin is not allowed.") }
        guard ["127.0.0.1:\(req.port)", "localhost:\(req.port)"].contains(req.headers["host"] ?? "") else { return .error(403, "Host is not allowed.") }
        guard req.path.hasPrefix(Self.prefix) else { return .init(status: 404, body: Data("Not found".utf8), contentType: "text/plain") }
        let expected: String
        do { expected = try await key(); guard !expected.isEmpty else { throw ManagementError.locked } }
        catch { return .error(503, "Proxy Deck has no management key configured.") }
        let authorization = req.headers["authorization"] ?? ""
        let given = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
        let a = Array(SHA256.hash(data: Data(given.utf8))), b = Array(SHA256.hash(data: Data(expected.utf8)))
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        guard diff == 0 else { return .error(401, "Wrong management key.") }
        guard req.body.count <= Self.bodyLimit else { return .error(413, "Request body is too large.") }
        let op = String(req.path.dropFirst(Self.prefix.count))
        do {
            if op == "auth-files" && req.method == "GET" {
                let raw = try await hub.authFiles(key: expected)
                let files = try decodeFiles(raw)
                return .json(["files": Self.listing(files, plans: plans(), local: localLogin()).map(\.out)])
            }
            if ["api-call", "reset-quota"].contains(op) && req.method == "POST" {
                guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any], let idx = limitsString(body["auth_index"]) else { return .error(400, "Expected a JSON body with auth_index.") }
                let raw = try await hub.authFiles(key: expected)
                guard let account = Self.listing(try decodeFiles(raw), plans: plans(), local: nil).first(where: { $0.index == idx }), !account.disabled else { return .error(404, "No such enabled Claude or Codex account.") }
                if op == "reset-quota" {
                    guard account.provider == "codex" else { return .error(403, "Only Codex cooldowns are cleared here.") }
                    let raw = try await hub.resetQuota(authIndex: idx, key: expected)
                    return .json((try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) ?? [:])
                }
                guard (body["method"] == nil || body["method"] is NSNull || body["method"] is String),
                      let target = [LiveQuotaTarget.claudeUsage, .codexUsage, .codexCredits, .codexConsume].first(where: {
                    $0.provider.rawValue == account.provider && $0.url == body["url"] as? String && $0.method == (body["method"] as? String ?? "GET")
                }), (body["data"] == nil || body["data"] is String), Self.validData(body["data"] as? String, target: target) else {
                    return .error(403, "Only T3 Code's limit reads and Codex reset credits are allowed.")
                }
                var payload = body["data"] as? String
                if target == .codexConsume, let payloadText = payload,
                   let fields = try JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: String] {
                    payload = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
                }
                let callRaw = try await hub.call(target, authIndex: idx, accountID: account.accountID, data: payload, key: expected)
                guard let wrapped = try JSONSerialization.jsonObject(with: callRaw) as? [String: Any], let code = wrapped["status_code"] as? NSNumber,
                      CFGetTypeID(code) != CFBooleanGetTypeID() else { return .error(502, "The hub could not run the call.") }
                let bodyText: String
                if let text = wrapped["body"] as? String { bodyText = text }
                else { bodyText = String(decoding: try JSONSerialization.data(withJSONObject: wrapped["body"] ?? NSNull(), options: [.fragmentsAllowed]), as: UTF8.self) }
                return .json(["status_code": code, "body": bodyText])
            }
            return .init(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        } catch ManagementError.locked { return .error(503, "Management access is unavailable.") }
        catch ProxyError.unauthorized { return .error(502, "The hub rejected the management key.") }
        catch ProxyError.unreachable { return .error(502, "Could not reach the hub. Is CLIProxyAPI running?") }
        catch LimitsFailure.accountList { return .error(502, "The hub returned an unexpected account list.") }
        catch LiveQuotaError.responseTooLarge { return .error(502, "The hub's answer is too large.") }
        catch let error as LimitsHTTPFailure {
            if op == "reset-quota" { return .json((try? JSONSerialization.jsonObject(with: error.body, options: [.fragmentsAllowed])) ?? [:], status: 502) }
            if op == "auth-files" { return .error(502, "The hub returned an unexpected account list.") }
            return .error(502, "The hub could not run the call.")
        }
        catch { return .error(502, "The hub could not run the call.") }
    }
    private func decodeFiles(_ raw: Data) throws -> [[String: Any]] {
        guard let env = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any], let files = env["files"] as? [Any] else { throw LimitsFailure.accountList }
        return files.compactMap { $0 as? [String: Any] }
    }
}
