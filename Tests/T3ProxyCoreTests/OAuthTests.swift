import Foundation
import Testing
@testable import T3ProxyCore

/// Own stub so this suite can run in parallel with the others.
final class OStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with r: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        OStub.seen.append(request)
        let (code, headers, body) = OStub.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private func oauthMonitor(_ store: KeyStore, _ h: @escaping @Sendable (URLRequest) -> (Int, [String: String], String)) -> Monitor {
    OStub.handler = h; OStub.seen = []
    return Monitor(client: ProxyClient(protocolClasses: [OStub.self]), store: store,
                   management: ManagementClient(protocolClasses: [OStub.self]))
}
private func query(_ r: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
private func oauthRequestData(_ r: URLRequest) -> Data {
    if let data = r.httpBody { return data }
    guard let stream = r.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}
private let state = "abcDEF_123-xyz"
private let start = #"{"status":"ok","url":"https://claude.ai/oauth/authorize?code=true&client_id=x&state=abcDEF_123-xyz","state":"abcDEF_123-xyz","expires_in":300}"#

@Suite(.serialized) @MainActor struct OAuthTests {
    @Test func catalogMatchesProxyDeck() {
        #expect(OAuthProvider.allCases.map(\.rawValue) == ["claude", "codex", "antigravity", "xai", "devin", "kimi", "kimi-ai", "meta", "vertex"])
        #expect(OAuthProvider.allCases.filter { $0.method == .browser }.map(\.rawValue) == ["claude", "codex", "antigravity", "xai", "devin"])
        #expect(OAuthProvider.allCases.filter { $0.method == .deviceCode }.map(\.rawValue) == ["kimi", "kimi-ai", "meta"])
        #expect(OAuthProvider.vertex.method == .importFile)
        #expect(OAuthProvider.kimiAI.markName == "kimi" && OAuthProvider.meta.markName == "meta")
    }

    @Test func everySignInProviderUsesItsOwnHostAndQuery() async throws {
        for p in OAuthProvider.allCases where p.method != .importFile {
            let host = try #require(p.authHosts.sorted().first)
            let device = p.method == .deviceCode || p == .xai
            let response = "{\"url\":\"https://\(host)/authorize\",\"state\":\"\(state)\",\"expires_in\":300\(device ? ",\"user_code\":\"TEST-1234\",\"flow\":\"device\"" : "")}"
            let m = oauthMonitor(MemStore("k")) { _ in (200, [:], response) }
            let s = try await m.management { try await $0.startOAuth(p, key: $1) }
            #expect(s.provider == p && s.url.host == host)
            #expect(s.userCode == (device ? "TEST-1234" : nil))
            #expect(s.pollInterval == 2)
            let q = query(try #require(OStub.seen.first))
            #expect(q["provider"] == p.rawValue)
            #expect(q["is_webui"] == (p.method == .browser ? "true" : nil))
        }
    }

    @Test func deviceVerificationFieldsAndInterval() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in
            (200, [:], #"{"verification_uri":"https://auth.kimi.ai/device","verification_uri_complete":"https://auth.kimi.ai/device?user_code=TEST-1234","state":"abcDEF_123-xyz","user_code":"TEST-1234","expires_in":180,"interval":5}"#)
        }
        let s = try await m.management { try await $0.startOAuth(.kimiAI, key: $1) }
        #expect(s.url.path == "/device" && s.userCode == "TEST-1234" && s.expiresIn == 180 && s.pollInterval == 5)
        #expect(query(try #require(OStub.seen.first)) == ["provider": "kimi-ai"])
    }

    @Test func invalidDeviceCodeIsRefusedAndSessionCancelled() async throws {
        for code in ["", "bad code", "TEST-1234\n", String(repeating: "a", count: 33)] {
            let payload = try JSONSerialization.data(withJSONObject: ["url": "https://auth.meta.com/device", "state": state, "user_code": code])
            let response = String(decoding: payload, as: UTF8.self)
            let m = oauthMonitor(MemStore("k")) { r in (200, [:], r.httpMethod == "DELETE" ? #"{"cancelled":true}"# : response) }
            await #expect(throws: OAuthError.invalidDeviceCode) { try await m.management { try await $0.startOAuth(.meta, key: $1) } }
            #expect(OStub.seen.count == 2 && OStub.seen.last?.httpMethod == "DELETE")
        }
    }

    @Test func deviceURLRejectionAndCleanupUseTheSharedLock() async throws {
        let m = oauthMonitor(MemStore("k")) { r in
            r.httpMethod == "DELETE" ? (401, [:], "{}")
                : (200, [:], #"{"url":"https://evil.example/device","state":"abcDEF_123-xyz","user_code":"TEST-1234"}"#)
        }
        await #expect(throws: OAuthError.untrustedURL) { try await m.management { try await $0.startOAuth(.kimi, key: $1) } }
        #expect(m.management == .rejected)
        #expect(OStub.seen.count == 2 && OStub.seen.last?.httpMethod == "DELETE")
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.oauthStatus(state: state, key: $1) } }
        #expect(OStub.seen.count == 2)
    }

    @Test func statusSuccessAndCancelFlag() async throws {
        let m = oauthMonitor(MemStore("k")) { r in
            (200, [:], r.httpMethod == "DELETE" ? #"{"cancelled":false}"# : #"{"status":"ok"}"#)
        }
        #expect(try await m.management { try await $0.oauthStatus(state: state, key: $1) } == .ok)
        #expect(try await m.management { try await $0.cancelOAuth(state: state, key: $1) } == false)
        #expect(OStub.seen.last?.httpMethod == "DELETE")
        #expect(query(try #require(OStub.seen.last)) == ["state": state])
    }

    @Test func allNewHostsAreExactHTTPSOnly() {
        for p in [OAuthProvider.xai, .devin, .kimi, .kimiAI, .meta] {
            let host = p.authHosts.sorted()[0]
            #expect(OAuthRules.authURL("https://\(host)/device", for: p) != nil)
            for raw in ["http://\(host)/x", "https://\(host).evil.example/x", "https://evil.\(host)/x", "https://user@\(host)/x", "https://\(host):8443/x"] {
                #expect(OAuthRules.authURL(raw, for: p) == nil)
            }
        }
        #expect(OAuthRules.authURL("https://auth.kimi.com/device", for: .kimiAI) == nil)
        #expect(OAuthRules.authURL("https://accounts.x.ai/device", for: .devin) == nil)
    }

    @Test func importRequiresConfirmationAndValidObjectBeforeSending() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, [:], "{}") }
        let valid = Data(#"{"type":"service_account","project_id":"test-project"}"#.utf8)
        await #expect(throws: OAuthError.confirmationRequired) {
            try await m.management { try await $0.importOAuthFile(valid, name: "test.json", key: $1) }
        }
        for invalid in [Data("[]".utf8), Data("null".utf8), Data("invalid".utf8), Data("42".utf8), Data(repeating: 32, count: 256_001)] {
            await #expect(throws: OAuthError.invalidImport) {
                try await m.management { try await $0.importOAuthFile(invalid, name: "test.json", confirmed: true, key: $1) }
            }
        }
        for name in ["../test.json", "test.JSON", "bad\r\nname.json", "a.json\"", "a..json"] {
            await #expect(throws: OAuthError.invalidImport) {
                try await m.management { try await $0.importOAuthFile(valid, name: name, confirmed: true, key: $1) }
            }
        }
        await #expect(throws: OAuthError.invalidLocation) {
            try await m.management { try await $0.importOAuthFile(valid, name: "test.json", location: "us central1", confirmed: true, key: $1) }
        }
        #expect(OStub.seen.isEmpty)
        // Proxy Deck's cap is inclusive, in bytes.
        try OAuthRules.validateImport(Data(("{}" + String(repeating: " ", count: 255_998)).utf8), name: "test.json")
    }

    @Test func importSendsCheckedBytesAsMultipartToVertex() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, [:], "{}") }
        let data = Data(#"{"type":"service_account"}"#.utf8)
        try await m.management { try await $0.importOAuthFile(data, name: "test.json", location: " us-central1 ", confirmed: true, key: $1) }
        let r = try #require(OStub.seen.first)
        #expect(r.httpMethod == "POST" && r.url?.path == "/v8/management/oauth/import")
        #expect(query(r) == ["provider": "vertex"])
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let contentType = try #require(r.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let wire = String(decoding: oauthRequestData(r), as: UTF8.self)
        #expect(wire.contains("name=\"file\"; filename=\"test.json\"\r\nContent-Type: application/json\r\n\r\n{\"type\":\"service_account\"}\r\n"))
        #expect(wire.contains("name=\"location\"\r\n\r\nus-central1\r\n"))
        #expect(wire.hasSuffix("--\r\n"))
    }

    @Test func methodsCannotBeMixedAndImportSharesRejectedKeyLock() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (403, [:], "{}") }
        await #expect(throws: OAuthError.unsupportedMethod) { try await m.management { try await $0.startOAuth(.vertex, key: $1) } }
        await #expect(throws: OAuthError.unsupportedMethod) {
            try await m.management { try await $0.submitOAuthCallback(.kimi, redirectURL: "http://localhost/?code=x", key: $1) }
        }
        #expect(OStub.seen.isEmpty)
        await #expect(throws: ProxyError.unauthorized) {
            try await m.management { try await $0.importOAuthFile(Data("{}".utf8), name: "test.json", confirmed: true, key: $1) }
        }
        #expect(m.management == .rejected)
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.startOAuth(.meta, key: $1) } }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.cancelOAuth(state: state, key: $1) } }
        #expect(OStub.seen.count == 1)
    }

    @Test func startSendsProviderQueryAndValidatesURL() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, [:], start) }
        let s = try await m.management { try await $0.startOAuth(.claude, key: $1) }
        #expect(s.state == state && s.url.host == "claude.ai" && s.expiresIn == 300)
        let r = try #require(OStub.seen.first)
        #expect(r.httpMethod == "GET" && r.url!.path == "/v8/management/oauth/auth-url")
        #expect(query(r) == ["provider": "claude", "is_webui": "true"])
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(OStub.seen.count == 1)
    }

    @Test func untrustedAuthURLIsRefusedAndSessionCancelled() async throws {
        let m = oauthMonitor(MemStore("k")) { r in
            r.httpMethod == "DELETE" ? (200, [:], #"{"cancelled":true}"#)
                : (200, [:], #"{"url":"https://evil.example/claude.ai","state":"abcDEF_123-xyz"}"#)
        }
        await #expect(throws: OAuthError.untrustedURL) { try await m.management { try await $0.startOAuth(.claude, key: $1) } }
        let c = try #require(OStub.seen.last)
        #expect(c.httpMethod == "DELETE" && c.url!.path == "/v8/management/oauth/session" && query(c) == ["state": state])
    }

    @Test func badStateFromHubIsRejected() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, [:], #"{"url":"https://claude.ai/x","state":"a b"}"#) }
        await #expect(throws: OAuthError.invalidState) { try await m.management { try await $0.startOAuth(.claude, key: $1) } }
        #expect(OStub.seen.count == 1)
    }

    @Test func authURLAllowlist() {
        #expect(OAuthRules.authURL("https://claude.ai/oauth/authorize?x=1", for: .claude) != nil)
        #expect(OAuthRules.authURL("https://console.anthropic.com/oauth", for: .claude) != nil)
        #expect(OAuthRules.authURL("https://auth.openai.com/oauth/authorize", for: .codex) != nil)
        #expect(OAuthRules.authURL("https://accounts.google.com/o/oauth2/auth", for: .antigravity) != nil)
        #expect(OAuthRules.authURL("https://AUTH.OPENAI.COM:443/x", for: .codex) != nil)
        for bad in ["http://claude.ai/x", "https://claude.ai.evil.com/x", "https://evil.claude.ai/x", "https://user@claude.ai/x",
                    "https://claude.ai:8443/x", "javascript:alert(1)", "file:///etc/passwd", "https://auth.openai.com/x", "", "claude.ai/x"] {
            #expect(OAuthRules.authURL(bad, for: .claude) == nil, "\(bad)")
        }
    }

    @Test func stateRule() {
        #expect(OAuthRules.isValidState("abcdefgh"))
        #expect(OAuthRules.isValidState(String(repeating: "a", count: 128)))
        for bad in ["short", "has space1", "a/b/c/d/e", "abc&def=1", String(repeating: "a", count: 129), "abcdefg\n", "abcdefgh\n"] {
            #expect(!OAuthRules.isValidState(bad))
        }
    }

    @Test func statusPollAndMessageAllowlist() async throws {
        let m = oauthMonitor(MemStore("k")) { r in
            query(r)["state"] == state ? (200, [:], #"{"status":"wait"}"#) : (200, [:], #"{"status":"error","error":"boom token=secret"}"#)
        }
        #expect(try await m.management { try await $0.oauthStatus(state: state, key: $1) } == .wait)
        #expect(OStub.seen[0].url!.path == "/v8/management/oauth/status" && OStub.seen[0].httpMethod == "GET")
        let e = try await m.management { try await $0.oauthStatus(state: "otherstate", key: $1) }
        #expect(e == .error("The hub reported that sign-in did not finish."))
        #expect(OAuthRules.statusMessage("Access denied") == "Access denied")
        await #expect(throws: OAuthError.invalidState) { try await m.management { try await $0.oauthStatus(state: "x&y", key: $1) } }
        #expect(OStub.seen.count == 2)
    }

    @Test func callbackBody() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, [:], "{}") }
        try await m.management { try await $0.submitOAuthCallback(.claude, redirectURL: "  http://localhost:54545/callback?code=c&state=s ", key: $1) }
        let r = try #require(OStub.seen.first)
        #expect(r.httpMethod == "POST" && r.url!.path == "/v0/management/oauth-callback")
        #expect(body(r) == ["provider": "anthropic", "redirect_url": "http://localhost:54545/callback?code=c&state=s"])
        await #expect(throws: OAuthError.invalidRedirect) {
            try await m.management { try await $0.submitOAuthCallback(.codex, redirectURL: "http://localhost/cb?foo=1", key: $1) }
        }
        #expect(!OAuthRules.isValidRedirect("ftp://h/?code=1") && !OAuthRules.isValidRedirect("not a url"))
        #expect(OStub.seen.count == 1)
    }

    @Test func versionsReadHeaderAndBody() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (200, ["X-CPA-Version": "8.0.55"], #"{"latest-version":"v8.1.0"}"#) }
        let v = try await m.management { try await $0.versions(key: $1) }
        #expect(v == HubVersionInfo(current: "8.0.55", latest: "v8.1.0"))
        #expect(OStub.seen.first?.url?.path == "/v8/management/server/latest-version")
        let bad = oauthMonitor(MemStore("k")) { _ in (200, ["X-CPA-Version": "<script>"], #"{"latest-version":"nope"}"#) }
        #expect(try await bad.management { try await $0.versions(key: $1) } == HubVersionInfo(current: nil, latest: nil))
    }

    @Test func unauthorizedLocksEverything() async throws {
        let m = oauthMonitor(MemStore("k")) { _ in (401, [:], "{}") }
        await #expect(throws: ProxyError.unauthorized) { try await m.management { try await $0.oauthStatus(state: state, key: $1) } }
        #expect(m.management == .rejected)
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.startOAuth(.codex, key: $1) } }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.versions(key: $1) } }
        #expect(OStub.seen.count == 1)
    }

    @Test func noKeySendsNothing() async throws {
        let m = oauthMonitor(MemStore(nil)) { _ in (200, [:], start) }
        await #expect(throws: ManagementError.locked) { try await m.management { try await $0.startOAuth(.claude, key: $1) } }
        #expect(OStub.seen.isEmpty)
    }
}
