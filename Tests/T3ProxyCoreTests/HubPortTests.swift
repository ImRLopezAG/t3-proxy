import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct HubPortTests {
    func defaults() -> UserDefaults {
        let name = "hubport.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func parseAcceptsOnlyInRangeDigits() {
        #expect(HubPort.parse("8317") == 8317)
        #expect(HubPort.parse(" 1024 ") == 1024)
        #expect(HubPort.parse("65535") == 65535)
        for bad in ["", "1023", "65536", "0", "-1", "80", "8317a", "83.17", "+8317", "１２３４", "999999", "0x2000"] {
            #expect(HubPort.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func storedValueFallsBackWhenMissingOrInvalid() {
        let d = defaults()
        #expect(HubPort.current(d) == 8317)
        d.set(9000, forKey: HubPort.key); #expect(HubPort.current(d) == 9000)
        d.set(80, forKey: HubPort.key); #expect(HubPort.current(d) == 8317)
        d.set(70000, forKey: HubPort.key); #expect(HubPort.current(d) == 8317)
        d.set("junk", forKey: HubPort.key); #expect(HubPort.current(d) == 8317)
        d.set("9100", forKey: HubPort.key); #expect(HubPort.current(d) == 9100)
    }

    @Test func saveRejectsInvalidAndClearsDefault() {
        let d = defaults()
        #expect(HubPort.save(9001, d) && HubPort.current(d) == 9001)
        #expect(!HubPort.save(1, d) && HubPort.current(d) == 9001)
        #expect(HubPort.save(8317, d) && d.object(forKey: HubPort.key) == nil)
    }

    @Test func endpointBuiltFromSettingIsLoopback() {
        let d = defaults(); HubPort.save(9123, d)
        let e = ProxyEndpoint.configured(d)
        #expect(e.port == 9123 && e.label == "127.0.0.1:9123")
        #expect(e.base.absoluteString == "http://127.0.0.1:9123" && e.base.host == "127.0.0.1")
        #expect(ProxyEndpoint(port: 5).port == 8317)
        let c = ProxyClient(endpoint: e), m = ManagementClient(endpoint: e)
        #expect(c.endpoint.base.port == 9123 && m.endpoint.base.port == 9123)
    }

    @Test func hubCheckUsesConfiguredPort() {
        #expect(T3CodeLocal.pointsAtHub("http://127.0.0.1:9123/v1", port: 9123))
        #expect(!T3CodeLocal.pointsAtHub("http://127.0.0.1:8317/v1", port: 9123))
        let settings = T3CodeSettings.parse(Data(#"{"providerInstances":{"c":{"driver":"claudeAgent","displayName":"C","enabled":true,"config":{"homePath":"~/h"}}}}"#.utf8), home: "/tmp")
        #expect(settings?.instances.count == 1)
        let cfg = T3CodeProviderConfig(kind: .claude, configPath: "/tmp/h/settings.json", fileFound: true,
                                       baseURL: "http://127.0.0.1:9123", keySource: nil, keyDigest: nil)
        let on = T3CodeLocal.evaluate(runtime: nil, alive: false, settings: settings, configs: ["c": cfg], hubKeys: .noKey, limitAnswers: [:], hubPort: 9123)
        #expect(on.checks.first { $0.id == "c.url" }?.state == .ok)
        let off = T3CodeLocal.evaluate(runtime: nil, alive: false, settings: settings, configs: ["c": cfg], hubKeys: .noKey, limitAnswers: [:], hubPort: 8317)
        let check = off.checks.first { $0.id == "c.url" }
        #expect(check?.state == .problem && check?.message.contains("127.0.0.1:8317") == true)
    }
}

extension MonitorTests {
    /// A port change reconnects to the new loopback port, drops old accounts, and starts with a fresh key lock.
    @Test func portChangeReconnectsWithFreshGate() async {
        let m = monitor(MemStore("k")) { r in
            if r.url!.port == 8317 { return r.url!.path.hasPrefix("/v0") ? (401, "{}") : (200, root) }
            return r.url!.path.hasPrefix("/v0") ? (200, #"{"files":[]}"#) : (200, root)
        }
        await m.refresh()
        #expect(m.management == .rejected)
        let epoch = m.keyEpoch
        await m.setEndpoint(ProxyEndpoint(port: 9123))
        #expect(m.endpointLabel == "127.0.0.1:9123" && m.keyEpoch != epoch)
        #expect(m.client.endpoint.port == 9123 && m.managementClient.endpoint.port == 9123)
        #expect(m.management == .connected && m.reachability == .live)
        #expect(Stub.seen.allSatisfy { $0.url!.host == "127.0.0.1" })
        #expect(mgmtCalls().filter { $0.url!.port == 9123 }.count == 1)
    }
}

extension MonitorTests {
    /// Regression: a health check still running on the old port must not mark the new port live.
    @Test func staleHealthFromOldPortDoesNotPublish() async throws {
        let m = monitor(MemStore("k")) { r in
            if r.url!.port == 8317 { Thread.sleep(forTimeInterval: 0.3); return (200, root) }   // old hub: up, slow
            return (503, "{}")                                                                   // new port: down
        }
        let first = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(60))
        await m.setEndpoint(ProxyEndpoint(port: 9123))
        await first.value
        #expect(m.reachability != .live)                // the old hub's answer was dropped, not shown for 9123
        try await Task.sleep(for: .milliseconds(400))   // the queued refresh against the new port
        #expect(m.endpointLabel == "127.0.0.1:9123")
        #expect(m.reachability == .offline)
    }
}
