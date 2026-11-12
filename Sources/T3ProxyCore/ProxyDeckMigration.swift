import Foundation
import Darwin
import SQLite3

public enum ProxyDeckState: Sendable, Equatable { case active, retired, absent }

public struct ProxyDeckCommandResult: Sendable, Equatable {
    public let arguments: [String]
    public let exitStatus: Int32
    public init(arguments: [String], exitStatus: Int32) { self.arguments = arguments; self.exitStatus = exitStatus }
}
public typealias ProxyDeckCommandRunner = @Sendable ([String]) -> Int32

/// Never runs retirement commands on construction. Caller must invoke retire/restore after confirmation.
public struct ProxyDeckRetirement: Sendable {
    public struct Result: Sendable, Equatable {
        public var commands: [ProxyDeckCommandResult]
        public var succeeded: Bool { !plistMissing && !commands.isEmpty && commands.allSatisfy { $0.exitStatus == 0 } }
        public var plistMissing: Bool
    }
    private let uid: UInt32
    private let home: String
    private let runner: ProxyDeckCommandRunner
    private let exists: @Sendable (String) -> Bool
    public init(uid: UInt32 = getuid(), home: String = NSHomeDirectory(), runner: @escaping ProxyDeckCommandRunner = Self.run,
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.uid = uid; self.home = home; self.runner = runner; self.exists = exists
    }
    public static func run(_ arguments: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
    /// Explicit action only. A nonzero bootout remains visible even if disable succeeds.
    public func retire() -> Result {
        let service = "gui/\(uid)/dev.proxy-deck"
        return .init(commands: [["bootout", service], ["disable", service]].map { .init(arguments: $0, exitStatus: runner($0)) }, plistMissing: false)
    }
    public func restore() -> Result {
        let service = "gui/\(uid)/dev.proxy-deck", plist = home + "/Library/LaunchAgents/dev.proxy-deck.plist"
        var commands = [ProxyDeckCommandResult(arguments: ["enable", service], exitStatus: runner(["enable", service]))]
        guard exists(plist) else { return .init(commands: commands, plistMissing: true) }
        let args = ["bootstrap", "gui/\(uid)", plist]
        commands.append(.init(arguments: args, exitStatus: runner(args)))
        return .init(commands: commands, plistMissing: false)
    }
}

/// Read-only probes run on a utility task. UI/recorder callers use the cached result and never wait on launchctl.
public final class ProxyDeckDetector: @unchecked Sendable {
    public static let shared = ProxyDeckDetector()
    private let lock = NSLock()
    private var state: ProxyDeckState
    private var checking = false
    private var shimOwnsPort = false
    /// Whether Proxy Deck's launch agent was loaded at the last probe; nil (treated as loaded) until one completes.
    private var agentLoadedAtLastProbe: Bool?
    /// Bumped by Retire/Restore and port-ownership changes: a probe that started earlier publishes nothing.
    private var generation = 0
    private var probedGeneration = -1
    /// Serialises probes so results can't be published out of order.
    private let probeLock = NSLock()
    private let path: String
    private let loaded: @Sendable () -> Bool
    private let listening: @Sendable () -> Bool
    private let ownsPort: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    public init(path: String = SQLiteUsageSource.proxyDeckPath,
                loaded: @escaping @Sendable () -> Bool = { ProxyDeckRetirement.run(["print", "gui/\(getuid())/dev.proxy-deck"]) == 0 },
                listening: @escaping @Sendable () -> Bool = { ProxyDeckDetector.portIsListening() },
                ownsPort: @escaping @Sendable () -> Bool = { false }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path; self.loaded = loaded; self.listening = listening; self.ownsPort = ownsPort; self.now = now
        self.state = .active // Conservative until the first off-main launch-agent probe completes.
    }
    public var cachedState: ProxyDeckState {
        lock.lock(); let value = state, schedule = !checking; checking = true; lock.unlock()
        if schedule { Task.detached(priority: .utility) { _ = self.refresh() } }
        return value
    }
    @discardableResult public func refresh() -> ProxyDeckState {
        probeLock.lock(); defer { probeLock.unlock() }
        lock.lock(); let own = shimOwnsPort, gen = generation; lock.unlock()
        let next: ProxyDeckState
        let agent = loaded()
        if agent || (!(own || ownsPort()) && listening()) { next = .active }
        else { next = Self.fileState(path: path, now: now()) }
        lock.lock(); defer { lock.unlock() }
        checking = false
        guard gen == generation else { return state }   // invalidated meanwhile: keep the newer view
        state = next; agentLoadedAtLastProbe = agent; probedGeneration = gen
        return next
    }

    /// Whether the last completed probe found Proxy Deck's launch agent loaded (nil before the first probe).
    /// `.active` with an unloaded agent means it was stopped and its database is still within the quiet period.
    public var agentLoaded: Bool? { lock.lock(); defer { lock.unlock() }; return agentLoadedAtLastProbe }

    /// Retire, Restore and port-ownership changes call this: earlier probes no longer count.
    public func invalidate() {
        lock.lock(); generation += 1; agentLoadedAtLastProbe = nil; lock.unlock()
    }

