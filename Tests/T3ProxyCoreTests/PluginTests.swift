import Foundation
import Testing
@testable import T3ProxyCore

// Public hub response shapes, with invented metadata and secrets.
private let pluginList = #"""
{"plugins_enabled":true,"plugins_dir":"/private/hub/plugins","plugins":[
 {"id":"sample","enabled":true,"effective_enabled":false,"registered":false,
  "metadata":{"name":"Sample plugin","version":"1.0.0","author":"Example"},
  "config_fields":[{"name":"api_key","type":"string","default":"secret-default"},
   {"name":"limit","type":"integer","default":5},{"name":"mode","type":"string","enum_values":["fast","slow"]},
   {"name":"enabled","type":"boolean"},{"name":"options","type":"object"}]},
 {"id":"../escape","metadata":{"name":"Bad"}}]}
"""#
private let pluginStore = #"""
{"plugins_enabled":true,"sources":[{"id":"official","name":"Main","url":"https://example.com/store"}],
 "source_errors":[{"source_id":"broken","message":"secret-error-body"}],"plugins":[
 {"id":"sample","source_id":"official","source_name":"Main","version":"2.0.0","name":"Sample plugin",
  "installed":true,"installed_version":"1.0.0","update_available":true,"install_source_status":"matched",
  "platforms":[{"goos":"darwin","goarch":"arm64"}]},
 {"id":"sample","source_id":"other","version":"2.0.0","installed":true,"install_source_status":"mismatch"}]}
"""#
private let pluginConfig = #"""
{"management":{"secret-key":"management-secret"},"plugins":{"configs":{"sample":
 {"enabled":true,"api_key":"stored-secret","limit":8,"mode":"fast","options":{"token":"nested-secret"}}}}}
