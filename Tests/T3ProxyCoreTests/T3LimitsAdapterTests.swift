import Foundation
import Testing
import Synchronization
@testable import T3ProxyCore

private final class LimitsAdapterProtocol: URLProtocol, @unchecked Sendable {
    struct State { var requests: [URLRequest] = []; var status = 200; var body = Data("{}".utf8); var resetReply: (Int, Data)? }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { value in
            value.requests.append(request)
            if request.url?.path.hasSuffix("/reset-quota") == true, let reply = value.resetReply { return reply }
            return (value.status, value.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite(.serialized) struct T3LimitsAdapterTests {
    @Test func fixedHeadersAndSharedGate() async throws {
        LimitsAdapterProtocol.state.withLock { $0 = .init(status: 200, body: Data(#"{"status_code":200,"body":"{}"}"#.utf8)) }
        let client = ManagementClient(protocolClasses: [LimitsAdapterProtocol.self])
        _ = try await client.call(.codexConsume, authIndex: "idx", accountID: "workspace", data: #"{"redeem_request_id":"r","credit_id":"c"}"#, key: "fixture-key")
        let request = try #require(LimitsAdapterProtocol.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == "http://127.0.0.1:8317/v0/management/api-call")
        let data = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var output = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; output.append(contentsOf: buffer.prefix(count)) }
            return output
        })
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["authIndex"] as? String == "idx")
        #expect(body["url"] as? String == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
        let headers = try #require(body["header"] as? [String: String])
        #expect(headers["Authorization"] == "Bearer $TOKEN$")
        #expect(headers["Chatgpt-Account-Id"] == "workspace")
        #expect(headers["Originator"] == "Codex Desktop")
        client.gate.reject("fixture-key")
        await #expect(throws: ManagementError.locked) { try await client.authFiles(key: "fixture-key") }
        #expect(LimitsAdapterProtocol.state.withLock { $0.requests.count } == 1)
    }
    @Test func resetFailurePreservesManagementJSON() async {
        LimitsAdapterProtocol.state.withLock { $0 = .init(status: 200, body: Data(#"{"files":[{"id":"o","auth_index":"o","provider":"codex"}]}"#.utf8), resetReply: (500, Data(#"{"error":"reset unavailable"}"#.utf8))) }
        let client = ManagementClient(protocolClasses: [LimitsAdapterProtocol.self])
        let h = T3LimitsHandler(key: { "fixture" }, hub: client, plans: { [:] }, localLogin: { nil })
        let response = await h.handle(.init(method: "POST", path: "/t3/v0/management/reset-quota", headers: ["host": "127.0.0.1:8318", "authorization": "Bearer fixture"], body: Data(#"{"auth_index":"o"}"#.utf8)))
        #expect(response.status == 502)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"error":"reset unavailable"}"#)
        #expect(LimitsAdapterProtocol.state.withLock { $0.requests.last?.url?.path } == "/v0/management/reset-quota")
    }
    @Test func hubRejectionLocksFurtherCalls() async throws {
        LimitsAdapterProtocol.state.withLock { $0 = .init(status: 401, body: Data("secret-body-never-echoed".utf8)) }
        let client = ManagementClient(protocolClasses: [LimitsAdapterProtocol.self])
        let h = T3LimitsHandler(key: {
            guard client.gate.permits("fixture") else { throw ManagementError.locked }; return "fixture"
        }, hub: client, plans: { [:] }, localLogin: { nil })
        let req = T3LimitsRequest(method: "GET", path: "/t3/v0/management/auth-files", headers: ["host": "127.0.0.1:8318", "authorization": "Bearer fixture"])
        let first = await h.handle(req)
        #expect(first.status == 502)
        #expect(!String(decoding: first.body, as: UTF8.self).contains("secret-body"))
        #expect(await h.handle(req).status == 503)
        #expect(LimitsAdapterProtocol.state.withLock { $0.requests.count } == 1)
    }
}

extension T3LimitsAdapterTests {
    /// An oversized hub answer is refused (the stream is cut at the cap, never buffered whole).
    @Test func oversizedHubResponseIsRefused() async {
        LimitsAdapterProtocol.state.withLock { $0 = .init(status: 200, body: Data(repeating: 0x20, count: ManagementClient.limitsResponseCap + 1)) }
        let client = ManagementClient(protocolClasses: [LimitsAdapterProtocol.self])
        await #expect(throws: LiveQuotaError.self) { _ = try await client.authFiles(key: "fixture-key") }
        LimitsAdapterProtocol.state.withLock { $0 = .init(status: 200, body: Data(#"{"files":[]}"#.utf8)) }
        #expect((try? await client.authFiles(key: "fixture-key")) == Data(#"{"files":[]}"#.utf8))
    }
}