    /// The shim may claim 127.0.0.1:8318 only while Proxy Deck's launch agent is not loaded, so it never wins a
    /// start-up race against Proxy Deck (at login, or right after Restore). Unknown counts as loaded.
    public var mayClaimPort: Bool {
        lock.lock(); defer { lock.unlock() }
        return agentLoadedAtLastProbe == false && probedGeneration == generation
    }
    public func setShimOwnsPort(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard shimOwnsPort != value else { return }
        shimOwnsPort = value; generation += 1; agentLoadedAtLastProbe = nil
    }
    public static func fileState(path: String, fileManager: FileManager = .default, now: Date = Date()) -> ProxyDeckState {
        var present = false
        for p in [path, path + "-wal"] {
            guard let attrs = try? fileManager.attributesOfItem(atPath: p) else { continue }
            present = true
            if let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) < 15 * 60 { return .active }
        }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().path
        return present || fileManager.fileExists(atPath: root + "/src/t3.ts") ? .retired : .absent
    }
    /// TCP connect only; sends no HTTP, authentication or application data.
    public static func portIsListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }; defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(8318).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, 200) > 0 else { return true }
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return true }
        return error == 0
    }
}

public enum ProxyDeckImport {
    public struct Result: Sendable, Equatable { public let sourceRows: Int; public let insertedRows: Int; public var skippedRows: Int { sourceRows - insertedRows } }
    /// The source is copied first, including WAL; SQLite only ever opens the temporary snapshot.
    public static func importHistory(from source: URL, into destination: URL = UsageRecorder.defaultDatabaseURL) throws -> Result {
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath, !destinationPath.hasPrefix(URL(fileURLWithPath: SQLiteUsageSource.proxyDeckPath).deletingLastPathComponent().deletingLastPathComponent().path + "/") else { throw UsageStoreError.unavailable }
        let snapshot = try UsageSnapshots.shared.snapshot(path: sourcePath, fresh: true)
        return try withExtendedLifetime(snapshot) {
            var sourceDB: OpaquePointer?
            guard sqlite3_open_v2(snapshot.file.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB else { sqlite3_close_v2(sourceDB); throw UsageStoreError.unavailable }
            defer { sqlite3_close_v2(sourceDB) }
            let columns = "id,ts,provider,model,account_key,auth_type,input,output,reasoning,cached,cache_read,cache_creation,total,failed,latency_ms"
            var read: OpaquePointer?
            guard sqlite3_prepare_v2(sourceDB, "SELECT \(columns) FROM requests", -1, &read, nil) == SQLITE_OK, let read else { throw UsageStoreError.unavailable }
            defer { sqlite3_finalize(read) }
            return try UsageStore.withDB(destination) { db in
                guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw UsageStoreError.unavailable }
                var committed = false
                defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
                var write: OpaquePointer?
                let slots = (1...15).map { "?\($0)" }.joined(separator: ",")
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO requests (\(columns)) VALUES (\(slots))", -1, &write, nil) == SQLITE_OK, let write else { throw UsageStoreError.unavailable }
                defer { sqlite3_finalize(write) }
                var rows = 0, inserted = 0
                while true {
                    let rc = sqlite3_step(read)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw UsageStoreError.unavailable }
                    sqlite3_reset(write); sqlite3_clear_bindings(write)
                    for col in 0..<15 {
                        guard sqlite3_bind_value(write, Int32(col + 1), sqlite3_column_value(read, Int32(col))) == SQLITE_OK else { throw UsageStoreError.unavailable }
                    }
                    guard sqlite3_step(write) == SQLITE_DONE else { throw UsageStoreError.unavailable }
                    rows += 1; inserted += Int(sqlite3_changes(db))
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw UsageStoreError.unavailable }
                committed = true
                return Result(sourceRows: rows, insertedRows: inserted)
            }
        }
    }
    /// Validated allowlisted plan/org fields, including freshness timestamps and org fingerprints.
    @discardableResult public static func importPlans(from source: URL = URL(fileURLWithPath: PlanCache.proxyDeckPath), into destination: URL = PlanCache.ownURL) throws -> Int {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath(),
              !destination.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: PlanCache.proxyDeckPath).deletingLastPathComponent().deletingLastPathComponent().path + "/") else { throw UsageStoreError.unavailable }
        let plans = PlanCache.load(path: source.path)
        var merged = PlanCache.load(path: destination.path)
        merged.merge(plans) { own, imported in
            (own.observedAt ?? .distantPast) >= (imported.observedAt ?? .distantPast) ? own : imported
        }
        var out: [String: [String: Any]] = [:]
        for (key, p) in merged {
            out[key] = ["plan": p.plan as Any? ?? NSNull(), "org": p.org as Any? ?? NSNull(), "orgId": p.orgID as Any? ?? NSNull(), "at": p.observedAt.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? 0]
        }
        let fm = FileManager.default, directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? fm.removeItem(at: temp) }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw UsageStoreError.unavailable }
        guard rename(temp.path, destination.path) == 0 else { throw UsageStoreError.unavailable }
        return plans.count
    }
}
