import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct RoutingRulesTests {
    @Test func planGroupsAndPriorityDiff() {
        for p in ["pro", "plus", "max", "max 5x", "max 20x", "MAX 100x"] { #expect(PlanGroup.classify(p) == .subscription) }
        for p in ["team", "team premium", "business", "enterprise", "team_premium"] { #expect(PlanGroup.classify(p) == .team) }
        for p in ["free", "edu", "go", "unknown", "professional"] { #expect(PlanGroup.classify(p) == nil) }
        let list = [Credential(name: "pro.json", provider: .claude, plan: "pro"),
                    Credential(name: "team.json", provider: .codex, plan: "team", priority: 0),
                    Credential(name: "unknown.json", provider: .claude)]
        let d = PriorityRule().changes(list)
        #expect(d.count == 1 && d.first?.credential.name == "pro.json" && d.first?.priority == 10)
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(_ used: Double = 100, reset: Date? = nil, disabled: Bool = false, version: String? = "v1", plan: String = "team") -> RoutingAccount {
        var c = Credential(name: "team.json", provider: .claude, plan: plan, disabled: disabled)
        c.updatedMarker = version
        let q = QuotaReading(observedAt: now, windows: [.init(id: "five-hour", label: "Session", usedPercent: used, resetAt: reset)], models: [:], plan: plan)
        return RoutingAccount(credential: c, quota: q)
    }
    @Test func pauseThresholdAndProtection() {
        let reset = now.addingTimeInterval(300)
        for threshold in [95, 98, 100] {
            var s = TeamGuardState()
            #expect(s.evaluate(snapshot(Double(threshold), reset: reset), enabledCount: 2, threshold: threshold, now: now) == .pause(reset))
        }
        var s = TeamGuardState()
        #expect(s.evaluate(snapshot(99, reset: reset), enabledCount: 2, now: now) == .none)
        #expect(s.evaluate(snapshot(), enabledCount: 2, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: reset), enabledCount: 1, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: reset, plan: "pro"), enabledCount: 2, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: reset, disabled: true), enabledCount: 2, now: now) == .none)
    }
    @Test func ownPauseResumesOnceAndNoFlapping() {
        var s = TeamGuardState()
        let reset = now.addingTimeInterval(300)
        let a = snapshot(reset: reset)
        #expect(s.evaluate(a, enabledCount: 2, now: now) == .pause(reset))
        var paused = snapshot(reset: reset, disabled: true, version: "v2")
        s.confirmPause(paused.credential)
        #expect(s.evaluate(paused, enabledCount: 1, now: now) == .none)
        #expect(s.evaluate(paused, enabledCount: 1, now: reset) == .resume)
        paused.credential.disabled = false
        #expect(s.evaluate(paused, enabledCount: 2, now: reset) == .none)
        #expect(s.evaluate(a, enabledCount: 2, now: now) == .none)
    }
    @Test func hubMarkerDriftWhilePausedStillResumes() {
        // Regression: the hub bumps updated_at on its own (token refresh) while the account is disabled.
        // That used to cancel recovery and leave the Team account off after its window reset.
        let reset = now.addingTimeInterval(300)
        for confirmed in ["v2", "v1"] {   // v1: the hub did not bump the marker on the status write
            var s = TeamGuardState()
            _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
            s.confirmPause(snapshot(reset: reset, disabled: true, version: confirmed).credential)
            #expect(s.pause(for: snapshot().credential)?.ownedMarker != nil)
            #expect(s.evaluate(snapshot(reset: reset, disabled: true, version: "refreshed"), enabledCount: 1, now: now) == .none)
            #expect(s.evaluate(snapshot(reset: reset, disabled: true, version: "refreshed-again"), enabledCount: 1, now: reset) == .resume)
            #expect(s.recoveryNotices == nil)
        }
    }
    @Test func unverifiedWritesNeverResume() {
        let reset = now.addingTimeInterval(300)
        var s = TeamGuardState()
        _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
        #expect(s.evaluate(snapshot(reset: reset, disabled: true), enabledCount: 1, now: reset) == .none)
        #expect(s.pauses.isEmpty)
    }
    @Test func userEnableAndAppOverrideDropOwnership() {
        var s = TeamGuardState()
        let a = snapshot(reset: now.addingTimeInterval(300))
        _ = s.evaluate(a, enabledCount: 2, now: now)
        s.confirmPause(snapshot(disabled: true, version: "v2").credential)
        #expect(s.evaluate(a, enabledCount: 2, now: now) == .none)
        #expect(s.pauses.isEmpty)
        #expect(s.evaluate(a, enabledCount: 2, now: now) == .none)
        s.userOverride(a.credential)
        #expect(s.pauses.isEmpty)
    }
    @Test func weeklyLimitWinsAndStateSurvivesRestart() throws {
        var a = snapshot(100, reset: now.addingTimeInterval(300))
        a.quota.windows.append(.init(id: "seven-day", label: "Weekly", usedPercent: 100, resetAt: now.addingTimeInterval(1000)))
        var s = TeamGuardState()
        #expect(s.evaluate(a, enabledCount: 2, now: now) == .pause(now.addingTimeInterval(1000)))
        let recovered = try JSONDecoder().decode(TeamGuardState.self, from: JSONEncoder().encode(s))
        #expect(recovered == s)
    }
    @Test func modelValidationAndForbiddenPaths() throws {
        #expect(try RoutingValidation.modelNames(["claude-*", "claude-*", "gpt/5"]) == ["claude-*", "gpt/5"])
        for bad in ["", "a b", "sk-…abcd", "x•", "a\nb", String(repeating: "x", count: 201)] {
            #expect(throws: RoutingError.invalidModels) { try RoutingValidation.modelNames([bad]) }
        }
        #expect(throws: RoutingError.invalidModels) { try RoutingValidation.aliases([.init(name: "ok", alias: "bad alias")]) }
        #expect(throws: RoutingError.invalidModels) { try RoutingValidation.modelNames(Array(repeating: "ok", count: 501)) }
        #expect(throws: RoutingError.invalidProvider) { try RoutingValidation.provider("../management") }
        #expect(RoutingConfigField.allCases.map(\.rawValue) == ["model-alias", "excluded-models"])
        for path in ["management", "remote-management", "secret-key", "auth-dir"] {
            #expect(throws: RoutingError.invalidProvider) { try RoutingValidation.provider(path) }
            #expect(RoutingConfigField(rawValue: path) == nil)
            #expect(!ConfigSetting.allCases.contains { $0.rawValue.contains(path) })
        }
    }
}

/// This suite has its own stub to avoid CLStub/MStub races with other serialized suites.
final class RoutingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var transportError: URLError.Code?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let code = Self.transportError {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct ManagementRoutingTests {
    let config = #"{"access":{"api-keys":["sk-first-client-secret-1111","sk-second-client-secret-2222"]},"oauth":{"model-alias":{"claude":[{"name":"claude-a","alias":"a"}]},"excluded-models":{"codex":["bad-*"]}},"management":{"secret-key":"do-not-expose"}}"#
    func monitor(_ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> Monitor {
        RoutingStub.handler = h; RoutingStub.requests = []; RoutingStub.transportError = nil
        return Monitor(client: ProxyClient(protocolClasses: [RoutingStub.self]), store: MemStore("mgmt"), management: ManagementClient(protocolClasses: [RoutingStub.self]))
    }
    func body(_ r: URLRequest) throws -> NSDictionary { try #require(JSONSerialization.jsonObject(with: clBody(r)) as? NSDictionary) }

    @Test func configProjectionHidesExistingSecrets() async throws {
        let text = config
        let m = monitor { _ in (200, text) }
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        #expect(result.clientKeys.count == 2)
        #expect(result.clientKeys.map(\.masked) == ["sk-…1111", "sk-…2222"])
        #expect(result.aliases["claude"] == [.init(name: "claude-a", alias: "a")])
        let dump = String(describing: result)
        for secret in ["first-client", "second-client", "do-not-expose"] { #expect(!dump.contains(secret)) }
        #expect(result.clientKeys[0].reference != result.clientKeys[1].reference)
    }
    @Test func aliasesPatchOnlyChangedProviderLeaves() async throws {
        let text = config
        let m = monitor { r in (200, r.httpMethod == "GET" ? text : "{}") }
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        try await m.management {
            try await $0.applyModelRouting(provider: "claude", aliases: [.init(name: "claude-b", alias: "b", fork: true)], excluded: ["x", "x"], revision: result.revision, key: $1)
        }
        let request = try #require(RoutingStub.requests.last)
        #expect(request.httpMethod == "PATCH" && request.url?.path == "/v8/management/config")
        #expect(try body(request) == ["oauth": ["model-alias": ["claude": [["name": "claude-b", "alias": "b", "fork": true]]], "excluded-models": ["claude": ["x"]]]] as NSDictionary)
        #expect(RoutingStub.requests.count == 3) // projection, revision read, patch
    }
    @Test func modelNoOpAndInvalidSendNoPatch() async throws {
        let text = config
        let m = monitor { _ in (200, text) }
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        RoutingStub.requests = []
        await #expect(throws: RoutingError.invalidProvider) {
            try await m.management { try await $0.applyModelRouting(provider: "management.secret-key", aliases: [], excluded: [], revision: result.revision, key: $1) }
        }
        #expect(RoutingStub.requests.isEmpty)
        await #expect(throws: RoutingError.invalidModels) {
            try await m.management { try await $0.applyModelRouting(provider: "claude", aliases: [.init(name: "a b", alias: "b")], excluded: [], revision: result.revision, key: $1) }
        }
        #expect(RoutingStub.requests.isEmpty)
        await #expect(throws: ConfigError.nothingChanged) {
            try await m.management { try await $0.applyModelRouting(provider: "claude", aliases: result.aliases["claude"]!, excluded: [], revision: result.revision, key: $1) }
        }
        #expect(!RoutingStub.requests.contains { $0.httpMethod == "PATCH" })
    }
    @Test func clientAddPreservesExistingAndRemoveResolvesRef() async throws {
        let text = config
        let m = monitor { r in (200, r.httpMethod == "GET" ? text : "{}") }
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        try await m.management { try await $0.changeClientKey(.add("sk-brand-new-client-key"), revision: result.revision, key: $1) }
        #expect(try body(RoutingStub.requests.last!) == ["access": ["api-keys": ["sk-first-client-secret-1111", "sk-second-client-secret-2222", "sk-brand-new-client-key"]]] as NSDictionary)
        try await m.management { try await $0.changeClientKey(.remove(reference: result.clientKeys[0].reference), revision: result.revision, key: $1) }
        #expect(try body(RoutingStub.requests.last!) == ["access": ["api-keys": ["sk-second-client-secret-2222"]]] as NSDictionary)
        #expect(RoutingStub.requests.filter { $0.httpMethod == "PATCH" }.allSatisfy { $0.url?.path == "/v8/management/config" })
    }
    @Test func staleRevisionAndStaleReferencesRefuseWrites() async throws {
        let text = config
        let m = monitor { _ in (200, text) }
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        await #expect(throws: ConfigError.stale) {
            try await m.management { try await $0.changeClientKey(.add("sk-brand-new-client-key"), revision: "stale", key: $1) }
        }
        await #expect(throws: ConfigError.stale) {
            try await m.management { try await $0.applyModelRouting(provider: "claude", aliases: [], excluded: [], revision: "stale", key: $1) }
        }
        await #expect(throws: RoutingError.staleReference) {
            try await m.management { try await $0.changeClientKey(.remove(reference: "0:000000000000"), revision: result.revision, key: $1) }
        }
        // A reference from a different key at the same index must not resolve, even with a current revision.
        let replaced = text.replacingOccurrences(of: "first-client-secret", with: "replacement-secret")
        RoutingStub.handler = { _ in (200, replaced) }
        let fresh = try await m.management { try await $0.routingConfig(key: $1) }
        await #expect(throws: RoutingError.staleReference) {
            try await m.management { try await $0.changeClientKey(.remove(reference: result.clientKeys[0].reference), revision: fresh.revision, key: $1) }
        }
        #expect(!RoutingStub.requests.contains { $0.httpMethod == "PATCH" })
    }
    @Test func invalidAndDuplicateKeysRefuseWrites() async throws {
        let text = config
        let m = monitor { _ in (200, text) }
        for bad in ["short", "sk-…1111", "a b c d 123", "$(whoami)", "ab\n123456", "sk-abc123\n"] {
            await #expect(throws: RoutingError.invalidKey) {
                try await m.management { try await $0.changeClientKey(.add(bad), revision: "x", key: $1) }
            }
        }
        #expect(RoutingStub.requests.isEmpty)
        let result = try await m.management { try await $0.routingConfig(key: $1) }
        await #expect(throws: RoutingError.invalidKey) {
            try await m.management { try await $0.changeClientKey(.add("sk-first-client-secret-1111"), revision: result.revision, key: $1) }
        }
        #expect(!RoutingStub.requests.contains { $0.httpMethod == "PATCH" })
    }
    @Test func generatedKeysAreUniqueAndValid() throws {
        let keys = try (0..<20).map { _ in try ClientKeyGenerator.generate() }
        #expect(Set(keys).count == 20)
        for k in keys { #expect(k.hasPrefix("sk-") && k.count == 67); try RoutingValidation.clientKey(k) }
    }
    @Test func authGateLocksEveryRoutingRequest() async {
        let m = monitor { _ in (401, "") }
        await #expect(throws: ProxyError.unauthorized) { try await m.management { try await $0.routingConfig(key: $1) } }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.changeClientKey(.add("sk-brand-new-key"), revision: "x", key: $1) } }
        #expect(RoutingStub.requests.count == 1)
    }
    @Test func priorityWritesOnlyChangedAndRefusesStale() async throws {
        let entry = #"{"files":[{"name":"pro.json","provider":"claude","plan":"pro","priority":0,"updated_at":"2026-11-06T12:00:00Z"}]}"#
        let m = monitor { r in (200, r.httpMethod == "GET" ? entry : "{}") }
        let credentials = try await m.management { try await $0.credentials(key: $1) }
        let diff = PriorityRule().changes(credentials)
        try await m.management { try await $0.applyPriority(diff[0], key: $1) }
        #expect(try body(RoutingStub.requests.last!) == ["name": "pro.json", "priority": 10] as NSDictionary)
        RoutingStub.requests = []
        RoutingStub.handler = { _ in (200, entry.replacingOccurrences(of: "\"priority\":0", with: "\"priority\":5")) }
        await #expect(throws: RoutingError.staleCredential) { try await m.management { try await $0.applyPriority(diff[0], key: $1) } }
        #expect(RoutingStub.requests.count == 1 && RoutingStub.requests[0].httpMethod == "GET")
    }
}

