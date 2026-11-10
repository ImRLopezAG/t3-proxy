import Foundation

protocol T3CodeSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
    var httpStatus: Int? { get }
}

/// Refuse redirects even when they remain on loopback; the bearer belongs to this endpoint only.
private final class T3CodeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class T3CodeWebSocket: T3CodeSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: T3CodeSessionDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // Large installations have thousands of shell rows. Do not opt in to frameParts framing.
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw T3CodeError.unsupportedServerVersion
        }
    }
    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Call connect once and consume events; disconnect explicitly when the owner stops monitoring.
/// Commands await the server's acceptance sequence. A lost reply is never retried automatically.
public actor T3CodeClient {
    private let endpoint: URL
    private let token: String
    private let makeSocket: @Sendable (URLRequest) -> any T3CodeSocket
    private var socket: (any T3CodeSocket)?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [UUID: AsyncStream<T3CodeClientEvent>.Continuation] = [:]
    private var pending: [String: CheckedContinuation<T3CodeJSON, any Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var pingOutstanding = false
    private var shellID: String?
    private var shell = T3CodeShellState()
    public private(set) var state: T3CodeConnectionState = .disconnected
    public private(set) var snapshot: T3CodeSnapshot?

    public init(port: Int = 3773, token: String) throws {
        guard (1...65535).contains(port), let url = URL(string: "ws://127.0.0.1:\(port)/ws") else {
            throw T3CodeError.invalidEndpoint
        }
        endpoint = try T3CodeWire.connectionURL(url)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw T3CodeError.invalidToken }
        self.token = token
        makeSocket = { T3CodeWebSocket(request: $0) }
    }

    init(endpoint: URL, token: String, makeSocket: @escaping @Sendable (URLRequest) -> any T3CodeSocket) throws {
        self.endpoint = try T3CodeWire.connectionURL(endpoint)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw T3CodeError.invalidToken }
        self.token = token
        self.makeSocket = makeSocket
    }

    /// Bounded streams keep the newest complete snapshot if a consumer falls behind.
    public func updates() -> AsyncStream<T3CodeClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<T3CodeClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        observers[id] = continuation
        continuation.yield(.connection(state))
        if let snapshot { continuation.yield(.snapshot(snapshot)) }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func emit(_ event: T3CodeClientEvent) { for observer in observers.values { observer.yield(event) } }
    private func setState(_ state: T3CodeConnectionState) { self.state = state; emit(.connection(state)) }

    /// Set once the server rejects this client's token. The token is never sent again; the owner must
    /// create a new client with a new token.
    private var credentialRejected = false

    public func connect() {
        guard worker == nil else { return }
        guard !credentialRejected else { setState(.failed(.authenticationFailed)); return }
        let current = UUID(); generation = current
        worker = Task { await self.run(generation: current) }
    }
    public func disconnect() {
        generation = UUID()
        worker?.cancel(); worker = nil
        socket?.close(); socket = nil
        failPending(.disconnected)
        shellID = nil
        setState(.disconnected)
    }

    @discardableResult public func stop(threadID: String, expectedRunID: String?, expectedConnection: Int? = nil) async throws -> Int {
        guard state == .connected else { throw T3CodeError.notConnected }
        guard expectedConnection == nil || expectedConnection == connectionCount else { throw T3CodeError.threadChanged }
        guard let thread = snapshot?.threads.first(where: { $0.id == threadID }),
              thread.activeRunId == expectedRunID else { throw T3CodeError.threadChanged }
        return try await dispatch(T3CodeWire.stop(threadID: threadID))
    }
    /// Starts a user continuation immediately, even before the reset time. It may hit the limit again.
    /// The server validates the referenced latest run and clears the snooze as part of the dispatch.
    @discardableResult public func resumeLimited(threadID: String, expectedRunID: String, expectedConnection: Int? = nil) async throws -> Int {
        guard state == .connected, let thread = snapshot?.threads.first(where: { $0.id == threadID }) else {
            throw T3CodeError.notConnected
        }
        guard expectedConnection == nil || expectedConnection == connectionCount else { throw T3CodeError.threadChanged }
        guard thread.latestRunId == expectedRunID else { throw T3CodeError.threadChanged }
        return try await dispatch(T3CodeWire.resumeLimited(thread: thread))
    }
    private func dispatch(_ command: T3CodeCommand) async throws -> Int {
        guard state == .connected else { throw T3CodeError.notConnected }
        let result = try await rpc("orchestration.dispatchCommand", payload: command)
        struct Receipt: Decodable { let sequence: Int }
        return try T3CodeWire.decode(Receipt.self, from: result.data).sequence
    }

    private func run(generation current: UUID) async {
        var attempt = 0
        while generation == current && !Task.isCancelled {
            setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            do {
                try await connection(generation: current)
            } catch {
                guard generation == current && !Task.isCancelled else { break }
                let error = error as? T3CodeError ?? .disconnected
                if [.authenticationFailed, .permissionDenied, .unsupportedServerVersion].contains(error) {
                    if error != .unsupportedServerVersion { credentialRejected = true }
                    setState(.failed(error)); break
                }
                setState(.failed(error))
            }
            guard generation == current && !Task.isCancelled else { break }
            // A connection that delivered a snapshot resets the retry count.
            if shell.hasSnapshot { attempt = 0 }
            attempt += 1
            let seconds = min(pow(2, Double(min(attempt - 1, 5))), 30) * Double.random(in: 0.8...1.2)
            do { try await Task.sleep(for: .seconds(seconds)) } catch { break }
        }
        if generation == current { worker = nil }
    }
    /// Counts socket connections; stamped on every snapshot and checked by commands.
    private var connectionCount = 0

    private func connection(generation current: UUID) async throws {
        connectionCount += 1
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let transport = makeSocket(request)
        socket = transport
        shell = T3CodeShellState()
        shellID = nil
        let reader = Task {
            do { try await self.read(transport, generation: current) }
            catch {
                if self.generation == current { self.failPending(self.classify(error, transport: transport)) }
                throw error
            }
        }
        defer {
            reader.cancel(); transport.close()
            if generation == current {
                socket = nil; shellID = nil; failPending(.disconnected)
            }
        }
        do {
            let config = try await rpc("server.getConfig", payload: [String: String]())
            try T3CodeWire.validateConfig(config.data)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            let id = UUID().uuidString; shellID = id
            try await transport.send(T3CodeWire.request(id: id, method: "orchestration.subscribeShell", payload: [String: String]()))
            pingOutstanding = false
            let heartbeat = Task {
                while !Task.isCancelled && self.generation == current {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard self.generation == current && !Task.isCancelled else { return }
                    if self.pingOutstanding { transport.close(); return }
                    self.pingOutstanding = true
                    do { try await transport.send(T3CodeWire.control("Ping")) }
                    catch { transport.close(); return }
                }
            }
            defer { heartbeat.cancel() }
            // A stalled initial snapshot must reconnect too; do not silently stay "connecting" forever.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if self.generation == current && !self.shell.hasSnapshot { transport.close() }
            }
            defer { watchdog.cancel() }
            try await reader.value
        } catch {
            // Drain the reader before another connection can register pending RPCs.
            transport.close(); reader.cancel()
            _ = try? await reader.value
            throw classify(error, transport: transport)
        }
    }
    private func classify(_ error: any Error, transport: any T3CodeSocket) -> T3CodeError {
        if transport.httpStatus == 426 { return .unsupportedServerVersion }
        if transport.httpStatus == 401 || transport.httpStatus == 403 { return .authenticationFailed }
        return error as? T3CodeError ?? .disconnected
    }
    private func read(_ transport: any T3CodeSocket, generation current: UUID) async throws {
        while generation == current && !Task.isCancelled {
            let data = try await transport.receive()
            guard generation == current else { return }
            var changed = false
            for frame in try T3CodeWire.frames(data) {
                guard generation == current && !Task.isCancelled else { return }
                switch frame._tag {
                case "Ping": try await transport.send(T3CodeWire.control("Pong"))
                case "Pong": pingOutstanding = false
                case "Chunk":
                    guard frame.requestId == shellID, let values = frame.values else { throw T3CodeError.invalidResponse }
                    for value in values { try shell.apply(value.data); changed = true }
                    try await transport.send(T3CodeWire.control("Ack", requestID: frame.requestId))
                case "Exit":
                    guard let id = frame.requestId else { throw T3CodeError.invalidResponse }
                    if id == shellID { throw frame.rpcError ?? T3CodeError.disconnected }
                    if let continuation = pending.removeValue(forKey: id) {
                        timeouts.removeValue(forKey: id)?.cancel()
                        if let error = frame.rpcError { continuation.resume(throwing: error) }
                        else if frame.exit?["_tag"]?.string == "Success" {
                            continuation.resume(returning: frame.exit?["value"] ?? .null)
                        } else { continuation.resume(throwing: T3CodeError.invalidResponse) }
                    }
                case "Defect": throw T3CodeError.commandRejected
                default: throw T3CodeError.unsupportedServerVersion
                }
            }
            guard generation == current && !Task.isCancelled else { return }
            if changed && shell.hasSnapshot {
                var stamped = shell.snapshot; stamped.connection = connectionCount; snapshot = stamped
                setState(.connected)
                if let snapshot { emit(.snapshot(snapshot)) }
            }
        }
    }
    private func rpc<P: Encodable>(_ method: String, payload: P) async throws -> T3CodeJSON {
        guard let socket else { throw T3CodeError.notConnected }
        let id = UUID().uuidString
        let data = try T3CodeWire.request(id: id, method: method, payload: payload)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self.finish(id, error: .timedOut)
                }
                Task {
                    do { try await socket.send(data) }
                    catch { self.finish(id, error: self.classify(error, transport: socket)) }
                }
            }
        } onCancel: { Task { await self.finish(id, error: .disconnected) } }
    }
    private func finish(_ id: String, error: T3CodeError) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func failPending(_ error: T3CodeError) {
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
