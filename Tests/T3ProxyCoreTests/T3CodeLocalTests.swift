import Foundation
import Testing
@testable import T3ProxyCore

/// Synthetic files only; every key below is invented.
@Suite struct T3CodeLocalTests {
    let secretA = "sk-synthetic-claude-0000000000000000"
    let secretB = "sk-synthetic-codex-1111111111111111"

    func tempHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3local-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func runtimeParsingAndExposure() throws {
        let r = try #require(T3CodeRuntime.parse(Data(#"{"version":1,"pid":4242,"host":"0.0.0.0","port":3773,"origin":"http://x","serverVersion":"0.9.1-nightly","startedAt":"2026-11-07T10:00:00.123Z"}"#.utf8)))
        #expect(r.pid == 4242 && r.port == 3773 && r.serverVersion == "0.9.1-nightly" && r.startedAt != nil)
        #expect(r.exposed)
        for h in ["127.0.0.1", "localhost", "::1", "[::1]"] {
            #expect(T3CodeRuntime.parse(Data(#"{"host":"\#(h)"}"#.utf8))?.exposed == false)
        }
        for h in ["192.168.1.4", "::", "my-mac.local"] {
            #expect(T3CodeRuntime.parse(Data(#"{"host":"\#(h)"}"#.utf8))?.exposed == true)
        }
        #expect(T3CodeRuntime.parse(Data("[]".utf8)) == nil)
        #expect(T3CodeRuntime.parse(Data(#"{"pid":"x","port":"y"}"#.utf8))?.pid == nil)
        #expect(T3CodeLocal.pidAlive(getpid()))
        #expect(!T3CodeLocal.pidAlive(0))
    }

    @Test func hubURLMatching() {
        for u in ["http://127.0.0.1:8317", "http://127.0.0.1:8317/v1", "http://localhost:8317/", "http://[::1]:8317/v1"] {
            #expect(T3CodeLocal.pointsAtHub(u), "\(u)")
        }
        for u in ["http://127.0.0.1:8318/v1", "http://127.0.0.1", "https://api.anthropic.com", "http://10.0.0.2:8317", "ftp://127.0.0.1:8317", "", "not a url"] {
            #expect(!T3CodeLocal.pointsAtHub(u), "\(u)")
        }
        #expect(!T3CodeLocal.pointsAtHub(nil))
    }

    @Test func claudeConfig() throws {
        let home = try tempHome()
        #expect(!T3CodeLocal.readClaude(home: home).fileFound)
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8317","ANTHROPIC_AUTH_TOKEN":"\#(secretA)"}}"#, home + "/settings.json")
        let c = T3CodeLocal.readClaude(home: home)
        #expect(c.fileFound && c.baseURL == "http://127.0.0.1:8317")
        #expect(c.keyDigest == T3CodeLocal.digest(secretA))
        #expect(!(c.keySource ?? "").contains(secretA))
        try write("not json", home + "/settings.json")
        let bad = T3CodeLocal.readClaude(home: home)
        #expect(bad.fileFound && bad.baseURL == nil && bad.keyDigest == nil)
    }

