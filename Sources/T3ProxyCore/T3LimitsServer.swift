import Foundation
import Network
import Combine

public enum T3LimitsServerStatus: Sendable, Equatable {
    case stopped, listening(UInt16), portBusy(UInt16), failed(String)
}

/// Main-actor ownership; all socket callbacks hop to it. Only an IPv4 loopback endpoint is bound.
@MainActor public final class T3LimitsServer: ObservableObject {
    @Published public private(set) var status: T3LimitsServerStatus = .stopped
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private let handler: @Sendable (T3LimitsRequest) async -> T3LimitsResponse
    private let queue = DispatchQueue(label: "dev.t3-proxy.limits")
    private var generation = 0
    public init(handler: T3LimitsHandler) { self.handler = { await handler.handle($0) } }
    public init(handle: @escaping @Sendable (T3LimitsRequest) async -> T3LimitsResponse) { handler = handle }
    public func start(port: UInt16 = 8318) {
        guard listener == nil else { return }
        generation += 1
        let epoch = generation
        do {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
            p.allowLocalEndpointReuse = false
            let l = try NWListener(using: p)
            listener = l
            l.stateUpdateHandler = { [weak self, weak l] state in
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    switch state {
                    case .ready: self.status = .listening(l?.port?.rawValue ?? port)
                    case .failed(let error):
                        self.status = error == .posix(.EADDRINUSE) ? .portBusy(port) : .failed("The limits listener could not start.")
                        l?.cancel(); self.listener = nil
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in
                    guard let self, self.generation == epoch, self.peers.count < 16 else { c.cancel(); return }
                    let id = UUID(), actualPort = self.listener?.port?.rawValue ?? port
                    let peer = Peer(connection: c, port: actualPort, handler: self.handler) { [weak self] in self?.peers[id] = nil }
                    self.peers[id] = peer; peer.start(queue: self.queue)
                }
            }
            l.start(queue: queue)
        } catch { status = .failed("The limits listener could not start.") }
    }
    public func stop() {
        generation += 1; listener?.cancel(); listener = nil
        let current = Array(peers.values); peers.removeAll()
        current.forEach { $0.close() }; status = .stopped
    }
    @MainActor private final class Peer {
        let connection: NWConnection
        let port: UInt16
        let handler: @Sendable (T3LimitsRequest) async -> T3LimitsResponse
        let finished: () -> Void
        var buffer = Data()
        var timeout: Task<Void, Never>?
        var work: Task<Void, Never>?
        var closed = false, responded = false
        init(connection: NWConnection, port: UInt16, handler: @escaping @Sendable (T3LimitsRequest) async -> T3LimitsResponse, finished: @escaping () -> Void) {
            self.connection = connection; self.port = port; self.handler = handler; self.finished = finished
        }
        func start(queue: DispatchQueue) {
            connection.start(queue: queue)
            deadline(10)   // reading the request
            receive()
        }
        /// One deadline at a time: reading (10 s), handling (60 s), then writing the response (10 s).
        func deadline(_ seconds: Int) {
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }; self?.close()
            }
        }
        func close() {
            guard !closed else { return }; closed = true
            timeout?.cancel(); work?.cancel(); connection.cancel(); finished()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, !self.closed, !self.responded else { return }
                    if let data { self.buffer.append(data) }
                    if self.parse() { return }
                    if complete || error != nil { self.close() } else { self.receive() }
                }
            }
        }
        func parse() -> Bool {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16384 { send(.error(431, "Request headers are too large.")); return true }; return false
            }
            guard range.upperBound <= 16384 else { send(.error(431, "Request headers are too large.")); return true }
            guard let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { send(.error(400, "Invalid request.")); return true }
            let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].contains("#") else { send(.error(400, "Invalid request.")); return true }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { send(.error(400, "Invalid headers.")); return true }
                let name = String(line[..<colon]).lowercased()
                guard !name.isEmpty, name.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil, headers[name] == nil else { send(.error(400, "Invalid headers.")); return true }
                headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { send(.error(400, "Chunked requests are not supported.")); return true }
            let rawLength = headers["content-length"] ?? "0"
            guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(rawLength) else { send(.error(400, "Invalid Content-Length.")); return true }
            guard length <= T3LimitsHandler.bodyLimit else { send(.error(413, "Request body is too large.")); return true }
            let end = range.upperBound + length
            guard buffer.count >= end else { return false }
            let req = T3LimitsRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: buffer.subdata(in: range.upperBound..<end), port: port)
            responded = true
            deadline(60)   // bounds the hub and provider work (each hub call also stops at 45 s)
            work = Task { [weak self, handler] in
                let response = await handler(req)
                guard let self, !self.closed else { return }; self.send(response)
            }
            return true
        }
        func send(_ response: T3LimitsResponse) {
            guard !closed else { return }; responded = true
            deadline(10)   // a peer that stops reading can't hold one of the 16 slots
            let head = "HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close() } })
        }
    }
}