"""#

private final class PluginStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct PluginTests {
    private func monitor(key: String? = "test-key", status: Int = 200, conflict: Bool = false) -> Monitor {
        PluginStub.seen = []
        PluginStub.handler = { request in
            if status != 200 { return (status, "secret-error-body") }
            if request.httpMethod != "GET" {
                if request.httpMethod == "DELETE" { return (200, #"{"status":"deleted","id":"sample","restart_required":false}"#) }
                return conflict ? (409, #"{"error":"plugin_update_requires_restart","restart_required":true}"#)
                    : (200, #"{"status":"installed","id":"sample","restart_required":true}"#)
            }
            switch request.url!.path {
            case "/v8/management/plugins": return (200, pluginList)
            case "/v8/management/plugins/store": return (200, pluginStore)
            case "/v8/management/config": return (200, pluginConfig)
            default: return (404, "")
            }
        }
        return Monitor(client: ProxyClient(protocolClasses: [PluginStub.self]), store: MemStore(key),
                       management: ManagementClient(protocolClasses: [PluginStub.self]))
    }

    @Test func installedAndStoreProjection() async throws {
        let m = monitor()
        let list = try await m.management { try await $0.plugins(key: $1) }
        #expect(list.enabled && list.plugins.count == 1)
        #expect(list.plugins[0].name == "Sample plugin" && !list.plugins[0].active)
        let store = try await m.management { try await $0.pluginStore(key: $1) }
        #expect(store.plugins.count == 2 && Set(store.plugins.map(\.id)).count == 2)
        #expect(store.plugins[0].canInstall && !store.plugins[1].canInstall)
        #expect(store.failedSources == 1)
        #expect(!String(describing: store).contains("secret-error-body"))
        #expect(!String(describing: list).contains("/private/hub"))
    }

    @Test func configurationMasksSecretsAndSkipsReservedFields() async throws {
        let m = monitor()
        let config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        let key = try #require(config.fields.first { $0.id == "api_key" })
        #expect(key.secret && key.isSet && key.value == nil)
        #expect(!config.fields.contains { $0.id == "enabled" })
        #expect(config.fields.first { $0.id == "limit" }?.value == .number(8))
        for secret in ["stored-secret", "secret-default", "management-secret", "nested-secret"] {
            #expect(!String(describing: config).contains(secret))
        }
    }

    @Test func installPinsSourceAndVersionAndReturnsRestart() async throws {
        let m = monitor()
        let store = try await m.management { try await $0.pluginStore(key: $1) }
        let result = try await m.management { try await $0.installPlugin(store.plugins[0], key: $1) }
        #expect(result.restartRequired)
        let request = try #require(PluginStub.seen.last)
        #expect(request.httpMethod == "POST" && request.url?.path == "/v8/management/plugins/store/sample/install")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "source", value: "official")])
        #expect(try JSONSerialization.jsonObject(with: clBody(request)) as? NSDictionary == ["version":"2.0.0"] as NSDictionary)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(PluginStub.seen.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

    @Test func toggleUsesBareBooleanAndDeleteUsesSelectedID() async throws {
        let m = monitor()
        let plugin = try await m.management { try await $0.plugins(key: $1) }.plugins[0]
        try await m.management { try await $0.setPluginEnabled(plugin, enabled: false, key: $1) }
        let toggle = try #require(PluginStub.seen.last)
        #expect(toggle.httpMethod == "PUT" && toggle.url?.path == "/v8/management/config/plugins/configs/sample/enabled")
        #expect(String(data: clBody(toggle), encoding: .utf8) == "false")
        _ = try await m.management { try await $0.removePlugin(plugin, key: $1) }
        #expect(PluginStub.seen.last?.httpMethod == "DELETE")
        #expect(PluginStub.seen.last?.url?.path == "/v8/management/plugins/sample")
    }

    @Test func configPatchPreservesUntouchedSecrets() async throws {
        let m = monitor()
        let config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        try await m.management { try await $0.savePluginConfiguration(config, changes: ["limit": .number(12)], key: $1) }
        let patch = try #require(PluginStub.seen.last)
        #expect(patch.httpMethod == "PATCH" && patch.url?.path == "/v8/management/config/plugins/configs/sample")
        #expect(try JSONSerialization.jsonObject(with: clBody(patch)) as? NSDictionary == ["limit":12] as NSDictionary)
        await #expect(throws: PluginError.invalidValue) {
            try await m.management { try await $0.savePluginConfiguration(config, changes: ["mode": .text("invalid")], key: $1) }
        }
    }

    @Test func staleConfigurationAndSelectionPreventWrites() async throws {
        let m = monitor()
        var config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        config.revision = "old"
        await #expect(throws: PluginError.stale) {
            try await m.management { try await $0.savePluginConfiguration(config, changes: ["limit": .number(12)], key: $1) }
        }
        var plugin = try await m.management { try await $0.plugins(key: $1) }.plugins[0]
        plugin.version = "old"
        await #expect(throws: PluginError.stale) { _ = try await m.management { try await $0.removePlugin(plugin, key: $1) } }
        #expect(PluginStub.seen.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func invalidIDsSendNothing() async {
        let m = monitor()
        for id in ["../escape", "a/b", "a?x=1", "a%2fb", "", "a..b"] {
            await #expect(throws: PluginError.invalidID) { _ = try await m.management { try await $0.pluginConfiguration(id: id, key: $1) } }
        }
        #expect(PluginStub.seen.isEmpty)
    }

    @Test func missingRejectedAndUnsupportedAreDistinct() async {
        let noKey = monitor(key: nil)
        await #expect(throws: ManagementError.locked) { _ = try await noKey.management { try await $0.plugins(key: $1) } }
        #expect(PluginStub.seen.isEmpty)
        let rejected = monitor(status: 401)
        await #expect(throws: ProxyError.unauthorized) { _ = try await rejected.management { try await $0.plugins(key: $1) } }
        await #expect(throws: ManagementError.locked) { _ = try await rejected.management { try await $0.pluginStore(key: $1) } }
        #expect(PluginStub.seen.count == 1)
        let old = monitor(status: 404)
        await #expect(throws: PluginError.unsupported) { _ = try await old.management { try await $0.plugins(key: $1) } }
    }

    @Test func restartConflictIsNotSuccessfulInstallation() async throws {
        let m = monitor(conflict: true)
        let store = try await m.management { try await $0.pluginStore(key: $1) }
        await #expect(throws: PluginError.restartRequired) {
            _ = try await m.management { try await $0.installPlugin(store.plugins[0], key: $1) }
        }
        #expect(PluginStub.seen.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func platformAuthenticationAndDifferentSourcePreventInstall() async throws {
        let m = monitor()
        PluginStub.handler = { _ in (200, #"""
        {"plugins_enabled":true,"plugins":[
         {"id":"linux","source_id":"main","version":"1.0.0","platforms":[{"goos":"linux","goarch":"amd64"}]},
         {"id":"private","source_id":"main","version":"1.0.0","auth_required":true,"auth_configured":false},
         {"id":"different","source_id":"main","version":"1.0.0","installed":true,"update_available":true,"install_source_status":"different"}]}
        """#) }
        let store = try await m.management { try await $0.pluginStore(key: $1) }
        #expect(store.plugins.count == 3 && store.plugins.allSatisfy { !$0.canInstall })
        for plugin in store.plugins {
            await #expect(throws: PluginError.unavailable) { _ = try await m.management { try await $0.installPlugin(plugin, key: $1) } }
        }
        #expect(PluginStub.seen.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func githubLatestReleaseIsResolvedByHub() async throws {
        let m = monitor()
        PluginStub.handler = { request in
            request.httpMethod == "GET" ? (200, #"{"plugins_enabled":true,"plugins":[{"id":"sample","source_id":"main","version":"","install_type":"github-release"}]}"#)
                : (200, #"{"status":"installed","id":"sample","restart_required":false}"#)
        }
        let plugin = try await m.management { try await $0.pluginStore(key: $1) }.plugins[0]
        #expect(plugin.canInstall && plugin.versionLabel == "Latest release")
        _ = try await m.management { try await $0.installPlugin(plugin, key: $1) }
        let request = try #require(PluginStub.seen.last)
        #expect(try JSONSerialization.jsonObject(with: clBody(request)) as? NSDictionary == [:] as NSDictionary)
    }

    @Test func changedStoreSourcePreventsInstallation() async throws {
        let m = monitor()
        let plugin = try await m.management { try await $0.pluginStore(key: $1) }.plugins[0]
        PluginStub.handler = { _ in (200, pluginStore.replacingOccurrences(of: "\"source_name\":\"Main\"", with: "\"source_name\":\"Main\",\"source_url\":\"https://changed.example/store\"")) }
        await #expect(throws: PluginError.stale) { _ = try await m.management { try await $0.installPlugin(plugin, key: $1) } }
        #expect(PluginStub.seen.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func replacementSecretIsSentOnlyWhenExplicitlyChanged() async throws {
        let m = monitor()
        let config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        try await m.management { try await $0.savePluginConfiguration(config, changes: ["api_key": .text("replacement-secret")], key: $1) }
        let request = try #require(PluginStub.seen.last)
        #expect(try JSONSerialization.jsonObject(with: clBody(request)) as? NSDictionary == ["api_key":"replacement-secret"] as NSDictionary)
        #expect(!String(describing: config).contains("stored-secret"))
    }

    @Test func unknownConflictAndMalformedResponseAreNotSuccess() async throws {
        let m = monitor()
        let plugin = try await m.management { try await $0.plugins(key: $1) }.plugins[0]
        PluginStub.handler = { request in request.httpMethod == "GET" ? (200, pluginList) : (409, "{}") }
        await #expect(throws: ProxyError.http(409)) {
            try await m.management { try await $0.setPluginEnabled(plugin, enabled: false, key: $1) }
        }
        PluginStub.handler = { _ in (200, "{}") }
        await #expect(throws: ProxyError.incompatible) { _ = try await m.management { try await $0.plugins(key: $1) } }
    }

    @Test func numericAndReservedConfigValidation() async throws {
        let m = monitor()
        let config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        PluginStub.seen = []
        for patch: [String: PluginValue] in [["enabled":.bool(false)], ["priority":.number(1)], ["limit":.number(.infinity)],
                                           ["limit":.number(2.5)], ["options":.text("{}")], ["api_key":.text(String(repeating: "x", count: 10_001))]] {
            await #expect(throws: PluginError.invalidValue) {
                try await m.management { try await $0.savePluginConfiguration(config, changes: patch, key: $1) }
            }
        }
        #expect(PluginStub.seen.isEmpty)
    }

    @Test func declaredEnumFieldsAcceptOnlyAllowedChoices() async throws {
        let m = monitor()
        let original = PluginStub.handler!
        PluginStub.handler = { request in
            let (status, body) = original(request)
            return (status, body.replacingOccurrences(of: "\"name\":\"mode\",\"type\":\"string\"", with: "\"name\":\"mode\",\"type\":\"enum\""))
        }
        let config = try await m.management { try await $0.pluginConfiguration(id: "sample", key: $1) }
        let mode = try #require(config.fields.first { $0.id == "mode" })
        #expect(mode.editable && mode.parse("slow") == .text("slow"))
        #expect(mode.parse("unlisted") == nil)
        try await m.management { try await $0.savePluginConfiguration(config, changes: ["mode": .text("slow")], key: $1) }
        let request = try #require(PluginStub.seen.last)
        #expect(try JSONSerialization.jsonObject(with: clBody(request)) as? NSDictionary == ["mode":"slow"] as NSDictionary)
    }
}
