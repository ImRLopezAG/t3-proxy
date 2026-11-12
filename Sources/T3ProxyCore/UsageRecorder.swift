import Foundation
import CryptoKit
import SQLite3
import Darwin

public enum UsageRecorderStatus: Sendable, Equatable {
    case off, blockedByOtherRecorder, waitingForHub
    case recording(lastAt: Date?, total: Int)
    case statisticsDisabled, keyRejected, unsupported, failed(String)
}

/// Destructive queue access, intentionally separate from ProxyClient's read-only API.
/// Only UsageRecorder calls this, after opt-in, competing-recorder checks and a storage preflight.
/// Uses exactly ManagementClient's loopback session, redirect refusal and shared key gate.
struct UsageQueueClient: Sendable {
    let management: ManagementClient
    func pop(key: String) async throws -> Data {
        guard management.gate.permits(key) else { throw ManagementError.locked }
        var components = URLComponents(url: management.endpoint.base.appendingPathComponent("v0/management/usage-queue"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "count", value: "200")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do { (data, response) = try await management.session.data(for: request) }
        catch { throw ProxyError.unreachable }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { management.gate.reject(key); throw ProxyError.unauthorized }
        guard code == 200 else { throw ProxyError.http(code) }
        guard data.count <= 8 * 1024 * 1024 else { throw ProxyError.incompatible }   // 200 records are far smaller
        return data
    }
}

/// Opt-in, single-consumer history recorder. No key is retained. tick() does nothing by default.
/// Failed transactions retain only sanitized rows in memory; no further queue read occurs until
/// they commit. This protects ordinary write failures, not process termination before commit.
public actor UsageRecorder {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/T3 Proxy/usage.sqlite")
    }
    public static func otherRecorderPresent(fileManager: FileManager = .default, state: ProxyDeckState? = nil) -> Bool {
        otherRecorderPresent(fileManager: fileManager, proxyDeckPath: SQLiteUsageSource.proxyDeckPath,
                             overridePath: UserDefaults.standard.string(forKey: "usageDatabasePath"), state: state ?? ProxyDeckDetector.shared.cachedState)
    }
    static func otherRecorderPresent(fileManager: FileManager, proxyDeckPath: String, overridePath: String?, state: ProxyDeckState? = nil) -> Bool {
        if (state ?? ProxyDeckDetector.fileState(path: proxyDeckPath, fileManager: fileManager)) == .active { return true }
        if let overridePath {
            return URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
                != defaultDatabaseURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        return false
    }

    private let databaseURL: URL
    /// Replaced on each tick by the Monitor's current client, so a hub port change in Settings is followed.
    private var client: ManagementClient
    private let otherRecorder: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var enabled = false
    private var pending: [UsageRecord] = []
    private var inFlight = false
    private var nextPopAt = Date.distantPast
    private var failures = 0
    private var status: UsageRecorderStatus = .off
    private var lastAt: Date?
    private var total = 0
    /// Bumped when the Monitor moves to another port/client: a tick from an older generation saves what it already
    /// received and then stops popping.
    private var generation = 0
    /// Set on quit: no further pops; pending rows are saved or spooled.
    private var stopped = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Rows popped but not yet in SQLite survive a quit or crash here (same sanitised fields, 0600).
    private var spoolURL: URL { databaseURL.deletingLastPathComponent().appendingPathComponent("usage-pending.json") }

    public init(databaseURL: URL = UsageRecorder.defaultDatabaseURL, client: ManagementClient) {
        self.databaseURL = databaseURL; self.client = client
        self.otherRecorder = { UsageRecorder.otherRecorderPresent(state: ProxyDeckDetector.shared.refresh()) }; self.now = { Date() }
    }

    init(databaseURL: URL, client: ManagementClient,
         otherRecorder: @escaping @Sendable () -> Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.databaseURL = databaseURL; self.client = client; self.otherRecorder = otherRecorder; self.now = now
    }

    /// The UI calls this only in response to the explicit user preference (default false).
    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value { status = .off }
        else if otherRecorder() { status = .blockedByOtherRecorder }
        nextPopAt = .distantPast
    }

