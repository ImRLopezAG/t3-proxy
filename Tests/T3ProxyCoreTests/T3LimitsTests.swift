import Foundation
import Testing
@testable import T3ProxyCore

struct T3LimitsTests {
    @Test func wrongKeyNeverCallsHub() async {
        let handler = T3LimitsHandler(key: { "secret" }, hub: ForbiddenLimitsHub())
        let response = await handler.handle(.init(method: "GET", path: "/t3/v0/management/auth-files", headers: ["host": "127.0.0.1:8318", "authorization": "Bearer wrong"]))
        #expect(response.status == 401)
    }
}
private struct ForbiddenLimitsHub: T3LimitsHub {
    func authFiles(key: String) async throws -> Data { Issue.record("Unexpected hub call"); return Data() }
    func call(_ target: LiveQuotaTarget, authIndex: String, accountID: String?, data: String?, key: String) async throws -> Data { Issue.record("Unexpected call"); return Data() }
    func resetQuota(authIndex: String, key: String) async throws -> Data { Issue.record("Unexpected reset"); return Data() }
}

private actor StubLimitsHub: T3LimitsHub {
    let files: Data
    private(set) var calls = 0
    private(set) var resets = 0
    private(set) var payload: String?
    init(files: [[String: any Sendable]] = [["id": "c", "auth_index": "c", "provider": "claude"], ["id": "o", "auth_index": "o", "provider": "codex"]]) {
        self.files = try! JSONSerialization.data(withJSONObject: ["files": files])
    }
    func authFiles(key: String) async throws -> Data { calls += 1; return files }
    func call(_ target: LiveQuotaTarget, authIndex: String, accountID: String?, data: String?, key: String) async throws -> Data {
        calls += 1; payload = data
        return Data(#"{"status_code":429,"body":{"error":"limited"},"header":{"secret":"discard"}}"#.utf8)
    }
    func resetQuota(authIndex: String, key: String) async throws -> Data { resets += 1; return Data(#"{"ok":true}"#.utf8) }
}

extension T3LimitsTests {
    private func request(_ op: String = "auth-files", method: String = "GET", body: [String: Any]? = nil,
                         headers: [String: String] = ["host": "127.0.0.1:8318", "authorization": "Bearer secret"]) -> T3LimitsRequest {
        .init(method: method, path: T3LimitsHandler.prefix + op, headers: headers,
              body: body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }
    private func handler(_ hub: any T3LimitsHub) -> T3LimitsHandler {
        T3LimitsHandler(key: { "secret" }, hub: hub, plans: { [:] }, localLogin: { nil })
    }
    @Test func missingKeyAndUnavailableKeyDoNotReachHub() async {
        #expect(await handler(ForbiddenLimitsHub()).handle(request(headers: ["host": "localhost:8318"])).status == 401)
        let locked = T3LimitsHandler(key: { throw ManagementError.locked }, hub: ForbiddenLimitsHub())
        #expect(await locked.handle(request()).status == 503)
    }
    @Test func originHostAndBodyCaps() async {
        let h = handler(ForbiddenLimitsHub())
        for headers in [["host": "evil.test:8318"], ["host": "127.0.0.1:8318", "origin": "null"], ["host": "localhost"], [:]] {
            #expect(await h.handle(request(headers: headers)).status == 403)
        }
        var large = request("api-call", method: "POST"); large.body = Data(repeating: 32, count: 16385)
        #expect(await h.handle(large).status == 413)
        var path = request(); path.path = "/v0/management/auth-files"
        #expect(await h.handle(path).status == 404)
    }
    @Test func listingNamesPlansAndCodexAllowlist() async throws {
        let hub = StubLimitsHub(files: [
            ["id": "a", "auth_index": "a", "provider": "claude", "email": "hidden@example.test", "note": " Team\nOne "],
            ["id": "b", "auth_index": "b", "provider": "claude", "note": "teamone"],
            ["id": "c", "auth_index": "c", "provider": "claude"],
            ["id": "o", "auth_index": "o", "provider": "codex", "email": "codex@example.test", "access_token": "NEVER", "id_token": ["chatgpt_account_id": "work", "plan_type": "team", "chatgpt_plan_type": "business", "email": "NEVER"]],
            ["id": "x", "auth_index": "x", "provider": "other"]])
        let h = T3LimitsHandler(key: { "secret" }, hub: hub, plans: { [PlanCache.accountKey("c"): .init(plan: "max 20x", org: nil)] }, localLogin: { nil })
        let res = await h.handle(request())
        let o = try #require(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let files = try #require(o["files"] as? [[String: Any]])
        #expect(files.count == 4)
        #expect(files[0]["id"] as? String == "TeamOne")
        #expect(files[1]["id"] as? String == "teamone 2")
        #expect(files[2]["id"] as? String == "Claude Max 20x")
        #expect(files[0]["email"] == nil)
        #expect(files[3]["email"] as? String == "codex@example.test")
        #expect(!String(decoding: res.body, as: UTF8.self).contains("NEVER"))
        #expect(Set(files[3].keys) == ["id", "auth_index", "provider", "email", "disabled", "id_token"])
    }
    @Test func localExceptionRequiresUniqueEnabledOrgAndEmail() {
        let local = T3LocalLogin(email: "User@example.test", orgID: "0123456789abcdef")
        let plans = [PlanCache.accountKey("a"): PlanInfo(plan: "team", org: nil, orgID: local.orgID, observedAt: Date()),
                     PlanCache.accountKey("b"): PlanInfo(plan: "team", org: nil, orgID: local.orgID, observedAt: Date())]
        let a: [String: Any] = ["id": "a", "auth_index": "a", "provider": "claude", "email": "user@example.test"]
        var b = a; b["id"] = "b"; b["auth_index"] = "b"
        #expect(T3LimitsHandler.listing([a], plans: plans, local: local)[0].out["email"] as? String == local.email)
        #expect(T3LimitsHandler.listing([a, b], plans: plans, local: local).allSatisfy { $0.out["email"] == nil })
        b["disabled"] = true
        #expect(T3LimitsHandler.listing([a, b], plans: plans, local: local)[0].out["email"] != nil)
        #expect(T3LimitsHandler.listing([a], plans: [:], local: local)[0].out["email"] == nil)
        let other = T3LocalLogin(email: "other@example.test", orgID: local.orgID)
        #expect(T3LimitsHandler.listing([a], plans: plans, local: other)[0].out["email"] == nil)
        var stale = plans; stale[PlanCache.accountKey("a")]?.observedAt = Date().addingTimeInterval(-8 * 86400)
        #expect(T3LimitsHandler.listing([a], plans: stale, local: local)[0].out["email"] == nil)
    }
    @Test func allowlistAndProviderErrors() async throws {
        let hub = StubLimitsHub(), h = handler(hub)
        for target in LiveQuotaTarget.allCases {
            let index = target.provider == .claude ? "c" : "o"
            let res = await h.handle(request("api-call", method: "POST", body: ["auth_index": index, "method": target.method, "url": target.url]))
            #expect(res.status == ([LiveQuotaTarget.claudeUsage, .codexUsage, .codexCredits].contains(target) ? 200 : 403))
        }
        let bad = await h.handle(request("api-call", method: "POST", body: ["auth_index": "c", "url": LiveQuotaTarget.codexUsage.url]))
        #expect(bad.status == 403)
        let res = await h.handle(request("api-call", method: "POST", body: ["auth_index": "o", "url": LiveQuotaTarget.codexUsage.url, "header": ["Authorization": "evil"]]))
        let envelope = try #require(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        #expect(envelope["status_code"] as? Int == 429)
        #expect(envelope["body"] is String)
        #expect(envelope["header"] == nil)
    }
    @Test func consumeStrictPayloadAndResetCodexOnly() async {
        let hub = StubLimitsHub(), h = handler(hub)
        for data in [#"{"credit_id":"c","redeem_request_id":"r","extra":1}"#, #"{"credit_id":"","redeem_request_id":"r"}"#, #"{"credit_id":1,"redeem_request_id":"r"}"#, #"{"credit_id":"a/b","redeem_request_id":"r"}"#, "null", "[]", String(repeating: "x", count: 1001)] {
            #expect(await h.handle(request("api-call", method: "POST", body: ["auth_index": "o", "method": "POST", "url": LiveQuotaTarget.codexConsume.url, "data": data])).status == 403)
        }
        #expect(await h.handle(request("api-call", method: "POST", body: ["auth_index": "o", "method": "POST", "url": LiveQuotaTarget.codexConsume.url, "data": #"{"credit_id":"abc_1","redeem_request_id":"req-1"}"#])).status == 200)
        #expect(await h.handle(request("reset-quota", method: "POST", body: ["auth_index": "c"])).status == 403)
        #expect(await hub.resets == 0)
        #expect(await h.handle(request("reset-quota", method: "POST", body: ["auth_index": "o"])).status == 200)
        #expect(await hub.resets == 1)
        #expect(await h.handle(request("api-call", method: "POST", body: [:])).status == 400)
        #expect(await h.handle(request("reset-quota", method: "POST", body: ["auth_index": "gone"])).status == 404)
    }
    @Test @MainActor func ephemeralLoopbackRoundTrip() async throws {
        let server = T3LimitsServer(handler: handler(StubLimitsHub()))
        server.start(port: 0)
        defer { server.stop() }
        var port: UInt16?
        for await status in server.$status.values {
            if case .listening(let p) = status { port = p; break }
            if case .failed = status { Issue.record("Listener failed"); return }
        }
        let p = try #require(port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(p)/t3/v0/management/auth-files")!)
        req.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: req)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Claude account"))
        req.setValue("https://example.test", forHTTPHeaderField: "Origin")
        #expect((try await session.data(for: req).1 as? HTTPURLResponse)?.statusCode == 403)
    }
}

extension T3LimitsTests {
    @Test @MainActor func framingAndPortContention() async throws {
        let server = T3LimitsServer(handler: handler(StubLimitsHub()))
        server.start(port: 0)
        defer { server.stop() }
        var port: UInt16?
        for await status in server.$status.values {
            if case .listening(let p) = status { port = p; break }
            if case .failed = status { Issue.record("Listener failed"); return }
        }
        let p = try #require(port)
        let second = T3LimitsServer(handler: handler(ForbiddenLimitsHub()))
        second.start(port: p)
        defer { second.stop() }
        for await status in second.$status.values {
            if case .portBusy(let busyPort) = status { #expect(busyPort == p); break }
            if case .listening = status { Issue.record("Second server unexpectedly bound an occupied port"); break }
        }
        let prefix = "POST /t3/v0/management/api-call HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nAuthorization: Bearer secret\r\n"
        for (tail, status) in [("Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 400),
                                ("Content-Length: 0\r\nContent-Length: 1\r\n\r\n", 400),
                                ("Content-Length: -1\r\n\r\n", 400),
                                ("Content-Length: 16385\r\n\r\n", 413),
                                ("X-Large: " + String(repeating: "x", count: 16384) + "\r\n\r\n", 431)] {
            let response = try await rawLimitsRequest(port: p, text: prefix + tail)
            #expect(response.hasPrefix("HTTP/1.1 \(status) "))
            #expect(response.contains("Connection: close\r\n"))
        }
    }
}

import Darwin
private func rawLimitsRequest(port: UInt16, text: String) async throws -> String {
    try await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError.unreachable }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { throw ProxyError.unreachable }
        let input = Data(text.utf8)
        var sent = 0
        try input.withUnsafeBytes { bytes in
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw ProxyError.unreachable }; sent += count
            }
        }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return String(decoding: result, as: UTF8.self)
    }.value
}
