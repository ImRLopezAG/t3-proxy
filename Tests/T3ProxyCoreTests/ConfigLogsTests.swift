import Foundation
import Testing
@testable import T3ProxyCore

/// Shaped like a live 8.0.55 `/v8/management/config` answer (field names observed, values invented),
/// plus a provider group in the v8 `api-keys` map.
let configJSON = #"""
{"config-version":1,
 "access":{"api-keys":["sk-client-aaaaaaaaaaaa1111","client-two-secret"]},
 "management":{"allow-remote":false,"disable-control-panel":true,"secret-key":"mgmt-secret-value"},
 "server":{"host":"127.0.0.1","port":8317,"commercial-mode":false,"tls":{"enable":false,"cert":"","key":"tls-key-path"}},
 "requests":{"proxy-url":"socks5://bob:p%40ss@proxy.local:1080","passthrough-headers":true,"nonstream-keepalive-interval":15},
 "routing":{"strategy":"round-robin","force-model-prefix":false,"session-affinity":true,"session-affinity-ttl":"30m",
   "retry":{"request-retry":3,"max-retry-interval":30,"max-retry-credentials":"oops"},
   "cooldown":{"disable-cooling":false,"save-cooldown-status":true,"transient-error-cooldown-seconds":60}},
 "observability":{"logs":{"debug":false,"logging-to-file":true,"error-logs-max-files":10,"logs-max-total-size-mb":100},
   "usage":{"usage-statistics-enabled":false}},
 "quota-exceeded":{"switch-project":true,"switch-preview-model":false},
 "plugins":{"enabled":true,"dir":"/x"},
 "api-keys":{"openai-compatibility":[{"name":"router","base-url":"https://user:pw@api.example.com/v1?key=abc","prefix":"rt9",
   "headers":{"X-Api-Token":"hdr-secret-123","X-Forward":"$X-Forward"},
   "models":[{"name":"m1","alias":"a1"}],"excluded-models":["bad"],
   "api-key-entries":[{"api-key":"sk-provider-zzzzzzzz9999","weight":2,"proxy-url":"http://u:v@p:1"}]}],
   "BAD KEY":[{"name":"x"}]}}
