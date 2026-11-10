import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct LiveQuotaParserTests {
    @Test func claudeScopedLimitsAndSafety() throws {
        let data = Data(#"{"five_hour":{"utilization":140},"seven_day":{"utilization":"NaN"},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":42,"resets_at":"2026-11-08T00:00:00Z"}]}"#.utf8)
        let q = try LiveQuotaParser.usage(data, provider: .claude)
        #expect(q.source == .live)
        #expect(q.window(.session)?.usedPercent == 100)
        #expect(q.window(.weekly)?.usedPercent == nil)
        #expect(q.windows.contains { $0.label == "Weekly · Fable" && $0.usedPercent == 42 })
    }
}

private let lqNow = Date(timeIntervalSince1970: 1_794_000_000)
private func json(_ text: String) -> Data { Data(text.utf8) }
private func lqAccount(_ provider: Provider = .codex, index: String = "index-1") -> Account {
    Account(name: index, provider: provider, authIndex: index, chatgptAccountID: provider == .codex ? "acct-1" : nil)
}
private func listedCredit() throws -> ResetCredit {
    try LiveQuotaParser.resetCredits(json(#"{"credits":[{"id":"credit_1","status":"available","title":"Full reset"}]}"#), now: lqNow)[0]
}

extension LiveQuotaParserTests {
    @Test func claudeAllWindowsAndCreditPool() throws {
        let q = try LiveQuotaParser.usage(json(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":32},"seven_day_opus":{"utilization":44},"seven_day_sonnet":{"utilization":55},"seven_day_oauth_apps":{"utilization":66},"seven_day_cowork":{"utilization":77},"iguana_necktie":{"limit_dollars":100,"remaining_dollars":40,"utilization":60},"extra_usage":{"is_enabled":true,"utilization":22}}"#), provider: .claude, now: lqNow)
        #expect(q.windows.count == 8)
        #expect(q.credits?.limit == 100 && q.credits?.remaining == 40)
        #expect(q.window(.weekly)?.usedPercent == 32)
        #expect(q.windows.contains { $0.id == "seven-day-opus" && $0.kind == nil })
    }

    @Test func codexDurationClassificationAndExtras() throws {
        let q = try LiveQuotaParser.usage(json(#"{"plan_type":"pro","rate_limit":{"primary_window":{"limit_window_seconds":604800,"used_percent":53,"reset_after_seconds":123},"secondary_window":{"limit_window_seconds":0,"used_percent":100}},"code_review_rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":-3}},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":8}}}],"credits":{"balance":"12.5","has_credits":true,"unlimited":false},"rate_limit_reset_credits":{"available_count":3}}"#), provider: .codex, now: lqNow)
        #expect(q.plan == "pro" && q.availableResetCredits == 3)
        #expect(q.credits?.balance == 12.5 && q.credits?.hasCredits == true)
        #expect(q.window(.weekly)?.usedPercent == 53)
        #expect(q.window(.weekly)?.resetAt == lqNow.addingTimeInterval(123))
        #expect(q.window(.session) == nil)
        #expect(q.windows.map(\.id) == ["weekly", "code-review-five-hour", "spark-five-hour"])
        #expect(q.windows[1].usedPercent == 0)
    }

    @Test(arguments: ["NaN", "inf", "1e300", "garbage"])
    func garbageNumbers(_ value: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["rate_limit": ["primary_window": ["used_percent": value, "limit_window_seconds": value, "reset_at": value, "reset_after_seconds": value]], "credits": ["balance": value], "rate_limit_reset_credits": ["available_count": value]])
        let q = try LiveQuotaParser.usage(data, provider: .codex, now: lqNow)
        #expect(q.windows.first?.usedPercent == nil && q.windows.first?.resetAt == nil)
        #expect(q.credits?.balance == nil && q.availableResetCredits == nil)
    }

    @Test func booleanAndHugeDatesRejected() throws {
        let q = try LiveQuotaParser.usage(json(#"{"rate_limit":{"primary_window":{"used_percent":true,"reset_at":99999999999999,"reset_after_seconds":-1}},"rate_limit_reset_credits":{"available_count":true},"plan_type":"someone@example.com"}"#), provider: .codex)
        #expect(q.plan == nil && q.availableResetCredits == nil)
        #expect(q.windows[0].usedPercent == nil && q.windows[0].resetAt == nil)
        #expect(throws: LiveQuotaError.invalidResponse) { try LiveQuotaParser.usage(json("[]"), provider: .codex) }
        #expect(throws: LiveQuotaError.responseTooLarge) { try LiveQuotaParser.usage(Data(repeating: 32, count: LiveQuotaParser.maximumResponseBytes + 1), provider: .codex) }
    }

    @Test func plansAndOrganizations() throws {
        let max = try LiveQuotaParser.plan(json(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x","name":"me@example.com"}}"#), provider: .claude)
        #expect(max == PlanInfo(plan: "max 20x", org: nil))
        let team = try LiveQuotaParser.plan(json(#"{"organization":{"organization_type":"claude_team","seat_tier":"premium","name":"Studio"}}"#), provider: .claude)
        #expect(team == PlanInfo(plan: "team premium", org: "Studio"))
        let codex = json(#"{"accounts":{"acct-1":{"account":{"plan_type":"business","structure":"workspace","name":"me@example.com"}},"other":{"account":{"plan_type":"enterprise","name":"Other"}}}}"#)
        #expect(try LiveQuotaParser.plan(codex, provider: .codex, accountID: "acct-1") == PlanInfo(plan: "business", org: nil))
        #expect(try LiveQuotaParser.plan(codex, provider: .codex) == PlanInfo(plan: nil, org: nil))
        let dirty = json(#"{"accounts":{"acct-1":{"account":{"plan_type":"made_up","structure":"workspace","name":"Bad\u0007Name"}}}}"#)
        #expect(try LiveQuotaParser.plan(dirty, provider: .codex, accountID: "acct-1") == PlanInfo(plan: nil, org: nil))
    }

    @Test func creditSortingValidationAndExpiry() throws {
        let data = json(#"{"credits":[{"id":"forever","status":"available"},{"id":"later","status":"available","expires_at":"2026-12-01T00:00:00Z"},{"id":"soon","status":"available","expires_at":"2026-11-08T00:00:00Z","granted_at":"2026-11-01T00:00:00Z","title":"Full reset"},{"id":"bad/id","status":"available"},{"id":"used","status":"redeemed"},{"id":"pending","status":"redeeming"},{"id":"expired","status":"available","expires_at":"2020-01-01T00:00:00Z"},{"id":"broken","status":"available","expires_at":"wat"},{"id":"soon","status":"available"}]}"#)
        let list = try LiveQuotaParser.resetCredits(data, now: lqNow)
        #expect(list.map(\.id) == ["soon", "later", "forever"])
        #expect(list[0].grantedAt != nil && list[0].title == "Full reset" && list[0].status == "available")
        #expect(throws: LiveQuotaError.invalidResponse) { try LiveQuotaParser.resetCredits(json("{}")) }
    }

    @Test func accountAndCredentialClaims() throws {
        let data = json(#"{"name":"codex-a.json","provider":"codex","auth_index":"opaque-index","id_token":{"chatgpt_account_id":"acct-1","plan_type":"pro","email":"drop@example.com","access_token":"discard"}}"#)
        let a = Account(try JSONDecoder().decode(AuthFileEntry.self, from: data))
        #expect(a.authIndex == "opaque-index" && a.chatgptAccountID == "acct-1")
        let c = try #require(Credential(JSONDecoder().decode(CredentialEntry.self, from: data)))
        #expect(c.chatgptAccountID == "acct-1" && c.authIndex == a.authIndex)
    }

    @Test func poolGainWithSimultaneousResetsAndUnknowns() throws {
        var a = lqAccount(.claude, index: "a"), b = lqAccount(.claude, index: "b")
        a.quota = QuotaReading(observedAt: lqNow, windows: [.init(id: "five-hour", label: "Session", usedPercent: 80, resetAt: lqNow.addingTimeInterval(100))], models: [:], plan: nil)
        b.quota = QuotaReading(observedAt: lqNow, windows: [.init(id: "five-hour", label: "Session", usedPercent: 20, resetAt: lqNow.addingTimeInterval(100))], models: [:], plan: nil)
        let p = pooledQuota([a, b, lqAccount(.claude, index: "unknown")], .claude, .session, now: lqNow)
        #expect(p.remaining == 50 && p.resetGainPercent == 50 && p.unknown == 1)
        b.disabled = true
        #expect(pooledQuota([a, b], .claude, .session, now: lqNow).resetGainPercent == 80)
    }
}

/// Separate stub state from every other suite. A lock protects parallel URLSession callbacks.
private final class LQStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var hold: (@Sendable (LQStub) -> Void)?
    nonisolated(unsafe) private static var holdCount = 0
    static var seen: [URLRequest] { lock.withLock { requests } }
    static func configure(_ h: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.withLock { handler = h; requests = []; hold = nil; holdCount = 0 }
    }
    static func holdNext(_ count: Int, _ f: @escaping @Sendable (LQStub) -> Void) {
        lock.withLock { holdCount = count; hold = f }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let h = Self.lock.withLock { Self.requests.append(request); return Self.handler! }
        let holding = Self.lock.withLock { () -> (@Sendable (LQStub) -> Void)? in
            guard Self.holdCount > 0 else { return nil }
            Self.holdCount -= 1; return Self.hold
        }
        if let holding { holding(self); return }
        let (code, body) = h(request)
        complete(code, body)
    }
    func complete(_ code: Int, _ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class LQHeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [LQStub] = []
    private var arrived: CheckedContinuation<Void, Never>?
    func append(_ stub: LQStub) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            held.append(stub)
            guard held.count == 2 else { return nil }
            let result = arrived; arrived = nil; return result
        }
        continuation?.resume()
    }
    func waitForTwo() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { if held.count == 2 { return true }; arrived = c; return false }
            if ready { c.resume() }
        }
    }
    func release() {
        let list = lock.withLock { let list = held; held = []; return list }
        for stub in list { stub.complete(200, envelope("{}")) }
    }
}
private final class LQClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = lqNow
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private func requestBody(_ r: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: clBody(r))) as? [String: Any] ?? [:]
}
@MainActor private func lqMonitor(_ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> Monitor {
    LQStub.configure(h)
    return Monitor(client: ProxyClient(protocolClasses: [LQStub.self]), store: MemStore("test-management-key"), management: ManagementClient(protocolClasses: [LQStub.self]))
}
private func envelope(_ body: String, status: Int = 200) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["status_code": status, "body": body]), as: UTF8.self)
}

@Suite(.serialized) @MainActor struct LiveQuotaRequestTests {
    @Test func fixedTargetsAndRequestShape() async throws {
        let m = lqMonitor { _ in (200, envelope("{}")) }
        #expect(LiveQuotaTarget.allCases.count == 6)
        for target in LiveQuotaTarget.allCases where target != .codexConsume {
            _ = try await m.management { try await $0.liveQuotaRead(target, account: lqAccount(target.provider), key: $1) }
            let r = try #require(LQStub.seen.last), b = requestBody(r)
            #expect(r.url?.path == "/v0/management/api-call" && r.httpMethod == "POST")
            #expect(Set(b.keys) == Set(["authIndex", "method", "url", "header"]))
            #expect(b["authIndex"] as? String == "index-1" && b["url"] as? String == target.url && b["method"] as? String == "GET")
            let h = try #require(b["header"] as? [String: String])
            #expect(h["Authorization"] == "Bearer $TOKEN$")
            #expect(!h.values.contains("test-management-key"))
            if target.provider == .claude { #expect(h["anthropic-beta"] == "oauth-2025-04-20") }
            else { #expect(h["Chatgpt-Account-Id"] == "acct-1") }
        }
        await #expect(throws: LiveQuotaError.invalidCredit) { try await m.management { try await $0.liveQuotaRead(.codexConsume, account: lqAccount(), key: $1) } }
        #expect(LQStub.seen.count == 5)
    }

    @Test func objectEnvelopeAndUpstreamErrors() async throws {
        let m = lqMonitor { _ in (200, #"{"status_code":"200","body":{"five_hour":{"utilization":25}}}"#) }
        let data = try await m.management { try await $0.liveQuotaRead(.claudeUsage, account: lqAccount(.claude), key: $1) }
        #expect(try LiveQuotaParser.usage(data, provider: .claude).window(.session)?.usedPercent == 25)
        let failed = lqMonitor { _ in (200, envelope(#"{"error":"private upstream body"}"#, status: 429)) }
        await #expect(throws: LiveQuotaError.upstream(429)) { try await failed.management { try await $0.liveQuotaRead(.codexUsage, account: lqAccount(), key: $1) } }
    }

    @Test func invalidAccountsSendNothing() async throws {
        let m = lqMonitor { _ in (200, envelope("{}")) }
        var a = lqAccount(); a.disabled = true
        await #expect(throws: LiveQuotaError.invalidAccount) { try await m.management { try await $0.liveQuotaRead(.codexUsage, account: a, key: $1) } }
        a.disabled = false; a.chatgptAccountID = "bad\r\nheader"
        await #expect(throws: LiveQuotaError.invalidAccount) { try await m.management { try await $0.liveQuotaRead(.codexUsage, account: a, key: $1) } }
        #expect(LQStub.seen.isEmpty)
    }

    @Test(arguments: ["reset", "already_redeemed", "nothing_to_reset", "no_credit", "unknown"])
    func consumeCodesAndCooldown(_ code: String) async throws {
        let m = lqMonitor { r in
            r.url?.path == "/v0/management/reset-quota" ? (200, "{}") : (200, envelope("{\"code\":\"\(code)\",\"windows_reset\":2}"))
        }
        let service = LiveQuotaService(monitor: m)
        let prepared = try ResetCreditConfirmationStore().prepare(credit: listedCredit(), account: lqAccount())
        #expect(prepared.requestID.uuidString.split(separator: "-")[2].first == "4")
        let result = try await service.consume(account: lqAccount(), confirmed: prepared.confirm())
        let expected: ResetCreditResult = switch code {
        case "reset": .reset(windows: 2)
        case "already_redeemed": .alreadyRedeemed
        case "nothing_to_reset": .nothingToReset
        case "no_credit": .noCredit
        default: .failed
        }
        #expect(result == expected)
        #expect(LQStub.seen.count == (["reset", "already_redeemed"].contains(code) ? 2 : 1))
        let b = requestBody(LQStub.seen[0])
        #expect(b["method"] as? String == "POST" && b["url"] as? String == LiveQuotaTarget.codexConsume.url)
        let payload = try #require((b["data"] as? String).flatMap { try? JSONSerialization.jsonObject(with: json($0)) as? [String: String] })
        #expect(payload["credit_id"] == "credit_1" && payload["redeem_request_id"] == prepared.requestID.uuidString.lowercased())
        if LQStub.seen.count == 2 { #expect(requestBody(LQStub.seen[1])["auth_index"] as? String == "index-1") }
    }

    @Test func retryReusesIDAndConfirmationIsAccountBound() async throws {
        let m = lqMonitor { _ in (200, envelope(#"{"code":"nothing_to_reset"}"#)) }
        let service = LiveQuotaService(monitor: m), store = ResetCreditConfirmationStore()
        let credit = try listedCredit(), a = lqAccount()
        let first = try store.prepare(credit: credit, account: a)
        let retry = try store.prepare(credit: credit, account: a)
        #expect(first.requestID == retry.requestID)
        _ = try await service.consume(account: a, confirmed: first.confirm())
        _ = try await service.consume(account: a, confirmed: retry.confirm())
        #expect(requestBody(LQStub.seen[0])["data"] as? String == requestBody(LQStub.seen[1])["data"] as? String)
        await #expect(throws: LiveQuotaError.invalidCredit) { try await service.consume(account: lqAccount(index: "other"), confirmed: retry.confirm()) }
        var disabled = a; disabled.disabled = true
        await #expect(throws: LiveQuotaError.invalidAccount) { try await service.consume(account: disabled, confirmed: retry.confirm()) }
        await #expect(throws: LiveQuotaError.invalidAccount) { try await service.consume(account: lqAccount(.claude), confirmed: retry.confirm()) }
        #expect(LQStub.seen.count == 2)
    }

    @Test func rejectedKeyStopsEverySubsequentCall() async throws {
        let m = lqMonitor { _ in (401, "") }
        let service = LiveQuotaService(monitor: m)
        _ = await service.refresh([lqAccount()])
        await #expect(throws: ManagementError.locked) { try await service.resetCredits(lqAccount()) }
        _ = await service.refresh([lqAccount(.claude)])
        #expect(LQStub.seen.count == 1)
    }

    @Test func cacheMinimumIntervalAndPlanOnce() async throws {
        let clock = LQClock()
        let m = lqMonitor { r in
            let target = requestBody(r)["url"] as? String ?? ""
            return (200, envelope(target.contains("profile") ? #"{"organization":{"organization_type":"claude_pro"}}"# : #"{"five_hour":{"utilization":25}}"#))
        }
        let service = LiveQuotaService(monitor: m, clock: { clock.now }), a = lqAccount(.claude)
        let first = await service.refresh([a])
        #expect(first[a.id]?.source == .live && first[a.id]?.planInfo?.plan == "pro")
        #expect(LQStub.seen.count == 2)
        _ = await service.refresh([a]); clock.advance(59)
        _ = await service.refresh([a]); #expect(LQStub.seen.count == 2)
        clock.advance(1); _ = await service.refresh([a]); #expect(LQStub.seen.count == 3)
        var disabled = a; disabled.disabled = true
        #expect(await service.refresh([disabled, lqAccount(.other)]).isEmpty)
        #expect(LQStub.seen.count == 3)
    }

    @Test func failedReadsAreThrottled() async {
        let clock = LQClock(), m = lqMonitor { _ in (503, "") }
        let service = LiveQuotaService(monitor: m, clock: { clock.now })
        #expect(await service.refresh([lqAccount()]).isEmpty)
        _ = await service.refresh([lqAccount()]); #expect(LQStub.seen.count == 1)
        clock.advance(60); _ = await service.refresh([lqAccount()]); #expect(LQStub.seen.count == 2)
    }

    @Test func overlappingRefreshDeduplicates() async {
        let m = lqMonitor { _ in (200, envelope("{}")) }, clock = LQClock()
        let service = LiveQuotaService(monitor: m, clock: { clock.now })
        async let a = service.refresh([lqAccount()])
        async let b = service.refresh([lqAccount()])
        let (x, y) = await (a, b)
        #expect(x == y && LQStub.seen.count == 2)
    }

    @Test func successInvalidatesCacheEvenWhenCooldownFails() async throws {
        let m = lqMonitor { r in
            if r.url?.path == "/v0/management/reset-quota" { return (500, "") }
            let url = requestBody(r)["url"] as? String ?? ""
            return (200, envelope(url.hasSuffix("consume") ? #"{"code":"reset","windows_reset":2}"# : "{}"))
        }
        let service = LiveQuotaService(monitor: m), a = lqAccount()
        _ = await service.refresh([a]); #expect(LQStub.seen.count == 2)
        let confirmation = try ResetCreditConfirmationStore().prepare(credit: listedCredit(), account: a).confirm()
        #expect(try await service.consume(account: a, confirmed: confirmation) == .reset(windows: 2))
        #expect(service.cooldownClearFailed.contains(a.id))
        _ = await service.refresh([a]); #expect(LQStub.seen.count == 5)
    }
}

extension LiveQuotaRequestTests {
    @Test func atMostTwoHubCallsWhileOthersAreQueued() async {
        let m = lqMonitor { _ in (200, envelope("{}")) }, held = LQHeldRequests()
        LQStub.holdNext(2) { held.append($0) }
        let service = LiveQuotaService(monitor: m)
        let refresh = Task { await service.refresh((0..<5).map { lqAccount(index: "index-\($0)") }) }
        await held.waitForTwo()
        #expect(LQStub.seen.count == 2)
        held.release()
        let readings = await refresh.value
        #expect(readings.count == 5 && LQStub.seen.count == 10)
    }

    @Test(arguments: [true, false])
    func keyChangeWhileConsumeWaitsForSlotSendsNothing(changeKey: Bool) async throws {
        let m = lqMonitor { _ in (200, envelope("{}")) }, held = LQHeldRequests()
        LQStub.holdNext(2) { held.append($0) }
        let service = LiveQuotaService(monitor: m)
        let first = Task { try? await service.resetCredits(lqAccount(index: "first")) }
        let second = Task { try? await service.resetCredits(lqAccount(index: "second")) }
        await held.waitForTwo()
        let confirmation = try ResetCreditConfirmationStore().prepare(credit: listedCredit(), account: lqAccount()).confirm()
        var valid = true
        var consume: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            consume = Task { @MainActor in
                started.resume()
                await #expect(throws: CancellationError.self) {
                    try await service.consume(account: lqAccount(), confirmed: confirmation, revalidate: { valid })
                }
            }
        }
        if changeKey { _ = await m.setKey("replacement-management-key") } else { valid = false }
        let beforeRelease = LQStub.seen.count
        held.release()
        await first.value; await second.value; await consume?.value
        #expect(LQStub.seen.count == beforeRelease)
        #expect(!LQStub.seen.contains { requestBody($0)["url"] as? String == LiveQuotaTarget.codexConsume.url })
    }

    @Test func listUsesDedicatedTargetAndNeverConsumes() async throws {
        let m = lqMonitor { _ in (200, envelope(#"{"credits":[{"id":"grant","status":"available"}]}"#)) }
        let service = LiveQuotaService(monitor: m)
        #expect(try await service.resetCredits(lqAccount()).count == 1)
        #expect(LQStub.seen.count == 1)
        #expect(requestBody(LQStub.seen[0])["url"] as? String == LiveQuotaTarget.codexCredits.url)
    }

    @Test func networkRetryPreservesUUIDAndDoesNotClearCooldown() async throws {
        let m = lqMonitor { _ in (503, "") }, service = LiveQuotaService(monitor: m)
        let confirmation = try ResetCreditConfirmationStore().prepare(credit: listedCredit(), account: lqAccount()).confirm()
        for _ in 0..<2 {
            await #expect(throws: ProxyError.http(503)) { try await service.consume(account: lqAccount(), confirmed: confirmation) }
        }
        #expect(LQStub.seen.count == 2)
        #expect(requestBody(LQStub.seen[0])["data"] as? String == requestBody(LQStub.seen[1])["data"] as? String)
        #expect(LQStub.seen.allSatisfy { $0.url?.path == "/v0/management/api-call" })
    }

    @Test func wrapperSizeAndMalformedBody() async {
        let m = lqMonitor { _ in (200, envelope("not json")) }
        await #expect(throws: LiveQuotaError.invalidResponse) { try await m.management { try await $0.liveQuotaRead(.codexUsage, account: lqAccount(), key: $1) } }
        let large = lqMonitor { _ in (200, envelope(String(repeating: "x", count: LiveQuotaParser.maximumResponseBytes + 1))) }
        await #expect(throws: LiveQuotaError.responseTooLarge) { try await large.management { try await $0.liveQuotaRead(.codexUsage, account: lqAccount(), key: $1) } }
    }
}