    /// The Monitor moved to another endpoint: use its new client, and end any tick still talking to the old one.
    public func retarget(_ current: ManagementClient) {
        guard current.endpoint != client.endpoint else { return }
        client = current; generation += 1
    }

    /// Quit: stop popping, wait for an in-flight batch, then save what is pending (or spool it).
    public func shutdown() async {
        stopped = true
        if inFlight { await withCheckedContinuation { idleWaiters.append($0) } }
        do { try flush() } catch { spool() }
    }

    /// `client`: the Monitor's current management client (new port, new key gate after a port change).
    public func tick(key: String, client current: ManagementClient? = nil) async -> UsageRecorderStatus {
        guard !inFlight else { return status }
        if let current { retarget(current) }
        inFlight = true
        defer {
            inFlight = false
            let waiters = idleWaiters; idleWaiters = []
            waiters.forEach { $0.resume() }
        }
        // Local recovery precedes every gate, including disable, competing recorder and key changes.
        if pending.isEmpty { pending = loadSpool() }
        do { if !pending.isEmpty { try flush() } }
        catch { spool(); status = .failed("Couldn't save usage history. Queued records will be retried."); return status }
        guard enabled, !stopped else { status = .off; return status }
        let gen = generation, client = self.client
        guard !otherRecorder() else { status = .blockedByOtherRecorder; return status }
        guard !Task.isCancelled else { return status }
        guard client.gate.permits(key) else {
            status = key.isEmpty ? .waitingForHub : .keyRejected; return status
        }
        guard now() >= nextPopAt else { return status }
        do {
            let config = try await client.configSummary(key: key)
            guard gen == generation, !stopped else { return status }
            guard config.usageStatistics == true else { status = .statisticsDisabled; nextPopAt = now().addingTimeInterval(30); return status }
            // Check storage BEFORE the first destructive request (and each subsequent batch).
            for _ in 0..<10 {
                guard enabled, !stopped, !Task.isCancelled else { status = .off; return status }
                // Moved to another port meanwhile: never pop the old hub again from this tick.
                guard gen == generation else { return status }
                guard !otherRecorder() else { status = .blockedByOtherRecorder; return status }
                do { total = try UsageStore.prepare(databaseURL, now: now()) }
                catch { throw UsageStoreError.unavailable }
                let data = try await UsageQueueClient(management: client).pop(key: key)
                // No suspension between receiving a batch and attempting its transaction.
                let raw = try JSONSerialization.jsonObject(with: data)
                guard let records = raw as? [Any] else { throw ProxyError.incompatible }
                pending = records.compactMap { ($0 as? [String: Any]).flatMap { UsageRecord($0, now: now()) } }
                try flush()
                if records.count < 200 { break }
            }
            failures = 0; nextPopAt = now().addingTimeInterval(30)
            status = .recording(lastAt: lastAt, total: total)
        } catch {
            failures = min(failures + 1, 5)
            nextPopAt = now().addingTimeInterval(min(900, 30 * pow(2, Double(failures))))
            switch error {
            case ProxyError.unauthorized, ManagementError.locked: status = .keyRejected
            case ProxyError.http(404): status = .unsupported
            case ProxyError.unreachable: status = .waitingForHub
            case is UsageStoreError:
                spool()   // rows already popped must outlive this process
                status = .failed("Couldn't save usage history. Queued records will be retried.")
            default: status = .failed("The hub returned an invalid usage queue response.")
            }
        }
        return status
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        total = try UsageStore.write(pending, to: databaseURL, now: now())
        lastAt = max(lastAt ?? .distantPast, pending.map { Date(timeIntervalSince1970: Double($0.ts) / 1000) }.max() ?? .distantPast)
        pending.removeAll(keepingCapacity: false)
        try? FileManager.default.removeItem(at: spoolURL)
    }