extension RoutingRulesTests {
    @Test func staleTeamCannotOverrideFreshPro() {
        var a = snapshot(reset: now.addingTimeInterval(600), plan: "pro")
        a.quota.plan = "team"; a.quota.observedAt = now.addingTimeInterval(-301)
        let result = GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now)
        #expect(result.plan == "pro" && !result.unclear)
        a.credential.plan = result.plan
        var state = TeamGuardState()
        #expect(state.evaluate(a, enabledCount: 2, now: now) == .none)
    }
    @Test func conflictingPlansPreventPause() {
        var a = snapshot(reset: now.addingTimeInterval(600))
        a.quota.plan = "pro"
        let result = GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now)
        #expect(result.plan == "team" && result.unclear)
        a.planUnclear = result.unclear
        var state = TeamGuardState()
        #expect(state.evaluate(a, enabledCount: 2, now: now) == .none)
    }
    @Test func fallbackRequiresFreshMatchingIdentity() {
        var a = snapshot(); a.credential.plan = nil
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: false, now: now).plan == nil)
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now).plan == "team")
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now.addingTimeInterval(301)).plan == nil)
    }
    /// The hub never reports Claude plans: a Claude Team account is only recognised through its own profile read.
    @Test func claudeTeamRecognisedFromVerifiedProfile() {
        var a = snapshot(reset: now.addingTimeInterval(600)); a.credential.plan = nil; a.quota.plan = nil; a.quota.planInfo = nil
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now).plan == nil)
        let viaProfile = GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now,
                                           profile: ("team", now.addingTimeInterval(-3600)))
        #expect(viaProfile.plan == "team" && !viaProfile.unclear)
        // A profile read older than a day is not trusted.
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now,
                                  profile: ("team", now.addingTimeInterval(-25 * 3600))).plan == nil)
        // A fresh profile that disagrees with the credential makes the plan unclear (no pause).
        a.credential.plan = "pro"
        #expect(GuardPlan.resolve(a.credential, quota: a.quota, identityMatches: true, now: now,
                                  profile: ("team", now)).unclear)
    }
    func ownedPause() -> (TeamGuardState, RoutingAccount, Date) {
        var s = TeamGuardState()
        let reset = now.addingTimeInterval(300)
        _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
        let a = snapshot(reset: reset, disabled: true, version: "v2")
        s.confirmPause(a.credential)
        return (s, a, reset)
    }
    @Test func ownedPauseSurvivesUnknownPlanAndRestart() throws {
        var (s, a, reset) = ownedPause()
        a.credential.plan = nil; a.quota = .none
        s = try JSONDecoder().decode(TeamGuardState.self, from: JSONEncoder().encode(s))
        #expect(s.evaluate(a, enabledCount: 1, now: now) == .none)
        #expect(s.pause(for: a.credential) != nil)
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .resume)
        #expect(s.pause(for: a.credential)?.resumeStatus == .pending)
    }
    @Test func definitiveResumeFailureBacksOffAndReconciles() {
        var (s, a, reset) = ownedPause()
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .resume)
        s.resumeFailed(a.credential, failure: .definitive, now: reset)
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(59)) == .none)
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(60)) == .resume)
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(120)) == .none)
        a.credential.disabled = false; a.credential.updatedMarker = "v3"
        #expect(s.evaluate(a, enabledCount: 2, now: reset.addingTimeInterval(121)) == .none)
        #expect(s.pauses.isEmpty)
    }
    @Test func unauthorizedNeverAutomaticallyRetries() {
        var (s, a, reset) = ownedPause()
        _ = s.evaluate(a, enabledCount: 1, now: reset)
        s.resumeFailed(a.credential, failure: .unauthorized, now: reset)
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(3600)) == .none)
        #expect(s.pause(for: a.credential)?.resumeStatus == .authBlocked)
        #expect(s.requestManualResume(a.credential, now: reset) == false)
        #expect(GuardResumeResult.failure(ProxyError.unauthorized) == .unauthorized)
        #expect(GuardResumeResult.failure(ManagementError.locked) == .unauthorized)
    }
    @Test func ambiguousResumeRequiresConfirmationEvenAfterRestart() throws {
        var (s, a, reset) = ownedPause()
        _ = s.evaluate(a, enabledCount: 1, now: reset)
        s.resumeFailed(a.credential, failure: .ambiguous, now: reset)
        s = try JSONDecoder().decode(TeamGuardState.self, from: JSONEncoder().encode(s))
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(3600)) == .none)
        #expect(s.pause(for: a.credential)?.resumeStatus == .manual)
        #expect(s.requestManualResume(a.credential, now: reset) == true)
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .resume)
    }
    @Test func interruptedResumeRemainsPendingAfterRestart() throws {
        var (s, a, reset) = ownedPause()
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .resume)
        s = try JSONDecoder().decode(TeamGuardState.self, from: JSONEncoder().encode(s))
        #expect(s.evaluate(a, enabledCount: 1, now: reset.addingTimeInterval(3600)) == .none)
        #expect(s.pause(for: a.credential)?.resumeStatus == .pending)
        #expect(s.requestManualResume(a.credential, now: reset) == true)
        a.credential.authIndex = "replacement"
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .none)
        #expect(s.pauses.isEmpty)
    }
    @Test func changedMarkerKeepsPendingResumeForReconciliation() {
        var (s, a, reset) = ownedPause()
        _ = s.evaluate(a, enabledCount: 1, now: reset)
        a.credential.updatedMarker = "hub-refresh"
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .none)
        #expect(s.pause(for: a.credential)?.resumeStatus == .pending)
        #expect(s.requestManualResume(a.credential, now: reset) == true)
        #expect(s.evaluate(a, enabledCount: 1, now: reset) == .resume)
    }
    @Test func unverifiedPauseLeavesNoticeThatClearsOnceEnabled() {
        let reset = now.addingTimeInterval(300)
        var s = TeamGuardState()
        _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
        #expect(s.evaluate(snapshot(reset: reset, disabled: true), enabledCount: 1, now: now) == .none)
        let id = TeamGuardState.accountID(snapshot().credential)
        #expect(s.recoveryNotices?[id] != nil)
        _ = s.evaluate(snapshot(50, reset: reset), enabledCount: 2, now: reset)
        #expect(s.recoveryNotices == nil)
    }
    @Test func guardWriteLimiterUsesElapsedTimeAcrossAccounts() {
        var limiter = GuardWriteLimiter()
        #expect(limiter.reserve(at: 100) == true)
        #expect(limiter.reserve(at: 100) == false)
        #expect(limiter.reserve(at: 104.999) == false)
        #expect(limiter.reserve(at: 105) == true)
        #expect(limiter.reserve(at: 104) == false)
        limiter.completed(at: 110)
        #expect(limiter.reserve(at: 114.999) == false)
        #expect(limiter.reserve(at: 115) == true)
    }
    @Test func resumeFailureCertainty() {
        #expect(GuardResumeResult.failure(GuardTransportError.offline) == .definitive)
        #expect(GuardResumeResult.failure(ProxyError.http(503)) == .definitive)
        #expect(GuardResumeResult.failure(ProxyError.unreachable) == .ambiguous)
        #expect(GuardResumeResult.failure(ProxyError.http(400)) == .ambiguous)
    }
    @Test func unknownMarkerAndExpiredQuotaDoNotPause() {
        var s = TeamGuardState()
        #expect(s.evaluate(snapshot(reset: now.addingTimeInterval(300), version: nil), enabledCount: 2, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: now), enabledCount: 2, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: now.addingTimeInterval(-1)), enabledCount: 2, now: now) == .none)
        var future = snapshot(reset: now.addingTimeInterval(300))
        future.quota.observedAt = now.addingTimeInterval(10)
        #expect(s.evaluate(future, enabledCount: 2, now: now) == .none)
        #expect(s.pauses.isEmpty)
    }
    @Test func turningOffStopsPausesButReleasesOwnedPausesAtReset() {
        let reset = now.addingTimeInterval(300)
        var s = TeamGuardState()
        #expect(s.evaluate(snapshot(reset: reset), enabledCount: 2, enabled: false, now: now) == .none)
        #expect(s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now) == .pause(reset))
        let paused = snapshot(reset: reset, disabled: true, version: "v2")
        s.confirmPause(paused.credential)
        #expect(s.evaluate(paused, enabledCount: 1, enabled: false, now: now) == .none)
        #expect(s.evaluate(paused, enabledCount: 1, enabled: false, now: reset) == .resume)
    }
    @Test func newExhaustedWindowExtendsExistingPauseWithoutAnotherWrite() {
        let reset = now.addingTimeInterval(300), weekly = now.addingTimeInterval(1000)
        var s = TeamGuardState()
        _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
        var paused = snapshot(reset: reset, disabled: true, version: "v2")
        s.confirmPause(paused.credential)
        paused.quota.windows.append(.init(id: "weekly", label: "Weekly", usedPercent: 100, resetAt: weekly))
        #expect(s.evaluate(paused, enabledCount: 1, now: reset) == .none)
        #expect(s.pause(for: paused.credential)?.resetAt == weekly)
        #expect(s.evaluate(paused, enabledCount: 1, now: weekly) == .resume)
    }
    @Test func changedIdentityDropsOwnershipButPlanDoesNot() {
        for changedPlan in [false, true] {
            var s = TeamGuardState()
            let reset = now.addingTimeInterval(300)
            _ = s.evaluate(snapshot(reset: reset), enabledCount: 2, now: now)
            var paused = snapshot(reset: reset, disabled: true, version: "v2")
            s.confirmPause(paused.credential)
            if changedPlan { paused.credential.plan = "pro" } else { paused.credential.authIndex = "replacement" }
            #expect(s.evaluate(paused, enabledCount: 1, now: reset) == (changedPlan ? .resume : .none))
            #expect(s.pauses.isEmpty == !changedPlan)
        }
    }
    @Test func resumeRequiresAnOwnedPause() {
        var s = TeamGuardState()
        let a = snapshot(reset: now.addingTimeInterval(-1), disabled: true, version: "v2")
        #expect(s.evaluate(a, enabledCount: 1, now: now) == .none)
        s.confirmPause(a.credential)
        #expect(s.pauses.isEmpty)
    }
    @Test func manualOverrideRetainsWindowSuppressionAfterRestart() throws {
        var s = TeamGuardState()
        let a = snapshot(reset: now.addingTimeInterval(300))
        _ = s.evaluate(a, enabledCount: 2, now: now)
        s.userOverride(a.credential)
        var recovered = try JSONDecoder().decode(TeamGuardState.self, from: JSONEncoder().encode(s))
        #expect(recovered.evaluate(a, enabledCount: 2, now: now) == .none)
    }
}

