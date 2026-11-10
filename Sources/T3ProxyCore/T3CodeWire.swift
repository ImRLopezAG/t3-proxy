import Foundation

/// Effect RPC uses ordinary JSON in each WebSocket message, including batched frames.
indirect enum T3CodeJSON: Codable, Sendable {
    case object([String: T3CodeJSON]), array([T3CodeJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let v) = self { v[key] } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var data: Data { get throws { try JSONEncoder().encode(self) } }
    func containsTag(_ tag: String) -> Bool {
        switch self {
        case .object(let v): v["_tag"]?.string == tag || v.values.contains { $0.containsTag(tag) }
        case .array(let v): v.contains { $0.containsTag(tag) }
        default: false
        }
    }
}

struct T3CodeRPCFrame: Decodable, Sendable {
    let _tag: String
    let requestId: String?
    let values: [T3CodeJSON]?
    let exit: T3CodeJSON?
    var rpcError: T3CodeError? {
        guard exit?["_tag"]?.string == "Failure" else { return nil }
        if exit?.containsTag("EnvironmentAuthorizationError") == true { return .permissionDenied }
        return .commandRejected
    }
}

struct T3CodeCommand: Encodable, Sendable {
    struct DispatchMode: Encodable, Sendable { let type: String }
    let type: String
    var commandId = UUID().uuidString
    let threadId: String
    var reason: String?
    var messageId: String?
    var manualContinuationOfRunId: String?
    var text: String?
    var attachments: [String]?
    var dispatchMode: DispatchMode?
    var createdBy: String?
    var creationSource: String?
}

enum T3CodeWire {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) { return date }
            throw T3CodeError.invalidResponse
        }
        do { return try decoder.decode(type, from: data) }
        catch let error as T3CodeError { throw error }
        catch { throw T3CodeError.invalidResponse }
    }
    static func connectionURL(_ endpoint: URL) throws -> URL {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "ws", parts.host == "127.0.0.1", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path == "/ws",
              (1...65535).contains(parts.port ?? 80) else { throw T3CodeError.invalidEndpoint }
        parts.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        guard let url = parts.url else { throw T3CodeError.invalidEndpoint }
        return url
    }
    static func validateConfig(_ data: Data) throws {
        struct Config: Decodable {
            struct Environment: Decodable { let orchestrationProtocolVersion: Int? }
            let environment: Environment?
        }
        guard let config = try? decode(Config.self, from: data),
              config.environment?.orchestrationProtocolVersion == 2 else { throw T3CodeError.unsupportedServerVersion }
    }
    static func frames(_ data: Data) throws -> [T3CodeRPCFrame] {
        let value = try decode(T3CodeJSON.self, from: data)
        if case .array(let values) = value { return try values.map { try decode(T3CodeRPCFrame.self, from: $0.data) } }
        return [try decode(T3CodeRPCFrame.self, from: data)]
    }
    private struct Request<Payload: Encodable>: Encodable {
        let _tag = "Request"
        let id: String
        let tag: String
        let payload: Payload
        let headers: [String] = []
    }
    static func request<P: Encodable>(id: String, method: String, payload: P) throws -> Data {
        try JSONEncoder().encode(Request(id: id, tag: method, payload: payload))
    }
    static func control(_ tag: String, requestID: String? = nil) throws -> Data {
        struct Control: Encodable { let _tag: String; let requestId: String? }
        return try JSONEncoder().encode(Control(_tag: tag, requestId: requestID))
    }
    static func stop(threadID: String) -> T3CodeCommand { T3CodeCommand(type: "thread.stop", threadId: threadID) }
    static func resumeLimited(thread: T3CodeThread) throws -> T3CodeCommand {
        guard thread.isUsageLimited, let run = thread.latestRunId, !run.isEmpty,
              thread.archivedAt == nil, thread.deletedAt == nil, thread.pendingRuntimeRequest == nil,
              thread.activeRunId == nil, thread.activityRunStatus == nil else { throw T3CodeError.notUsageLimited }
        return T3CodeCommand(type: "message.dispatch", threadId: thread.id, messageId: UUID().uuidString,
                             manualContinuationOfRunId: run, text: "Continue where you left off.", attachments: [],
                             dispatchMode: .init(type: "start_immediately"), createdBy: "user", creationSource: "web")
    }
}

/// Fresh subscriptions always request a full snapshot. Enrichment snapshots merge project metadata only.
struct T3CodeShellState {
    private var threads: [String: T3CodeThread] = [:]
    private var archived: [String: T3CodeThread] = [:]
    private var projects: [String: T3CodeProject] = [:]
    private var sequence = 0
    private(set) var hasSnapshot = false
    var snapshot: T3CodeSnapshot {
        func sorted(_ values: Dictionary<String, T3CodeThread>.Values) -> [T3CodeThread] {
            values.sorted {
                if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                return $0.id < $1.id
            }
        }
        return .init(sequence: sequence, projects: projects.values.sorted { $0.id < $1.id },
                     threads: sorted(threads.values), archivedThreads: sorted(archived.values))
    }
    mutating func apply(_ data: Data) throws {
        struct VersionHeader: Decodable {
            struct Version: Decodable { let schemaVersion: Int }
            let snapshot: Version?
        }
        if let version = try T3CodeWire.decode(VersionHeader.self, from: data).snapshot?.schemaVersion, version != 2 {
            throw T3CodeError.unsupportedServerVersion
        }
        struct Item: Decodable {
            struct Snapshot: Decodable {
                let schemaVersion: Int
                let snapshotSequence: Int
                let projects: [T3CodeProject]
                let threads: [T3CodeThread]
                let archivedThreads: [T3CodeThread]
            }
            let kind: String
            let snapshot: Snapshot?
            let resolvedRepositoryIdentityRoots: [String]?
            let sequence: Int?
            let thread: T3CodeThread?
            let threadId: String?
            let location: String?
            let project: T3CodeProject?
            let projectId: String?
        }
        let item = try T3CodeWire.decode(Item.self, from: data)
        switch item.kind {
        case "snapshot":
            guard let s = item.snapshot else { throw T3CodeError.invalidResponse }
            if item.resolvedRepositoryIdentityRoots != nil {
                for p in s.projects { projects[p.id] = p }
                return
            }
            threads = s.threads.reduce(into: [:]) { $0[$1.id] = $1 }
            archived = s.archivedThreads.reduce(into: [:]) { $0[$1.id] = $1 }
            projects = s.projects.reduce(into: [:]) { $0[$1.id] = $1 }
            sequence = s.snapshotSequence
            hasSnapshot = true
        case "thread.updated":
            guard let t = item.thread, item.location == "active" || item.location == "archive" else { throw T3CodeError.invalidResponse }
            threads.removeValue(forKey: t.id); archived.removeValue(forKey: t.id)
            if item.location == "active" { threads[t.id] = t } else { archived[t.id] = t }
        case "thread.removed":
            guard let id = item.threadId, item.location == "active" || item.location == "archive" else { throw T3CodeError.invalidResponse }
            if item.location == "active" { threads.removeValue(forKey: id) } else { archived.removeValue(forKey: id) }
        case "project.updated":
            guard let p = item.project else { throw T3CodeError.invalidResponse }
            projects[p.id] = p
        case "project.removed":
            guard let id = item.projectId else { throw T3CodeError.invalidResponse }
            projects.removeValue(forKey: id)
        case "synchronized": break
        default: throw T3CodeError.unsupportedServerVersion
        }
        if let n = item.sequence { sequence = max(sequence, n) }
    }
}
