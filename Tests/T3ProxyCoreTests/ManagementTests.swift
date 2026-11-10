import Foundation
import Testing
@testable import T3ProxyCore

/// Shaped like a live 8.0.55 `/v8/management/credentials` answer (field names observed, values invented).
let credentials = #"""
{"observed_at":"2026-11-06T18:00:00Z","files":[
 {"name":"claude-a.json","id":"claude-a.json","provider":"claude","type":"claude","auth_index":"ai-1","note":"  Work\u0007  main ","priority":10,
  "status":"active","disabled":false,"unavailable":false,"runtime_only":false,"path":"/secret/claude-a.json","email":"a@example.com",
  "label":"a@example.com","account":"x","cooldowns":[],"last_refresh":"2026-11-06T17:00:00Z","success":3,"failed":0,
  "recent_requests":[{"time":"t","success":1,"failed":0}],"quota":{"observed_at":"t","signals":{}},"model_quotas":{}},
 {"name":"codex-b.json","provider":"codex","auth_index":"ai-2","status":"disabled","disabled":true,
  "id_token":{"plan_type":"pro","chatgpt_account_id":"secret-acct"}},
 {"name":"claude-c.json","provider":"claude","auth_index":"ai-3","status":"active","plan_type":"max 20x","priority":"bogus",
  "cooldowns":[{"scope":"model","model_key":"m","retry_at":"2026-11-06T20:00:00Z","http_status":429},
               {"scope":"credential","retry_at":"2026-11-06T19:00:00Z"}]},
 {"name":"xai-d.json","type":"xai","auth_index":"ai-4","status":"error","status_message":"token expired","priority":500},
 {"name":"../evil.json","provider":"claude"}
]}
"""#

/// Separate from `Stub` so this suite can run in parallel with MonitorTests.
final class MStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with r: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        MStub.seen.append(request)
        let (code, body) = MStub.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor func mgmtMonitor(_ store: KeyStore, _ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> Monitor {
    MStub.handler = h; MStub.seen = []
    return Monitor(client: ProxyClient(protocolClasses: [MStub.self]), store: store,
                   management: ManagementClient(protocolClasses: [MStub.self]))
}
func v8Calls() -> [URLRequest] { MStub.seen.filter { $0.url!.path.hasPrefix("/v8/") } }
func body(_ r: URLRequest) -> [String: AnyHashable] {
    var data = r.httpBody
    if data == nil, let s = r.httpBodyStream {
        s.open(); defer { s.close() }
        var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        data = d
    }
    return (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: AnyHashable] ?? [:]
}
let ok: @Sendable (URLRequest) -> (Int, String) = { r in r.httpMethod == "GET" ? (200, credentials) : (200, "{}") }

@Suite(.serialized) @MainActor struct ManagementTests {
    @Test func decodesAllowlistedFields() async throws {
        let m = mgmtMonitor(MemStore("k"), ok)
        let c = try await m.management { try await $0.credentials(key: $1) }
        #expect(c.map(\.name) == ["claude-a.json", "claude-c.json", "codex-b.json", "xai-d.json"])
        #expect(c[0].nickname == "Work main"); #expect(c[0].priority == 10); #expect(c[0].status == .healthy)
        #expect(c[0].lastRefresh != nil); #expect(c[0].label == "Work main")
        #expect(c[1].status == .cooling); #expect(c[1].planLabel == "Max 20x"); #expect(c[1].priority == 0)
        #expect(c[1].retryAt == Account.parseDate("2026-11-06T19:00:00Z"))
        #expect(c[2].status == .disabled); #expect(c[2].disabled); #expect(c[2].planLabel == "Pro"); #expect(c[2].provider == .codex)
        #expect(c[3].status == .error); #expect(c[3].reason == "Sign-in expired or was revoked"); #expect(c[3].priority == 0)
        #expect(c[3].provider == .other); #expect(c[3].providerName == "xai"); #expect(c[3].label == "xai-d")
    }

    @Test func writesSendExactRoutes() async throws {
        let m = mgmtMonitor(MemStore("k"), ok)
        try await m.management { try await $0.setNickname(" Team  one ", name: "claude-a.json", key: $1) }
        try await m.management { try await $0.setPriority(-100, name: "claude-a.json", key: $1) }
        try await m.management { try await $0.setDisabled(true, name: "claude-a.json", key: $1) }
        try await m.management { try await $0.refresh(name: "claude-a.json", key: $1) }
        try await m.management { try await $0.resetCooldown(name: "claude-c.json", key: $1) }
        let calls = v8Calls().map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == ["PATCH /v8/management/credentials/fields", "PATCH /v8/management/credentials/fields",
                          "PATCH /v8/management/credentials/status", "POST /v8/management/credentials/refresh",
                          "GET /v8/management/credentials", "POST /v8/management/routing/cooldown/reset"])
        let s = v8Calls()
        #expect(body(s[0]) == ["name": "claude-a.json", "note": "Team one"])
        #expect(body(s[1]) == ["name": "claude-a.json", "priority": -100])
        #expect(body(s[2]) == ["name": "claude-a.json", "disabled": true])
        #expect(body(s[3]) == ["name": "claude-a.json"])
        #expect(body(s[5]) == ["auth_index": "ai-3"])
        #expect(s.allSatisfy { $0.url!.host == "127.0.0.1" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer k" })
        #expect(s.filter { $0.httpMethod != "GET" }.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
    }

    @Test func emptyNicknameClears() async throws {
        let m = mgmtMonitor(MemStore("k"), ok)
        try await m.management { try await $0.setNickname("  ", name: "claude-a.json", key: $1) }
        #expect(body(v8Calls()[0]) == ["name": "claude-a.json", "note": ""])
    }

    @Test func invalidInputSendsNothing() async {
        let m = mgmtMonitor(MemStore("k"), ok)
        for n in ["../x.json", ".json", "x..y.json", "-a.json", "abc.txt", "a b.json", "a/b.json", ""] {
            await #expect(throws: ManagementError.invalidName) { try await m.management { try await $0.setDisabled(true, name: n, key: $1) } }
        }
        await #expect(throws: ManagementError.invalidPriority) { try await m.management { try await $0.setPriority(101, name: "claude-a.json", key: $1) } }
        await #expect(throws: ManagementError.invalidPriority) { try await m.management { try await $0.setPriority(-101, name: "claude-a.json", key: $1) } }
        await #expect(throws: ManagementError.nicknameTooLong) {
            try await m.management { try await $0.setNickname(String(repeating: "x", count: 61), name: "claude-a.json", key: $1) }
        }
        #expect(MStub.seen.isEmpty)
        #expect(ManagementRules.isValidFileName("claude-user@example.com.json"))
    }

    @Test func noKeySendsNothing() async {
        let m = mgmtMonitor(MemStore(nil), ok)
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.credentials(key: $1) } }
        #expect(MStub.seen.isEmpty)
    }

    @Test func rejectionLocksAllManagementUntilKeyChanges() async throws {
        let m = mgmtMonitor(MemStore("bad")) { r in r.url!.path.isEmpty ? (200, root) : (401, "{}") }
        await #expect(throws: ProxyError.unauthorized) { try await m.management { try await $0.setDisabled(true, name: "claude-a.json", key: $1) } }
        #expect(m.management == .rejected)
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.credentials(key: $1) } }
        await m.refresh()   // polling shares the lock
        #expect(MStub.seen.filter { !$0.url!.path.isEmpty }.count == 1)
        MStub.handler = { r in r.url!.path.isEmpty ? (200, root) : r.url!.path.hasPrefix("/v0") ? (200, files) : (200, credentials) }
        _ = await m.setKey("good")
        #expect(try await m.management { try await $0.credentials(key: $1) }.count == 4)
    }

    @Test func lockIsCheckedPerRequestEvenMidOperation() async {
        // The lookup GET succeeds, then a 401 elsewhere rejects the key before the POST.
        let m = mgmtMonitor(MemStore("k"), ok)
        let c = m.managementClient
        await #expect(throws: ManagementError.locked) {
            try await m.management { client, key in
                _ = try await client.credentials(key: key)
                c.gate.reject(key)
                try await client.resetCooldown(name: "claude-a.json", key: key)
            }
        }
        #expect(v8Calls().map(\.httpMethod) == ["GET"])
        #expect(m.management == .rejected)
    }

    @Test func hugeOrNonFinitePriorityDoesNotCrash() async throws {
        let m = mgmtMonitor(MemStore("k")) { _ in (200, #"{"files":[{"name":"a-x.json","provider":"claude","priority":1e300}]}"#) }
        #expect(try await m.management { try await $0.credentials(key: $1) }.first?.priority == 0)
    }

    @Test func forbiddenAlsoLocks() async {
        let m = mgmtMonitor(MemStore("k")) { _ in (403, "{}") }
        await #expect(throws: ProxyError.unauthorized) { try await m.management { try await $0.refresh(name: "claude-a.json", key: $1) } }
        #expect(m.management == .rejected)
    }

    @Test func resetCooldownForUnknownNameIsNotFound() async {
        let m = mgmtMonitor(MemStore("k"), ok)
        await #expect(throws: ManagementError.notFound) { try await m.management { try await $0.resetCooldown(name: "gone-z.json", key: $1) } }
        #expect(v8Calls().map(\.httpMethod) == ["GET"])
    }

    @Test func failedRefreshIsReported() async {
        let m = mgmtMonitor(MemStore("k")) { _ in (200, #"{"ok":true,"results":[{"id":"claude-a.json","success":false}]}"#) }
        await #expect(throws: ManagementError.refreshFailed) { try await m.management { try await $0.refresh(name: "claude-a.json", key: $1) } }
    }

    @Test func malformedListIsIncompatible() async {
        let m = mgmtMonitor(MemStore("k")) { _ in (200, "[]") }
        await #expect(throws: ProxyError.incompatible) { try await m.management { try await $0.credentials(key: $1) } }
    }

    @Test func baseIsAlwaysLoopback() {
        #expect(ManagementClient(endpoint: .init(port: 9999)).endpoint.base.absoluteString == "http://127.0.0.1:9999")
    }

    @Test func planCacheJoinsByProxyDeckAccountKey() throws {
        // Proxy Deck: sha256(auth_index) hex, first 12 characters.
        #expect(PlanCache.accountKey("abc") == "ba7816bf8f01")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("plans.json")
        try Data(#"{"ba7816bf8f01":{"plan":"max 20x","org":null,"orgId":"x","at":1},"aaaaaaaaaaaa":{"plan":"team","org":"AI-Robotix","at":1},"bbbbbbbbbbbb":{"plan":"pwned","org":"a@b.com"},"bad":{"plan":"pro"}}"#.utf8).write(to: f)
        let plans = PlanCache.load(path: f.path)
        #expect(plans["ba7816bf8f01"] == PlanInfo(plan: "max 20x", org: nil, observedAt: Date(timeIntervalSince1970: 0.001)))
        #expect(plans["aaaaaaaaaaaa"] == PlanInfo(plan: "team", org: "AI-Robotix", observedAt: Date(timeIntervalSince1970: 0.001)))
        #expect(plans["bbbbbbbbbbbb"] == nil)   // unknown plan word and an email as org are dropped
        #expect(plans["bad"] == nil)
        #expect(PlanCache.load(path: dir.appendingPathComponent("missing.json").path).isEmpty)
        var c = Credential(name: "claude-a.json", provider: .claude)
        c = c.with(PlanInfo(plan: "max 20x", org: "Org"))
        #expect(c.planLabel == "Max 20x"); #expect(c.org == "Org")
        let codex = Credential(name: "codex-a.json", provider: .codex, plan: "team").with(PlanInfo(plan: "pro", org: "W"))
        #expect(codex.plan == "team")   // the hub's own plan wins
    }
}
