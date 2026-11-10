import Foundation
import Testing
@testable import T3ProxyCore

// Synthetic protocol fixtures only; never record local conversation content.
private let threadJSON = #"{"id":"sample-thread","title":"Sample task","projectId":"sample-project","status":"failed","providerInstanceId":"sample-provider","modelSelection":{"instanceId":"sample-provider","model":"sample-model"},"lineage":{"parentThreadId":"sample-parent","relationshipToParent":"fork","rootThreadId":"sample-parent"},"latestRunId":"sample-run","lastErrorClass":"usage_limit","usageLimitResetAt":"2099-01-01T00:00:00Z","snoozedUntil":"2099-01-01T00:00:00Z","limitRecovery":{"runId":"sample-run","resetAt":"2099-01-01T00:00:00Z","autoResume":true,"snooze":true},"updatedAt":"2026-01-01T00:00:00.123Z","futureField":{"ignored":true}}"#
private func decodeThread(_ json: String = threadJSON) throws -> T3CodeThread {
    try T3CodeWire.decode(T3CodeThread.self, from: Data(json.utf8))
}

@Suite struct T3CodeDecodingTests {
    @Test func decodesKnownFieldsAndIgnoresNewFields() throws {
        let t = try decodeThread()
        #expect(t.id == "sample-thread")
        #expect(t.modelSelection?.model == "sample-model")
        #expect(t.lineage?.parentThreadId == "sample-parent")
        #expect(t.status == .failed)
        #expect(t.isUsageLimited)
        #expect(t.isSnoozedByUsageLimit(at: .distantPast))
        #expect(!t.isSnoozedByUsageLimit(at: .distantFuture))
    }
    @Test(arguments: ["idle", "preparing", "queued", "starting", "running", "waiting", "completed", "interrupted", "failed", "cancelled", "rolled_back"])
    func mapsEveryKnownStatus(_ status: String) throws {
        let t = try decodeThread(threadJSON.replacingOccurrences(of: #""status":"failed""#, with: #""status":"\#(status)""#))
        #expect(t.status.rawValue == status)
    }
    @Test func unknownStatusDoesNotInventFinishedState() throws {
        let t = try decodeThread(threadJSON.replacingOccurrences(of: #""status":"failed""#, with: #""status":"future_status""#))
        #expect(t.status == .unknown)
        #expect(t.attention == .unknown)
    }
    @Test func needsYouIncludesAsyncQuestionsAndPlansButNotEveryWait() throws {
        let waiting = #"{"id":"sample-thread","title":"Sample task","projectId":"sample-project","status":"waiting"}"#
        #expect(try decodeThread(waiting).attention == .running)
        for kind in ["permission", "command", "file-read", "file-change", "mcp-elicitation", "user_input", "auth_refresh", "future_kind"] {
            let t = try decodeThread(String(waiting.dropLast()) + #", "pendingRuntimeRequest":{"id":"sample-request","kind":"\#(kind)","blocking":false}}"#)
            #expect(t.attention == .needsYou)
            #expect(t.pendingRuntimeRequest?.blocksRun == false)
        }
        #expect(try decodeThread(String(waiting.dropLast()) + #", "hasActionableProposedPlan":true}"#).attention == .needsYou)
        #expect(try decodeThread(String(waiting.dropLast()) + #", "pendingGuestMessageCount":1}"#).attention == .needsYou)
    }
    @Test func manualSnoozeIsNotClaimedAsLimitSnooze() throws {
        let t = try decodeThread(threadJSON.replacingOccurrences(of: #""snooze":true"#, with: #""snooze":false"#))
        #expect(!t.isSnoozedByUsageLimit(at: .distantPast))
    }
    @Test func versionCompatibilityUsesProtocolRatherThanDailyBuild() throws {
        try T3CodeWire.validateConfig(Data(#"{"environment":{"serverVersion":"0.1.8-nightly.future","orchestrationProtocolVersion":2},"future":true}"#.utf8))
        #expect(throws: T3CodeError.unsupportedServerVersion) {
            try T3CodeWire.validateConfig(Data(#"{"environment":{"serverVersion":"future","orchestrationProtocolVersion":3}}"#.utf8))
        }
        #expect(throws: T3CodeError.unsupportedServerVersion) {
            try T3CodeWire.validateConfig(Data(#"{"environment":{"serverVersion":"legacy"}}"#.utf8))
        }
    }
    @Test func shellReductionPreservesThreadsAcrossEnrichmentAndHandlesMoves() throws {
        var state = T3CodeShellState()
        func apply(_ s: String) throws { try state.apply(Data(s.utf8)) }
        try apply(#"{"kind":"snapshot","snapshot":{"schemaVersion":2,"snapshotSequence":10,"projects":[{"id":"sample-project","title":"Sample project"}],"threads":[\#(threadJSON)],"archivedThreads":[]}}"#)
        try apply(#"{"kind":"snapshot","resolvedRepositoryIdentityRoots":["/sample"],"snapshot":{"schemaVersion":2,"snapshotSequence":11,"projects":[],"threads":[],"archivedThreads":[]}}"#)
        #expect(state.snapshot.threads.count == 1)
        try apply(#"{"kind":"thread.updated","sequence":12,"location":"archive","thread":\#(threadJSON)}"#)
        #expect(state.snapshot.threads.isEmpty)
        #expect(state.snapshot.archivedThreads.count == 1)
        try apply(#"{"kind":"thread.removed","sequence":13,"location":"archive","threadId":"sample-thread"}"#)
        #expect(state.snapshot.archivedThreads.isEmpty)
        #expect(throws: T3CodeError.unsupportedServerVersion) {
            try apply(#"{"kind":"snapshot","snapshot":{"schemaVersion":3,"snapshotSequence":14,"projects":[],"threads":[],"archivedThreads":[]}}"#)
        }
    }
    @Test func commandsUseGuardedManualContinuationAndUniqueIDs() throws {
        let stop = T3CodeWire.stop(threadID: "sample-thread")
        #expect(stop.type == "thread.stop")
        #expect(stop.reason == nil)
        let resume = try T3CodeWire.resumeLimited(thread: decodeThread())
        #expect(resume.type == "message.dispatch")
        #expect(resume.manualContinuationOfRunId == "sample-run")
        #expect(resume.dispatchMode?.type == "start_immediately")
        #expect(resume.createdBy == "user")
        #expect(resume.creationSource == "web")
        #expect(resume.commandId != stop.commandId)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(resume)) as? [String: Any])
        #expect(object["usageLimitContinuationOfRunId"] == nil)
        #expect(object["attachments"] as? [String] == [])
        let ordinary = try decodeThread(threadJSON.replacingOccurrences(of: "usage_limit", with: "other"))
        #expect(throws: T3CodeError.notUsageLimited) { try T3CodeWire.resumeLimited(thread: ordinary) }
    }
    @Test func framesDecodeBatchesAndDoNotExposeServerErrors() throws {
        let frames = try T3CodeWire.frames(Data(#"[{"_tag":"Pong"},{"_tag":"Chunk","requestId":"1","values":[{"kind":"synchronized"}]},{"_tag":"Exit","requestId":"2","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"EnvironmentAuthorizationError","message":"private content"}}]}}]"#.utf8))
        #expect(frames.count == 3)
        #expect(frames[1].values?.count == 1)
        #expect(frames[2].rpcError == .permissionDenied)
    }
    @Test func endpointRejectsNonLoopbackAndCredentialURLs() throws {
        for endpoint in ["ws://localhost:3773/ws", "ws://192.0.2.1/ws", "ws://127.0.0.1.evil/ws", "ws://127.0.0.1/ws?token=sample", "ws://user@127.0.0.1/ws"] {
            #expect(throws: T3CodeError.invalidEndpoint) { try T3CodeWire.connectionURL(URL(string: endpoint)!) }
        }
        #expect(try T3CodeWire.connectionURL(URL(string: "ws://127.0.0.1:3773/ws")!).query == "orchestrationProtocol=2")
    }
}

private final class T3CodeTestSocket: T3CodeSocket, @unchecked Sendable {
    let httpStatus: Int? = 101
    private let stream: AsyncStream<Data>
    private let output: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sent: [String] = []
    private var endpointsAreLocal = true
    let protocolVersion: Int
    let rejectCommands: Bool
    let dropCommands: Bool
    init(protocolVersion: Int = 2, rejectCommands: Bool = false, dropCommands: Bool = false) {
        self.protocolVersion = protocolVersion; self.rejectCommands = rejectCommands; self.dropCommands = dropCommands
        (stream, output) = AsyncStream<Data>.makeStream()
    }
    func capture(_ request: URLRequest) {
        lock.withLock {
            endpointsAreLocal = endpointsAreLocal && request.url?.host == "127.0.0.1"
                && request.url?.query == "orchestrationProtocol=2"
                && request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        }
    }
    var methods: [String] { lock.withLock { sent } }
    var localOnly: Bool { lock.withLock { endpointsAreLocal } }
    func send(_ data: Data) async throws {
        let request = try JSONDecoder().decode(T3CodeJSON.self, from: data)
        if let control = request["_tag"]?.string, control != "Request" {
            lock.withLock { sent.append(control) }; return
        }
        let id = request["id"]?.string ?? ""
        let method = request["tag"]?.string ?? ""
        lock.withLock { sent.append(method) }
        switch method {
        case "server.getConfig":
            output.yield(Data(#"{"_tag":"Exit","requestId":"\#(id)","exit":{"_tag":"Success","value":{"environment":{"serverVersion":"synthetic","orchestrationProtocolVersion":\#(protocolVersion)}}}}"#.utf8))
        case "orchestration.subscribeShell":
            output.yield(Data(#"[{"_tag":"Ping"},{"_tag":"Chunk","requestId":"\#(id)","values":[{"kind":"snapshot","snapshot":{"schemaVersion":2,"snapshotSequence":1,"projects":[],"threads":[\#(threadJSON)],"archivedThreads":[]}}]}]"#.utf8))
        case "orchestration.dispatchCommand":
            if dropCommands { output.finish(); return }
            if rejectCommands {
                output.yield(Data(#"{"_tag":"Exit","requestId":"\#(id)","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"EnvironmentAuthorizationError"}}]}}"#.utf8))
            } else {
                output.yield(Data(#"{"_tag":"Exit","requestId":"\#(id)","exit":{"_tag":"Success","value":{"sequence":2}}}"#.utf8))
            }
        default: break
        }
    }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let next = await iterator.next() else { throw T3CodeError.disconnected }
        return next
    }
    func close() { output.finish() }
}

@Suite(.timeLimit(.minutes(1))) struct T3CodeClientTests {
    private func client(_ socket: T3CodeTestSocket) throws -> T3CodeClient {
        try T3CodeClient(endpoint: URL(string: "ws://127.0.0.1:3773/ws")!, token: UUID().uuidString) { request in
            socket.capture(request); return socket
        }
    }
    @Test func subscribesPublishesAcknowledgesAndAwaitsCommandReceipts() async throws {
        let socket = T3CodeTestSocket()
        let client = try client(socket)
        let events = await client.updates()
        await client.connect()
        var received = false
        for await event in events {
            if case .snapshot(let snapshot) = event {
                #expect(snapshot.threads.count == 1)
                received = true; break
            }
        }
        #expect(received)
        #expect(socket.localOnly)
        #expect(socket.methods.contains("Ack"))
        #expect(socket.methods.contains("Pong"))
        await #expect(throws: T3CodeError.threadChanged) {
            try await client.stop(threadID: "sample-thread", expectedRunID: "new-run")
        }
        await #expect(throws: T3CodeError.threadChanged) {
            try await client.resumeLimited(threadID: "sample-thread", expectedRunID: "new-run")
        }
        // A confirmation made on another connection is refused without sending anything.
        let current = try #require(await client.snapshot?.connection)
        #expect(current >= 1)
        await #expect(throws: T3CodeError.threadChanged) {
            try await client.stop(threadID: "sample-thread", expectedRunID: nil, expectedConnection: current + 1)
        }
        await #expect(throws: T3CodeError.threadChanged) {
            try await client.resumeLimited(threadID: "sample-thread", expectedRunID: "sample-run", expectedConnection: current - 1)
        }
        #expect(!socket.methods.contains("orchestration.dispatchCommand"))
        #expect(try await client.stop(threadID: "sample-thread", expectedRunID: nil, expectedConnection: current) == 2)
        #expect(try await client.resumeLimited(threadID: "sample-thread", expectedRunID: "sample-run") == 2)
        #expect(socket.methods.filter { $0 == "orchestration.dispatchCommand" }.count == 2)
        await client.disconnect()
        #expect(await client.state == .disconnected)
        await #expect(throws: T3CodeError.notConnected) { try await client.stop(threadID: "sample-thread", expectedRunID: nil) }
    }
    @Test func mismatchedProtocolFailsBeforeSubscribing() async throws {
        let socket = T3CodeTestSocket(protocolVersion: 3)
        let client = try client(socket)
        let events = await client.updates()
        await client.connect()
        for await event in events {
            if case .connection(.failed(let error)) = event {
                #expect(error == .unsupportedServerVersion); break
            }
        }
        #expect(!socket.methods.contains("orchestration.subscribeShell"))
        await client.disconnect()
    }
    @Test func scopedRejectionReachesCommandCaller() async throws {
        let socket = T3CodeTestSocket(rejectCommands: true)
        let client = try client(socket)
        let events = await client.updates()
        await client.connect()
        for await event in events { if case .snapshot = event { break } }
        await #expect(throws: T3CodeError.permissionDenied) { try await client.stop(threadID: "sample-thread", expectedRunID: nil) }
        #expect(socket.methods.filter { $0 == "orchestration.dispatchCommand" }.count == 1)
        await client.disconnect()
    }
}

private final class T3CodeTestConnections: @unchecked Sendable {
    let first = T3CodeTestSocket(dropCommands: true)
    let second = T3CodeTestSocket()
    private let lock = NSLock()
    private var count = 0
    func open(_ request: URLRequest) -> any T3CodeSocket {
        lock.withLock {
            count += 1
            let socket = count == 1 ? first : second
            socket.capture(request)
            return socket
        }
    }
}

extension T3CodeClientTests {
    @Test func reconnectsWithFreshSubscriptionWithoutReplayingUncertainCommand() async throws {
        let connections = T3CodeTestConnections()
        let client = try T3CodeClient(endpoint: URL(string: "ws://127.0.0.1:3773/ws")!, token: UUID().uuidString) {
            connections.open($0)
        }
        let events = await client.updates()
        await client.connect()
        for await event in events { if case .snapshot = event { break } }
        await #expect(throws: T3CodeError.disconnected) { try await client.stop(threadID: "sample-thread", expectedRunID: nil) }
        for await event in events { if case .snapshot = event { break } }
        #expect(connections.first.methods.filter { $0 == "orchestration.dispatchCommand" }.count == 1)
        #expect(!connections.second.methods.contains("orchestration.dispatchCommand"))
        #expect(connections.second.methods.contains("orchestration.subscribeShell"))
        await client.disconnect()
    }
    @Test func tokenParsingIsPrivateAndRequiresExactScopes() throws {
        let value = UUID().uuidString
        let raw = try JSONSerialization.data(withJSONObject: ["sessionId": "sample-session", "token": value,
            "expiresAt": "2099-01-01T00:00:00Z", "scopes": ["orchestration:read", "orchestration:operate"]])
        let session = try T3CodeTokenCLI.parseIssued(raw)
        #expect(session.sessionID == "sample-session")
        let redacted = !session.description.contains(value) && !session.debugDescription.contains(value)
        #expect(redacted)
        let tooBroad = try JSONSerialization.data(withJSONObject: ["sessionId": "sample-session", "token": value,
            "expiresAt": "2099-01-01T00:00:00Z", "scopes": ["orchestration:read", "orchestration:operate", "settings:write"]])
        #expect(throws: T3CodeError.cliFailed) { try T3CodeTokenCLI.parseIssued(tooBroad) }
        #expect(throws: T3CodeError.cliFailed) { try T3CodeTokenCLI.parseIssued(Data("invalid".utf8)) }
    }
}

/// A server that rejects every upgrade with 401; counts how many connections were opened.
private final class RejectingSocket: T3CodeSocket, @unchecked Sendable {
    nonisolated(unsafe) static var opened = 0
    var httpStatus: Int? { 401 }
    init() { Self.opened += 1 }
    func send(_ data: Data) async throws { throw URLError(.userAuthenticationRequired) }
    func receive() async throws -> Data { throw URLError(.userAuthenticationRequired) }
    func close() {}
}

@Suite struct T3CodeCredentialTests {
    @Test func rejectedTokenIsNeverSentAgain() async throws {
        RejectingSocket.opened = 0
        let client = try T3CodeClient(endpoint: URL(string: "ws://127.0.0.1:3773/ws")!,
                                      token: "synthetic-token", makeSocket: { _ in RejectingSocket() })
        await client.connect()
        for _ in 0..<200 where await client.state != .failed(.authenticationFailed) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await client.state == .failed(.authenticationFailed))
        let opened = RejectingSocket.opened
        await client.connect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(RejectingSocket.opened == opened, "a rejected token was sent again")
    }
}