    @Test func codexVariants() throws {
        // env_key resolved from auth.json, provider table declared before and with quoted names.
        let home = try tempHome()
        #expect(!T3CodeLocal.readCodex(home: home, environment: [:]).fileFound)
        try write("""
            # comment
            model_provider = "cliproxy" # trailing
            notes = \"\"\"
            [model_providers.cliproxy]
            base_url = "http://evil:1"
            \"\"\"
            [[skills.config]]
            base_url = "http://ignored"
            [model_providers."cliproxy"]
            name = "CLIProxyAPI"
            base_url = 'http://127.0.0.1:8317/v1'
            env_key = "CLIPROXY_API_KEY"
            headers = { a = "b" }
            """, home + "/config.toml")
        try write(#"{"CLIPROXY_API_KEY":"\#(secretB)"}"#, home + "/auth.json")
        var c = T3CodeLocal.readCodex(home: home, environment: [:])
        #expect(c.baseURL == "http://127.0.0.1:8317/v1")
        #expect(c.keyDigest == T3CodeLocal.digest(secretB))
        #expect(c.keySource == "CLIPROXY_API_KEY from auth.json")
        #expect(!c.keyVerified) // Codex doesn't read a custom env_key from auth.json

        // proxy-key file fallback, then environment, then missing.
        try FileManager.default.removeItem(atPath: home + "/auth.json")
        try write(secretB + "\n", home + "/proxy-key")
        c = T3CodeLocal.readCodex(home: home, environment: [:])
        #expect(c.keyDigest == T3CodeLocal.digest(secretB))
        try FileManager.default.removeItem(atPath: home + "/proxy-key")
        c = T3CodeLocal.readCodex(home: home, environment: ["CLIPROXY_API_KEY": secretA])
        #expect(c.keyDigest == T3CodeLocal.digest(secretA) && c.keySource == "CLIPROXY_API_KEY from this app's environment" && !c.keyVerified)
        c = T3CodeLocal.readCodex(home: home, environment: [:])
        #expect(c.keyDigest == nil && c.keySource == "CLIPROXY_API_KEY (value not found)")

        // Inline bearer token; no model_provider means openai with no base_url.
        try write("model_provider = \"hub\"\n[model_providers.hub]\nbase_url = \"http://localhost:8317/v1\"\nexperimental_bearer_token = \"\(secretA)\"\n", home + "/config.toml")
        c = T3CodeLocal.readCodex(home: home, environment: [:])
        #expect(c.keyDigest == T3CodeLocal.digest(secretA) && T3CodeLocal.pointsAtHub(c.baseURL))
        try write("model = \"gpt\"\n", home + "/config.toml")
        c = T3CodeLocal.readCodex(home: home, environment: [:])
        #expect(c.baseURL == nil)
    }

    @Test func hubKeyDigests() throws {
        let cfg = Data(#"{"access":{"api-keys":["\#(secretA)","",7]}}"#.utf8)
        let set = try T3CodeLocal.clientKeyDigests(fromConfig: cfg)
        #expect(set == [T3CodeLocal.digest(secretA)])
        #expect(try T3CodeLocal.clientKeyDigests(fromConfig: Data(#"{"api-keys":["\#(secretB)"]}"#.utf8)) == [T3CodeLocal.digest(secretB)])
        #expect(T3CodeLocal.digest(" \(secretA)\n") == T3CodeLocal.digest(secretA))
    }

    /// End to end through files: checks, states, summary, and that no secret leaks into any string.
    @Test func inspectAndNoSecretsInStrings() async throws {
        let home = try tempHome()
        let paths = T3CodePaths(home: home)
        try write(#"{"pid":\#(getpid()),"host":"127.0.0.1","port":3773,"serverVersion":"1.0","startedAt":"2026-11-07T10:00:00Z"}"#, paths.runtime)
        try write("""
            {"providerInstances":{
              "claude_proxy":{"driver":"claudeAgent","displayName":"Claude Proxy","enabled":true,"config":{"homePath":"~/claude-home"}},
              "codex_proxy":{"driver":"codex","displayName":"Codex Proxy","enabled":true,"config":{"homePath":"~/codex-home"}},
              "off":{"driver":"codex","enabled":false,"config":{"homePath":"~/nope"}},
              "plain":{"driver":"claudeAgent","enabled":true,"config":{}}},
             "usageLimitSources":{"s":{"kind":"cliproxy","url":"http://127.0.0.1:1/t3","managementKey":"\(secretA)","enabled":true}}}
            """, paths.settings)
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8317","ANTHROPIC_AUTH_TOKEN":"\#(secretA)"}}"#, home + "/claude-home/settings.json")
        try write("model_provider = \"x\"\n[model_providers.x]\nbase_url = \"http://127.0.0.1:9999/v1\"\nexperimental_bearer_token = \"\(secretB)\"\n", home + "/codex-home/config.toml")

        let hub: T3CodeHubKeys = .digests([T3CodeLocal.digest(secretA)])
        let s = await T3CodeLocal.inspect(paths: paths) { hub }
        #expect(s.running && s.version == "1.0" && !s.exposed)
        let byID = Dictionary(uniqueKeysWithValues: s.checks.map { ($0.id, $0) })
        #expect(byID["claude_proxy.url"]?.state == .ok)
        #expect(byID["claude_proxy.key"]?.message == "Key accepted by the hub.")
        #expect(byID["codex_proxy.url"]?.state == .problem)
        #expect(byID["codex_proxy.key"]?.message == "Key not in the hub's client keys.")
        #expect(byID["limit.s"]?.state == .problem)
        #expect(byID["off.url"] == nil && byID["plain.url"] == nil)
        #expect(s.summary == "3 problems")

        let noKey = await T3CodeLocal.inspect(paths: paths) { .noKey }
        #expect(noKey.checks.first { $0.id == "claude_proxy.key" }?.message == "Can't check: no management key.")

        let strings = (s.checks + noKey.checks).flatMap { [$0.title, $0.message, $0.id] } + [s.summary, s.version ?? ""]
        for str in strings {
            #expect(!str.contains(secretA) && !str.contains(secretB) && !str.contains("synthetic"), "\(str.prefix(20))")
        }
    }

    @Test func summaryAndLimitLabel() {
        let settings = T3CodeSettings(instances: [], limitSources: [.init(id: "d", kind: "cliproxy", url: "http://127.0.0.1:8318/t3", enabled: true)])
        let s = T3CodeLocal.evaluate(runtime: nil, alive: false, settings: settings, configs: [:], hubKeys: .noKey, limitAnswers: ["d": true])
        let limit = s.checks.first { $0.id == "limit.d" }
        #expect(limit?.title == "T3 Code limit bars read from Proxy Deck (8318)")
        #expect(limit?.message == "Something answers at 127.0.0.1:8318.")
        #expect(!s.running && !s.runtimeFound)
        #expect(s.summary == "1 problem") // the "no instances" warning
    }

    @Test func loopbackIsLiteralOnly() {
        for h in ["127.0.0.1", "127.1.2.3", "localhost", "::1", "[::1]"] { #expect(T3CodeLocal.isLoopback(h), "\(h)") }
        for h in ["127.attacker.example", "127.0.0.1.nip.io", "127.0.0", "127.0.0.256", "128.0.0.1", "0.0.0.0", "localhost.evil.com", "１２７.0.0.1"] {
            #expect(!T3CodeLocal.isLoopback(h), "\(h)")
        }
        #expect(!T3CodeLocal.pointsAtHub("http://127.attacker.example:8317/v1"))
        #expect(T3CodeLocal.loopbackLiteral("localhost") == "127.0.0.1")
    }

    @Test func codexKeyFromLauncher() throws {
        let home = try tempHome()
        try write("model_provider = \"cliproxy\"\n[model_providers.cliproxy]\nbase_url = \"http://127.0.0.1:8317/v1\"\nenv_key = \"CLIPROXY_API_KEY\"\n", home + "/config.toml")
        try write(secretB + "\n", home + "/proxy-key")
        // A stale auth.json value must not win over what the launcher exports.
        try write(#"{"CLIPROXY_API_KEY":"\#(secretA)"}"#, home + "/auth.json")
        // Real layout: provider home is <user>/.codex-proxy and the launcher reads $HOME/.codex-proxy/proxy-key,
        // where $HOME is the user's home (the parent), not the provider home.
        let user = (home as NSString).deletingLastPathComponent
        let rel = (home as NSString).lastPathComponent
        try write("#!/bin/sh\nexport CLIPROXY_API_KEY=\"$(cat \"$HOME/\(rel)/proxy-key\")\"\nexec codex \"$@\"\n", home + "/codex")
        let c = T3CodeLocal.readCodex(home: home, launcher: home + "/codex", userHome: user, environment: [:])
        #expect(c.keyDigest == T3CodeLocal.digest(secretB) && c.keyVerified, "\(c.keySource ?? "")")
        #expect(!(c.keySource ?? "").contains(secretB))
        // No launcher export: the proxy-key file is only a candidate.
        try write("#!/bin/sh\nexec codex \"$@\"\n", home + "/codex")
        try FileManager.default.removeItem(atPath: home + "/auth.json")
        let d = T3CodeLocal.readCodex(home: home, launcher: home + "/codex", userHome: user, environment: [:])
        #expect(d.keyDigest == T3CodeLocal.digest(secretB) && !d.keyVerified)
    }

    @Test func invalidLimitSourceNeverEchoesRawText() {
        #expect(T3CodeLocal.hostPort("not a url with \(secretA)") == nil)
    }
}
