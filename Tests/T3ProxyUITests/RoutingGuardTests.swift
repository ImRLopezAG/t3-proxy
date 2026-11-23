import Foundation
import Synchronization
import Testing
import T3ProxyCore
@testable import T3ProxyUI

@Suite(.serialized) @MainActor struct RoutingGuardTests {
    @Test(arguments: [200, 503])
    func acknowledgedPauseSurvivesFailedReadBackAndRestart(readBackStatus: Int) async throws {
        let domain = "T3ProxyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let now = Date()
        let reset = now.addingTimeInterval(3600)
        GuardHubStub.scenario.withLock {
            $0 = .init(observedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-10)),
                       resetAt: Int(reset.timeIntervalSince1970), readBackStatus: readBackStatus)
        }
        let monitor = Monitor(client: ProxyClient(protocolClasses: [GuardHubStub.self]), store: GuardTestKey(),
                              management: ManagementClient(protocolClasses: [GuardHubStub.self]))
        await monitor.refresh()
        try #require(monitor.management == .connected)

        let guardModel = RoutingGuard(monitor: monitor, defaults: defaults)
        await guardModel.refresh()
        try #require(GuardHubStub.scenario.withLock { $0.statusWrites } == 1)

        let restored = RoutingGuard(monitor: monitor, defaults: defaults)
        #expect(restored.state.pauses.values.first?.confirmationDeadline != nil)
        await restored.refresh()
        let paused = try #require(restored.credentials.first { $0.name == "team.json" })
        #expect(paused.disabled)
        #expect(restored.pause(for: paused)?.ownedMarker != nil)
        #expect(GuardHubStub.scenario.withLock { $0.statusWrites } == 1)
        var recovered = restored.state
        let resetAt = try #require(restored.pause(for: paused)?.resetAt)
        #expect(recovered.evaluate(.init(credential: paused, quota: .none), enabledCount: 1, now: resetAt) == .resume)
    }

    @Test func pendingPauseCanOnlyBeConfirmedByItsOriginalHub() async throws {
        let domain = "T3ProxyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let now = Date()
        GuardHubStub.scenario.withLock {
            $0 = .init(observedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-10)),
                       resetAt: Int(now.addingTimeInterval(3600).timeIntervalSince1970), readBackStatus: 503)
        }
        let original = ProxyEndpoint(port: 8317)
        let monitor = Monitor(client: ProxyClient(endpoint: original, protocolClasses: [GuardHubStub.self]),
                              store: GuardTestKey(),
                              management: ManagementClient(endpoint: original, protocolClasses: [GuardHubStub.self]))
        await monitor.refresh()
        let guardModel = RoutingGuard(monitor: monitor, defaults: defaults)
        await guardModel.refresh()
        try #require(guardModel.state.pauses.values.first?.confirmationDeadline != nil)

        await monitor.setEndpoint(.init(port: 8327))
        await guardModel.refresh()
        let otherHubAccount = try #require(guardModel.credentials.first { $0.name == "team.json" })
        #expect(otherHubAccount.disabled)
        #expect(guardModel.pause(for: otherHubAccount) == nil)

        await monitor.setEndpoint(original)
        await guardModel.refresh()
        let originalAccount = try #require(guardModel.credentials.first { $0.name == "team.json" })
        #expect(guardModel.pause(for: originalAccount)?.ownedMarker != nil)
        #expect(GuardHubStub.scenario.withLock { $0.statusWrites } == 1)
    }

    @Test func migrationPreservesExistingPauseForConfiguredHub() throws {
        let domain = "T3ProxyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        var account = Credential(name: "team.json", provider: .codex, plan: "team")
        account.updatedMarker = "2026-01-01T00:00:00Z"
        let window = QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 100, resetAt: reset)
        let quota = QuotaReading(observedAt: now, windows: [window], models: [:], plan: "team")
        var legacy = TeamGuardState()
        try #require(legacy.evaluate(.init(credential: account, quota: quota), enabledCount: 2, now: now) == .pause(reset))
        account.disabled = true
        legacy.confirmPause(account)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "routing.guard.state")

        let monitor = Monitor(client: ProxyClient(endpoint: .init(port: 8327)), store: GuardTestKey())
        let migrated = RoutingGuard(monitor: monitor, defaults: defaults)
        #expect(migrated.state == legacy)
        #expect(defaults.data(forKey: "routing.guard.state") == nil)
        #expect(RoutingGuard(monitor: monitor, defaults: defaults).state == legacy)
    }
}

private struct GuardTestKey: KeyStore {
    func load() -> String? { "test-key" }
    func save(_ key: String) -> Bool { false }
    func remove() {}
}

private final class GuardHubStub: URLProtocol, @unchecked Sendable {
    struct Scenario {
        let observedAt: String
        let resetAt: Int
        let readBackStatus: Int
        var statusWrites = 0
        var didSendReadBack = false

        mutating func respond(to request: URLRequest) -> (Int, String) {
            switch (request.httpMethod, request.url?.path) {
            case ("GET", ""), ("GET", "/"): return (200, "CLI Proxy API")
            case ("PATCH", "/v8/management/credentials/status"):
                statusWrites += 1
                return (200, "{}")
            case ("GET", "/v0/management/auth-files"):
                return (200, accounts(disabled: statusWrites > 0 || request.url?.port == 8327))
            case ("GET", "/v8/management/credentials"):
                if request.url?.port == 8327 { return (200, accounts(disabled: true)) }
                if statusWrites > 0 && !didSendReadBack {
                    didSendReadBack = true
                    return (readBackStatus, accounts(disabled: false))
                }
                return (200, accounts(disabled: statusWrites > 0))
            default: return (404, "{}")
            }
        }

        func accounts(disabled: Bool) -> String {
            let marker = disabled ? "2026-01-01T00:01:00Z" : "2026-01-01T00:00:00Z"
            return """
            {"files":[
              {"name":"team.json","provider":"codex","plan_type":"team","auth_index":"team-index",
               "id_token":{"chatgpt_account_id":"test-team-account"},
               "disabled":\(disabled),"updated_at":"\(marker)",
               "quota":{"observed_at":"\(observedAt)","signals":{
                 "x-codex-primary-used-percent":"100","x-codex-primary-window-minutes":"10080",
                 "x-codex-primary-reset-at":"\(resetAt)"}}},
              {"name":"pro.json","provider":"codex","plan_type":"pro","auth_index":"pro-index",
               "disabled":false,"updated_at":"2026-01-01T00:00:00Z"}
            ]}
            """
        }
    }

    static let scenario = Mutex(Scenario(observedAt: "", resetAt: 0, readBackStatus: 200))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.scenario.withLock { $0.respond(to: request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