    /// Best effort: pending rows to the spool file (owner-only), so a quit or crash before the next write keeps them.
    private func spool() {
        guard !pending.isEmpty, let data = try? JSONEncoder().encode(Array(pending.suffix(5_000))) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: spoolURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? fm.destinationOfSymbolicLink(atPath: spoolURL.path)) == nil else { return }
        let tmp = spoolURL.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? fm.replaceItemAt(spoolURL, withItemAt: tmp)
        if !fm.fileExists(atPath: spoolURL.path) { try? fm.moveItem(at: tmp, to: spoolURL) }
    }

    private func loadSpool() -> [UsageRecord] {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: spoolURL.path)) == nil,
              let attrs = try? fm.attributesOfItem(atPath: spoolURL.path), attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? .max) < 16 * 1024 * 1024,
              let data = fm.contents(atPath: spoolURL.path),
              let rows = try? JSONDecoder().decode([UsageRecord].self, from: data) else { return [] }
        return rows.filter(\.isValid)
    }
}

/// Only this allowlist crosses the storage boundary; raw queue JSON never reaches SQLite (or the spool).
private struct UsageRecord: Codable {
    let id: String, ts: Int64, provider: String, model: String, accountKey: String?, authType: String
    let input: Int64, output: Int64, reasoning: Int64, cached: Int64, total: Int64, failed: Int64, latency: Int64
    init?(_ raw: [String: Any], now: Date) {
        guard let timestamp = raw["timestamp"] as? String, timestamp.count <= 64,
              let date = Account.parseDate(timestamp), date.timeIntervalSince1970 >= 0,
              date <= now.addingTimeInterval(300) else { return nil }
        ts = Int64((date.timeIntervalSince1970 * 1000).rounded())
        func token(_ value: Any?, max: Int64 = 1_000_000_000) -> Int64? {
            guard let value, !(value is NSNull) else { return 0 }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= Double(max),
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.int64Value
        }
        if let tokens = raw["tokens"], !(tokens is NSNull), !(tokens is [String: Any]) { return nil }
        let tokens = raw["tokens"] as? [String: Any] ?? [:]
        guard let i = token(tokens["input_tokens"]), let o = token(tokens["output_tokens"]),
              let r = token(tokens["reasoning_tokens"]), let c = token(tokens["cached_tokens"]),
              let t = token(tokens["total_tokens"]), let l = token(raw["latency_ms"], max: 86_400_000) else { return nil }
        input = i; output = o; reasoning = r; cached = c; total = t; latency = l
        failed = (raw["failed"] as? Bool) == true ? 1 : 0
        func safe(_ value: Any?, max: Int, fallback: String, pattern: String) -> String {
            guard let s = value as? String, s.count <= max, s.range(of: pattern, options: .regularExpression) != nil else { return fallback }
            return s
        }
        provider = safe(raw["provider"], max: 40, fallback: "unknown", pattern: #"^[A-Za-z0-9-]{1,40}$"#).lowercased()
        model = safe(raw["model"], max: 200, fallback: "unknown", pattern: #"^[A-Za-z0-9._:/+-]{1,200}$"#)
        authType = safe(raw["auth_type"], max: 32, fallback: "unknown", pattern: #"^[A-Za-z0-9_-]{1,32}$"#)
        accountKey = (raw["auth_index"] as? String).flatMap { $0.isEmpty || $0.count > 4096 ? nil : PlanCache.accountKey($0) }
        let requestID = safe(raw["request_id"], max: 128, fallback: "", pattern: #"^[A-Za-z0-9_-]{1,128}$"#)
        // Hash canonical JSON, including unknown fields, without persisting those fields or their values.
        guard let canonical = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return nil }
        id = requestID.isEmpty ? SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined() : requestID
    }
    /// Claude's cache writes appear only in `total_tokens` (see `SQLiteUsageSource.cacheCreation`).
    var cacheCreation: Int64 { provider == "claude" ? max(0, total - input - output - cached) : 0 }
    /// Re-checks rows read back from the spool against the same bounds as fresh records.
    var isValid: Bool {
        func short(_ s: String, _ max: Int, _ pattern: String) -> Bool { s.count <= max && s.range(of: pattern, options: .regularExpression) != nil }
        return short(id, 128, #"^[A-Za-z0-9_-]{1,128}$"#) && short(provider, 40, #"^[a-z0-9-]{1,40}$"#)
            && short(model, 200, #"^[A-Za-z0-9._:/+-]{1,200}$"#) && short(authType, 32, #"^[A-Za-z0-9_-]{1,32}$"#)
            && (accountKey.map { short($0, 64, #"^[0-9a-f]{1,64}$"#) } ?? true)
            && ts >= 0 && [input, output, reasoning, cached, total, latency].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000 } && (failed == 0 || failed == 1)
    }
}

enum UsageStoreError: Error { case unavailable }
enum UsageStore {
    static let schema = """
        CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, account_key TEXT, auth_type TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cached INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_creation INTEGER NOT NULL, total INTEGER NOT NULL, failed INTEGER NOT NULL, latency_ms INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS requests_by_time ON requests (ts);
        """
    static func prepare(_ url: URL, now: Date) throws -> Int {
        try withDB(url) { db in
            try exec(db, "DELETE FROM requests WHERE ts < \(Int64(now.addingTimeInterval(-400 * 86400).timeIntervalSince1970 * 1000))")
            let total = try count(db)
            guard total < 2_000_000 else { throw UsageStoreError.unavailable }
            return total
        }
    }
    fileprivate static func write(_ records: [UsageRecord], to url: URL, now: Date) throws -> Int {
        try withDB(url) { db in
            try exec(db, "BEGIN IMMEDIATE")
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO requests VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?15,?12,?13,?14)", -1, &statement, nil) == SQLITE_OK, let statement else { throw UsageStoreError.unavailable }
                defer { sqlite3_finalize(statement) }
                for r in records {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    for (index, value) in [(1, r.id), (3, r.provider), (4, r.model), (5, r.accountKey), (6, r.authType)] {
                        if let value {
                            let rc = value.withCString { sqlite3_bind_text(statement, Int32(index), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                            guard rc == SQLITE_OK else { throw UsageStoreError.unavailable }
                        }
                    }
                    for (index, value) in [(2, r.ts), (7, r.input), (8, r.output), (9, r.reasoning), (10, r.cached), (11, r.cached), (12, r.total), (13, r.failed), (14, r.latency), (15, r.cacheCreation)] {
                        guard sqlite3_bind_int64(statement, Int32(index), value) == SQLITE_OK else { throw UsageStoreError.unavailable }
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.unavailable }
                }
                try exec(db, "COMMIT")
                return try count(db)
            } catch { try? exec(db, "ROLLBACK"); throw error }
        }
    }
    static func withDB<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { throw UsageStoreError.unavailable }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var diskBytes: Int64 = 0
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            // fileExists follows links and returns false for dangling ones.
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else { throw UsageStoreError.unavailable }
            guard fm.fileExists(atPath: path) else { continue }
            let attrs = try fm.attributesOfItem(atPath: path)
            diskBytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  diskBytes < 384 * 1024 * 1024 else { throw UsageStoreError.unavailable }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        if !fm.fileExists(atPath: url.path) {
            let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard fd >= 0 else { throw UsageStoreError.unavailable }
            Darwin.close(fd)
        }
        // Foundation deliberately abbreviates /private/var to /var on macOS; SQLite's
        // NOFOLLOW flag requires the physical parent path (including in the temp directory).
        guard let physicalParent = directory.path.withCString({ realpath($0, nil) }) else { throw UsageStoreError.unavailable }
        defer { free(physicalParent) }
        let physicalPath = String(cString: physicalParent) + "/" + url.lastPathComponent
        var handle: OpaquePointer?
        guard sqlite3_open_v2(physicalPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle); throw UsageStoreError.unavailable
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2000)
        try exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA journal_size_limit=8388608;")
        try exec(db, schema)
        return try body(db)
    }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageStoreError.unavailable }
    }
    private static func count(_ db: OpaquePointer) throws -> Int {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM requests", -1, &s, nil) == SQLITE_OK, let s else { throw UsageStoreError.unavailable }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw UsageStoreError.unavailable }
        return Int(sqlite3_column_int64(s, 0))
    }
}
