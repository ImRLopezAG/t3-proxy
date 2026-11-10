import Foundation
import Testing
@testable import T3ProxyCore

final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with r: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Stub.seen.append(request)
        let (code, body) = Stub.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class MemStore: KeyStore, @unchecked Sendable {
    var key: String?
    init(_ k: String?) { key = k }
    func load() -> String? { key }
    func save(_ k: String) -> Bool { key = k; return true }
    func remove() { key = nil }
}
let root = "{\"message\":\"CLI Proxy API Server\"}"
let files = #"{"files":[{"name":"claude-a.json","provider":"claude","status":"active","path":"/secret","recent_requests":[{"time":"x","success":2,"failed":1},{"time":"y","success":4,"failed":0}]},{"name":"codex-b.json","type":"codex","disabled":true,"status":"disabled"},{"name":"claude-c.json","provider":"claude","unavailable":true,"status":"error","status_message":"rate limited","next_retry_after":"2026-11-06T20:00:00Z","recent_requests":[{"success":1}]}]}"#

@MainActor func monitor(_ store: KeyStore, _ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> Monitor {
    Stub.handler = h; Stub.seen = []
    return Monitor(client: ProxyClient(protocolClasses: [Stub.self]), store: store)
}
func mgmtCalls() -> [URLRequest] { Stub.seen.filter { $0.url!.path.hasPrefix("/v0/") } }

@Suite(.serialized) @MainActor struct MonitorTests {
    @Test func noKeySendsNoManagementRequest() async {
        let m = monitor(MemStore(nil)) { _ in (200, root) }
        await m.refresh()
        #expect(m.reachability == .live); #expect(m.management == .noKey); #expect(mgmtCalls().isEmpty)
    }
    @Test func rejectionStopsPollingUntilNewKey() async {
        let m = monitor(MemStore("bad")) { r in !r.url!.path.hasPrefix("/v0") ? (200, root) : (401, "{}") }
        await m.refresh(); await m.refresh(); await m.refresh()
        #expect(m.management == .rejected); #expect(mgmtCalls().count == 1)
        Stub.handler = { r in !r.url!.path.hasPrefix("/v0") ? (200, root) : (200, files) }
        #expect(await m.setKey("bad") == .previouslyRejected)   // same key is never resent
        m.removeKey(); #expect(await m.setKey("bad") == .previouslyRejected)
        #expect(mgmtCalls().count == 1)
        _ = await m.setKey("good")
        #expect(m.management == .connected); #expect(m.accounts.count == 3)
    }
    @Test func offlineSendsNoManagementRequest() async {
        let m = monitor(MemStore("k")) { _ in (500, "") }
        await m.refresh()
        #expect(m.reachability == .offline); #expect(mgmtCalls().isEmpty)
    }
    @Test func unrelatedServiceIsNotLive() async {
        let m = monitor(MemStore("k")) { _ in (200, "<html>") }
        await m.refresh()
        #expect(m.reachability == .offline)
    }
    @Test func keyIsBearerToLoopbackOnly() async {
        let m = monitor(MemStore("k1")) { r in !r.url!.path.hasPrefix("/v0") ? (200, root) : (200, files) }
        await m.refresh()
        let r = mgmtCalls()[0]
        #expect(r.url!.host == "127.0.0.1"); #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k1")
    }
    @Test func onlyReadOnlyRoutesAreCalled() async {
        let m = monitor(MemStore("k")) { r in !r.url!.path.hasPrefix("/v0") ? (200, root) : (200, files) }
        await m.refresh()
        #expect(Set(Stub.seen.map { $0.url!.path }) == ["", "/v0/management/auth-files"])
        #expect(Stub.seen.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func malformedBodyIsAFailureNotEmptyData() async {
        let m = monitor(MemStore("k")) { r in !r.url!.path.hasPrefix("/v0") ? (200, root) : (200, "[]") }
        await m.refresh()
        #expect(m.management == .failed("Unexpected response")); #expect(m.accountsUpdatedAt == nil)
    }
}

@Suite struct ModelTests {
    let accounts = try! JSONDecoder().decode(AuthFilesEnvelope.self, from: Data(files.utf8)).files.map(Account.init)
    @Test func classifiesHeld() {
        #expect(accounts[0].held == false)
        #expect(accounts[1].heldReason == "Disabled"); #expect(accounts[1].provider == .codex)
        #expect(accounts[2].heldReason == "Rate limited by the provider"); #expect(accounts[2].releaseAt != nil)
    }
    @Test func summaryAlignsToNewestBucket() {
        let s = summarize(accounts, .claude)
        #expect(s.requests == [3, 5]); #expect(s.total == 8); #expect(s.active == 1); #expect(s.held == 1)
    }
    @Test func compactFormat() {
        #expect(compact(950) == "950"); #expect(compact(2_460_000_000) == "2.5B"); #expect(compact(383_000_000) == "383M"); #expect(compact(2000) == "2K")
    }
}