extension ManagementRoutingTests {
    @Test func guardResumeDistinguishesOfflineFromAmbiguousTransport() async {
        for code in [URLError.cannotConnectToHost, .notConnectedToInternet, .timedOut, .networkConnectionLost] {
            let m = monitor { _ in (200, "{}") }
            RoutingStub.transportError = code
            do {
                try await m.management { try await $0.resumeGuardCredential(name: "team.json", key: $1) }
                Issue.record("Expected transport failure")
            } catch {
                let expected: GuardResumeFailure = [.cannotConnectToHost, .notConnectedToInternet].contains(code) ? .definitive : .ambiguous
                #expect(GuardResumeResult.failure(error) == expected)
            }
            #expect(RoutingStub.requests.count == 1)
        }
        RoutingStub.transportError = nil
    }
    @Test func guardResumeUsesStatusPatchAndAuthGate() async throws {
        for code in [401, 403] {
            let m = monitor { _ in (code, "") }
            await #expect(throws: ProxyError.unauthorized) {
                try await m.management { try await $0.resumeGuardCredential(name: "team.json", key: $1) }
            }
            await #expect(throws: ManagementError.locked) {
                try await m.management { try await $0.resumeGuardCredential(name: "team.json", key: $1) }
            }
            #expect(RoutingStub.requests.count == 1)
            let request = try #require(RoutingStub.requests.first)
            #expect(request.httpMethod == "PATCH" && request.url?.path == "/v8/management/credentials/status")
            #expect(try body(request) == ["name": "team.json", "disabled": false] as NSDictionary)
        }
    }
    @Test func guardResumeRetainsServerFailureForBackoff() async {
        let m = monitor { _ in (503, "") }
        do {
            try await m.management { try await $0.resumeGuardCredential(name: "team.json", key: $1) }
            Issue.record("Expected server failure")
        } catch { #expect(GuardResumeResult.failure(error) == .definitive) }
        #expect(RoutingStub.requests.count == 1)
    }
    @Test func rejectedRevisionReadNeverSendsPatchOrResendsKey() async throws {
        let text = config
        let m = monitor { _ in (200, text) }
        let read = try await m.management { try await $0.routingConfig(key: $1) }
        RoutingStub.requests = []
        RoutingStub.handler = { _ in (403, "") }
        await #expect(throws: ProxyError.unauthorized) {
            try await m.management { try await $0.changeClientKey(.remove(reference: read.clientKeys[0].reference), revision: read.revision, key: $1) }
        }
        await #expect(throws: ManagementError.locked) {
            try await m.management { try await $0.applyModelRouting(provider: "claude", aliases: [], excluded: [], revision: read.revision, key: $1) }
        }
        #expect(RoutingStub.requests.count == 1 && RoutingStub.requests[0].httpMethod == "GET")
    }
    @Test func nullOptionalCollectionsAndLegacyKeys() async throws {
        let text = #"{"api-keys":["sk-legacy-client-secret"],"oauth":{"model-alias":null,"excluded-models":null}}"#
        let m = monitor { r in (200, r.httpMethod == "GET" ? text : "{}") }
        let read = try await m.management { try await $0.routingConfig(key: $1) }
        #expect(read.aliases.isEmpty && read.excluded.isEmpty && read.clientKeys.count == 1)
        try await m.management { try await $0.changeClientKey(.add("sk-new-client-key"), revision: read.revision, key: $1) }
        #expect(try body(RoutingStub.requests.last!) == ["access": ["api-keys": ["sk-legacy-client-secret", "sk-new-client-key"]]] as NSDictionary)
    }
    @Test func malformedKeyListCannotBeOverwritten() async {
        let m = monitor { _ in (200, #"{"access":{"api-keys":["keep-me",123]}}"#) }
        await #expect(throws: ProxyError.incompatible) { try await m.management { try await $0.changeClientKey(.add("sk-new-client-key"), revision: "x", key: $1) } }
        #expect(RoutingStub.requests.count == 1 && RoutingStub.requests[0].httpMethod == "GET")
    }
}

extension ManagementRoutingTests {
    @Test func forbiddenProviderSegmentsSendNothing() async {
        let m = monitor { _ in (200, "{}") }
        for provider in ["management", "remote-management", "secret-key", "auth-dir", "claude\n"] {
            await #expect(throws: RoutingError.invalidProvider) {
                try await m.management { try await $0.applyModelRouting(provider: provider, aliases: [], excluded: [], revision: "x", key: $1) }
            }
        }
        #expect(RoutingStub.requests.isEmpty)
    }
}