"""#

/// Separate from MStub/Stub so suites can run in parallel.
final class CLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with r: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        CLStub.seen.append(request)
        let (code, body) = CLStub.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor func clMonitor(_ key: String? = "the-mgmt-key", _ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> Monitor {
    CLStub.handler = h; CLStub.seen = []
    return Monitor(client: ProxyClient(protocolClasses: [CLStub.self]), store: MemStore(key),
                   management: ManagementClient(protocolClasses: [CLStub.self]))
}
func clBody(_ r: URLRequest) -> Data {
    if let b = r.httpBody { return b }
    guard let s = r.httpBodyStream else { return Data() }
    s.open(); defer { s.close() }
    var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
    while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
    return d
}

@Suite(.serialized) @MainActor struct ConfigLogsTests {
    @Test func summaryDecodesAndMasks() async throws {
        let m = clMonitor { _ in (200, configJSON) }
        let s = try await m.management { try await $0.configSummary(key: $1) }
        #expect(s.routingStrategy == "round-robin" && s.requestRetry == 3 && s.maxRetryCredentials == nil)
        #expect(s.loggingToFile == true && s.usageStatistics == false && s.switchProject == true && s.port == 8317)
        #expect(s.managementKeySet && s.clientKeys == 2 && s.panelDisabled == true)
        #expect(s.proxyURL == "socks5://••••@proxy.local:1080")
        #expect(s.providers.count == 1)
        let g = try #require(s.providers.first)
        #expect(g.provider == "openai-compatibility" && g.name == "router" && g.prefix == "rt9")
        #expect(g.baseURL == "https://••••@api.example.com/v1?••••")
        #expect(g.headers == ["X-Api-Token": "••••", "X-Forward": "$X-Forward"])
        #expect(g.keys == [ProviderKeyView(masked: "sk-…9999", weight: 2, proxyURL: "http://••••@p:1")])
        #expect(g.models.map(\.alias) == ["a1"] && g.excludedModels == ["bad"])
        // Nothing secret survives anywhere in the projection.
        let dump = String(describing: s)
        for secret in ["mgmt-secret-value", "sk-client", "client-two-secret", "p%40ss", "hdr-secret", "zzzzzzzz", "user:pw", "key=abc"] {
            #expect(!dump.contains(secret), "leaked \(secret)")
        }
        #expect(s.revision.count == 16)
    }

    @Test func maskRules() {
        #expect(ConfigMask.key("short") == "••••")
        #expect(ConfigMask.key("abcdefghijklmnop") == "…mnop")
        #expect(ConfigMask.url("http://h:1/x?a=1") == "http://h:1/x?a=1")
        #expect(ConfigMask.url("http://h/x?token=1") == "http://h/x?••••")
    }

    @Test func togglePatchBodyAndRevision() async throws {
        let m = clMonitor { r in (200, r.httpMethod == "GET" ? configJSON : "{}") }
        let s = try await m.management { try await $0.configSummary(key: $1) }
        try await m.management { try await $0.applySettings([.usageStatistics: .bool(true)], revision: s.revision, key: $1) }
        let patch = try #require(CLStub.seen.last)
        #expect(patch.httpMethod == "PATCH" && patch.url?.path == "/v8/management/config")
        let json = try JSONSerialization.jsonObject(with: clBody(patch)) as? NSDictionary
        #expect(json == ["observability": ["usage": ["usage-statistics-enabled": true]]] as NSDictionary)
        let multi = try ConfigSetting.patch([.loggingToFile: .bool(false), .debug: .bool(true), .strategy: .text("fill-first"),
                                             .requestRetry: .int(5), .sessionAffinityTTL: .text("30m")])
        #expect(multi as NSDictionary == ["observability": ["logs": ["logging-to-file": false, "debug": true]],
                                          "routing": ["strategy": "fill-first", "session-affinity-ttl": "30m",
                                                      "retry": ["request-retry": 5]]] as NSDictionary)
    }

    @Test func settingValidation() {
        #expect(ConfigSetting.requestRetry.validated(.int(101)) == nil)
        #expect(ConfigSetting.requestRetry.validated(.int(-1)) == nil)
        #expect(ConfigSetting.requestRetry.validated(.text("3")) == nil)
        #expect(ConfigSetting.strategy.validated(.text("random")) == nil)
        #expect(ConfigSetting.sessionAffinityTTL.validated(.text("1h")) != nil)
        #expect(ConfigSetting.sessionAffinityTTL.validated(.text("1 hour")) == nil)
        #expect(ConfigSetting.sessionAffinityTTL.validated(.text("\u{0661}h")) == nil) // Arabic-Indic digit
        #expect(ConfigSetting.sessionAffinityTTL.validated(.text("\u{FF11}h")) == nil) // full-width digit
        #expect(ConfigSetting.debug.validated(.int(1)) == nil)
        #expect(throws: ConfigError.invalidValue(.strategy)) { try ConfigSetting.patch([.strategy: .text("x")]) }
        // Nothing outside the allowlist is expressible.
        let paths = ConfigSetting.allCases.map(\.rawValue)
        #expect(!paths.contains { $0.range(of: #"(^|\.)(management|remote-management|secret-key|auth-dir|host|port|tls|api-keys|proxy-url)(\.|$)"#, options: .regularExpression) != nil })
    }

    @Test func invalidOrUnchangedSendsNothing() async throws {
        let m = clMonitor { r in (200, r.httpMethod == "GET" ? configJSON : "{}") }
        let s = try await m.management { try await $0.configSummary(key: $1) }
        CLStub.seen.removeAll()
        await #expect(throws: ConfigError.invalidValue(.requestRetry)) {
            try await m.management { try await $0.applySettings([.requestRetry: .int(1000)], revision: s.revision, key: $1) }
        }
        #expect(CLStub.seen.isEmpty)
        if let same = s.value(.debug) {
            await #expect(throws: ConfigError.nothingChanged) {
                try await m.management { try await $0.applySettings([.debug: same], revision: s.revision, key: $1) }
            }
        }
        #expect(!CLStub.seen.contains { $0.httpMethod == "PATCH" })
    }

    @Test func staleRevisionSendsNoPatch() async {
        let m = clMonitor { r in (200, r.httpMethod == "GET" ? configJSON : "{}") }
        await #expect(throws: ConfigError.stale) {
            try await m.management { try await $0.applySettings([.loggingToFile: .bool(false)], revision: "0000000000000000", key: $1) }
        }
        #expect(!CLStub.seen.contains { $0.httpMethod == "PATCH" })
    }

    @Test func noKeySendsNothing() async {
        let m = clMonitor(nil) { _ in (200, configJSON) }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.logsTail(key: $1) } }
        #expect(CLStub.seen.isEmpty)
    }

    @Test func rejectedKeyLocks() async {
        let m = clMonitor { _ in (401, "") }
        await #expect(throws: ProxyError.unauthorized) { try await m.management { try await $0.configSummary(key: $1) } }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.errorLogs(key: $1) } }
        #expect(CLStub.seen.count == 1)
    }

    @Test func modelDefinitions() async throws {
        let body = #"{"channel":"claude","models":[{"id":"claude-x","display_name":"Claude X","context_length":200000},{"id":"bad id"},{"id":"y"}]}"#
        let m = clMonitor { _ in (200, body) }
        let list = try await m.management { try await $0.modelDefinitions(channel: "claude", key: $1) }
        #expect(list == [ModelDefinition(id: "claude-x", name: "Claude X", context: 200000), ModelDefinition(id: "y", name: "y", context: nil)])
        #expect(CLStub.seen.last?.url?.path == "/v8/management/routing/model-definitions/claude")
        await #expect(throws: ConfigError.invalidChannel) { try await m.management { try await $0.modelDefinitions(channel: "../x", key: $1) } }
    }

    // MARK: - Redaction

    @Test func configSecretsCollectsEverySecret() throws {
        let s = try LogRedactor.configSecrets(Data(configJSON.utf8))
        for x in ["sk-client-aaaaaaaaaaaa1111", "client-two-secret", "mgmt-secret-value", "sk-provider-zzzzzzzz9999",
                  "bob:p%40ss", "bob", "p%40ss", "p@ss", "tls-key-path", "u:v"] {
            #expect(s.contains(x), "missing \(x)")
        }
        #expect(s == s.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
        #expect(throws: ProxyError.incompatible) { try LogRedactor.configSecrets(Data("[1]".utf8)) }
        #expect(throws: ProxyError.incompatible) { try LogRedactor.configSecrets(Data(#"{"access":"x"}"#.utf8)) }
    }

    @Test func redactPatterns() {
        let r = { LogRedactor.redact($0, secrets: ["mysecretvalue"]) }
        #expect(!r("Cookie: theme=dark; session=private-session-value").contains("private-session-value"))
        #expect(!r(#"Cookie: session="private-cookie-value"; other=private-other"#).contains("private"))
        #expect(!r("GET /callback?code=private-auth-code&state=private-state HTTP/1.1").contains("private-auth-code"))
        #expect(!r("GET /callback?code=private-auth-code&state=private-state HTTP/1.1").contains("private-state"))
        #expect(!r("next=%2Fcb%3Fcode%3Dprivate-enc-code%26state%3Dx").contains("private-enc-code"))
        #expect(r("value mysecretvalue here") == "value [redacted] here")
        #expect(r(#"{"access_token":"abc\"def","x":1}"#) == #"{"access_token":"[redacted]","x":1}"#)
        #expect(r(#"{\"refresh_token\":\"abc\"}"#) == #"{\"refresh_token\":\"[redacted]\"}"#)
        #expect(r("'password': 'hunter2'") == "'password': '[redacted]'")
        #expect(r("Authorization: Bearer abcdefghijkl") == "Authorization: [redacted]")
        #expect(r("using Bearer abcdefghijkl now") == "using Bearer [redacted] now")
        #expect(r("key sk-ant-abcdefgh123 used") == "key [redacted] used")
        // Header-style rule runs first and takes the rest of the query, as in Proxy Deck.
        #expect(r("GET /x?api_key=zzz&a=1") == "GET /x?api_key=[redacted]")
        #expect(r("GET /x?key=zzz&a=1") == "GET /x?key=[redacted]&a=1")
        #expect(r("x-goog-api-key: AIzaSyXXXX") == "x-goog-api-key: [redacted]")
        #expect(r("[2026-10-29 19:58:01] [info ] plain line") == "[2026-10-29 19:58:01] [info ] plain line")
    }

    @Test func parseAndFilterLines() {
        let a = LogLine("[2026-10-29 19:58:01] [f00dbabe] [info ] [gin_logger.go:93] hello")
        #expect(a.time == "2026-10-29 19:58:01" && a.requestID == "f00dbabe" && a.level == .info && a.message == "[gin_logger.go:93] hello")
        let b = LogLine("[2026-10-29 19:58:02] [--------] [WARNING] slow")
        #expect(b.requestID == nil && b.level == .warn)
        let c = LogLine("panic: something")
        #expect(c.time == nil && c.level == .error)
        #expect(LogLine.filter([a, b, c], level: .warn, query: "").count == 1)
        #expect(LogLine.filter([a, b, c], level: nil, query: "HELLO") == [a])
    }

    @Test func tailRedactsCapsAndValidatesCursor() async throws {
        let cursorJSON = #"{"v":1,"file":"main.log","offset":10,"size":20,"modTime":5,"modTimeUnixNano":1793700000123456789,"latestTimestamp":7,"fingerprint":"ab"}"#
        let cursor = Data(cursorJSON.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let long = String(repeating: "x", count: 5000)
        let tail = #"{"lines":["a mgmt-secret-value b","the-mgmt-key in line","\#(long)"],"latest-timestamp":99,"line-count":3,"next-cursor":"\#(cursor)"}"#
        let m = clMonitor { r in r.url!.path == "/v8/management/config" ? (200, configJSON) : (200, tail) }
        let t = try await m.management { try await $0.logsTail(limit: 99999, key: $1) }
        #expect(t.enabled && t.latest == 99 && t.cursor == cursor)
        #expect(t.lines[0] == "a [redacted] b" && t.lines[1] == "[redacted] in line")
        #expect(t.lines[2].count == LogLimits.maxLine + 1 && t.lines[2].hasSuffix("…"))
        let q = CLStub.seen.last!.url!.query ?? ""
        #expect(q == "limit=5000")
        _ = try await m.management { try await $0.logsTail(cursor: cursor, key: $1) }
        #expect(CLStub.seen.last!.url!.query == "cursor=\(cursor)")
        await #expect(throws: LogsError.invalidCursor) { try await m.management { try await $0.logsTail(cursor: "bm9wZQ", key: $1) } }
        #expect(LogLimits.validCursor(cursor) == cursor)
    }

    @Test func tailFailsClosedWithoutSecrets() async {
        let m = clMonitor { r in r.url!.path == "/v8/management/config" ? (200, "[]") : (200, #"{"lines":["x"]}"#) }
        await #expect(throws: ProxyError.incompatible) { try await m.management { try await $0.logsTail(key: $1) } }
        #expect(!CLStub.seen.contains { $0.url!.path == "/v8/management/observability/logs" })
    }

    @Test func loggingOffIsAState() async throws {
        let m = clMonitor { r in r.url!.path == "/v8/management/config" ? (200, configJSON) : (400, #"{"error":"logging to file disabled"}"#) }
        let t = try await m.management { try await $0.logsTail(key: $1) }
        #expect(!t.enabled && t.lines.isEmpty)
    }

    @Test func errorLogsAndText() async throws {
        let files = #"{"files":[{"name":"error-1.log","size":10,"modified":100},{"name":"../x","size":1},{"name":"error-2.log","modified":200}]}"#
        let m = clMonitor { r in
            switch r.url!.path {
            case "/v8/management/config": (200, configJSON)
            case "/v8/management/observability/logs/errors": (200, files)
            default: (200, "line with sk-provider-zzzzzzzz9999 and password=abc")
            }
        }
        let list = try await m.management { try await $0.errorLogs(key: $1) }
        #expect(list.map(\.name) == ["error-2.log", "error-1.log"])
        let t = try await m.management { try await $0.errorLog(name: "error-1.log", key: $1) }
        #expect(t.text == "line with [redacted] and password=[redacted]" && !t.truncated, "\(t.text)")
        #expect(CLStub.seen.last!.url!.path == "/v8/management/observability/logs/errors/error-1.log")
        _ = try await m.management { try await $0.requestLog(id: "abc_123", key: $1) }
        #expect(CLStub.seen.last!.url!.path == "/v8/management/observability/logs/requests/abc_123")
        await #expect(throws: LogsError.invalidName) { try await m.management { try await $0.errorLog(name: "../etc", key: $1) } }
        await #expect(throws: LogsError.invalidRequestID) { try await m.management { try await $0.requestLog(id: "a/b", key: $1) } }
        #expect(LogLimits.capText(LogText(name: "n", text: String(repeating: "a", count: LogLimits.textMax + 5), truncated: false)).truncated)
    }

    @Test func clearSendsDelete() async throws {
        let m = clMonitor { _ in (200, #"{"removed":3}"#) }
        let n = try await m.management { try await $0.clearLogs(key: $1) }
        #expect(n == 3 && CLStub.seen.last?.httpMethod == "DELETE")
    }
}
