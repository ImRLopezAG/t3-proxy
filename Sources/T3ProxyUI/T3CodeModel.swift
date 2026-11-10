import Foundation
import AppKit
import Combine
import T3ProxyCore

/// Owns the T3 Code client: the scoped session (Keychain), connection state, the latest snapshot and reconnects.
/// Connects only to 127.0.0.1 on the port from `server-runtime.json`. The token is never logged or shown.
@MainActor
public final class T3CodeModel: ObservableObject {
    private static var instance: T3CodeModel?
    public static func shared() -> T3CodeModel {
        if let m = instance { return m }
        let m = T3CodeModel(); instance = m; return m
    }

    public enum Status: Equatable {
        case notConnected, connecting, connected(version: String?)
        case notRunning, unsupported, expired, failed(String)
        public var text: String {
            switch self {
            case .notConnected: "Not connected"
            case .connecting: "Connecting…"
            case .connected(let v): v.map { "Connected · \($0)" } ?? "Connected"
            case .notRunning: "T3 Code isn't running"
            case .unsupported: "Unsupported T3 Code version"
            case .expired: "Session expired or revoked — Connect again"
            case .failed(let m): m
            }
        }
        public var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    @Published public private(set) var status: Status = .notConnected
    @Published public private(set) var snapshot: T3CodeSnapshot?
    @Published public private(set) var updatedAt: Date?
    @Published public var expandedThreads: Set<String> = []
    /// First-seen fallback when the shell lacks a usable sidebar timestamp.
    @Published public private(set) var runningSince: [String: Date] = [:]
    @Published public private(set) var busy = false
    @Published public private(set) var actionBusy = false
    @Published public private(set) var hasPendingRevocations = false
    /// Last command result, for the panel footer. Fixed phrases only.
    @Published public var notice: String?

    private static let sessionKey = "t3code.sessionID"
    private let store = T3CodeTokenStore()
    private let cli = T3CodeTokenCLI()
    private let paths = T3CodePaths()
    private var client: T3CodeClient?
    private var endpoint: T3CodeActionConnection?
    private let revocations = T3CodePendingRevocations()
    @Published public private(set) var revoking = false
    private var events: Task<Void, Never>?
    private var timer: Timer?
    private var started = false
    private var generation = 0
    /// Changes whenever a new client is created (reconnect, runtime change). Lets observers tell connections apart.
    public var clientGeneration: Int { generation }

    /// First sighting of each running thread's current run, saved so a relaunch keeps elapsed times.
    private struct RunStart: Codable, Equatable { let run: String; let since: Date }
    private static let runStartsKey = "t3code.runStarts"
    private var runStarts: [String: RunStart] = {
        guard let data = UserDefaults.standard.data(forKey: runStartsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RunStart].self, from: data)) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(runStarts), forKey: Self.runStartsKey) }
    }

    private var sessionID: String? {
        get { UserDefaults.standard.string(forKey: Self.sessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionKey) }
    }
    /// True once a session was issued; until then the Keychain is never read (no prompt).
    public var hasSession: Bool { sessionID != nil }

    private init() { hasPendingRevocations = !revocations.sessionIDs.isEmpty }

    public func start() {
        guard !started else { return }
        started = true
        Task { await revokeOldSessions() }
        if hasSession { reconnect() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Issues a 30-day scoped session, saves it, connects.
    public func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        removeLocalSession()
        await revokeOldSessions()
        status = .connecting
        do {
            let issued = try await cli.issue(ttl: "30d")
            guard store.save(issued.token) else {
                revocations.insert(issued.sessionID)
                await revokeOldSessions()
                status = .failed("Couldn't save the session in the Keychain"); return
            }
            sessionID = issued.sessionID
            reconnect()
        } catch {
            status = runtime() == nil ? .notRunning : .failed("Couldn't create a T3 Code session")
        }
    }

    /// Removes local access immediately and retains the ID until revocation succeeds.
    public func disconnect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        removeLocalSession()
        status = .notConnected
        await revokeOldSessions()
    }

    private func removeLocalSession() {
        if let id = sessionID { revocations.insert(id) }
        hasPendingRevocations = !revocations.sessionIDs.isEmpty
        generation += 1
        dropClient()
        store.remove(); sessionID = nil
        snapshot = nil; updatedAt = nil; runningSince = [:]; runStarts = [:]
    }

    public func revokeOldSessions() async {
        guard !revoking else { return }
        revoking = true; defer { revoking = false }
        var attempted: Set<String> = []
        while let id = revocations.sessionIDs.first(where: { !attempted.contains($0) }) {
            attempted.insert(id)
            do { try await cli.revoke(sessionID: id); revocations.didRevoke(id) }
            catch { /* Keep the ID for a later explicit retry. Never surface CLI output. */ }
        }
        hasPendingRevocations = !revocations.sessionIDs.isEmpty
    }

    /// Recreates the client with the stored token and the current runtime port.
    public func reconnect() {
        guard hasSession else { status = .notConnected; return }
        generation += 1
        let g = generation
        dropClient()
        status = .connecting
        Task { [self] in
            guard g == generation else { return }
            guard let rt = runtime(), let p = rt.port else { status = .notRunning; return }
            guard let token = store.load() else {
                removeLocalSession(); status = .expired
                await revokeOldSessions(); return
            }
            guard let c = try? T3CodeClient(port: p, token: token) else { status = .failed("Invalid T3 Code endpoint"); return }
            client = c
            endpoint = .init(generation: g, port: p, pid: rt.pid, startedAt: rt.startedAt)
            status = .connecting
            let stream = await c.updates()
            guard g == generation else { await c.disconnect(); return }
            events = Task { [weak self] in
                for await e in stream {
                    guard let self, self.client === c else { return }
                    self.handle(e, version: rt.serverVersion)
                }
            }
            await c.connect()
        }
    }

    private func dropClient() {
        events?.cancel(); events = nil
        let old = client
        client = nil; endpoint = nil
        Task { await old?.disconnect() }
    }

    private func handle(_ e: T3CodeClientEvent, version: String?) {
        switch e {
        case .snapshot(let s):
            let now = Date()
            snapshot = s; updatedAt = now
            var next: [String: Date] = [:]
            var starts: [String: RunStart] = [:]
            let activeIDs = Set(T3ThreadBoard.sections(s, now: now).flatMap(\.rows).filter { $0.group == .running }.map(\.id))
            for t in s.threads where activeIDs.contains(t.id) || t.attention == .running || t.attention == .waiting {
                // Keep a first-seen fallback per run across relaunches. Shell timestamps take
                // precedence in the board; updatedAt can change for unrelated thread metadata.
                let run = t.activeRunId ?? t.latestRunId ?? ""
                let since = runStarts[t.id].flatMap { $0.run == run ? $0.since : nil } ?? now
                next[t.id] = since; starts[t.id] = RunStart(run: run, since: since)
            }
            if starts != runStarts { runStarts = starts }
            if next != runningSince { runningSince = next }
        case .connection(let c):
            switch c {
            case .connected: status = .connected(version: version)
            case .connecting, .reconnecting:
                generation += 1
                if let e = endpoint {
                    endpoint = .init(generation: generation, port: e.port, pid: e.pid, startedAt: e.startedAt)
                }
                status = runtime() == nil ? .notRunning : .connecting
            case .disconnected: break
            case .failed(.authenticationFailed), .failed(.permissionDenied):
                // Drop the token; never retry with it.
                removeLocalSession()
                status = .expired
                snapshot = nil
                Task { await revokeOldSessions() }
            case .failed(.unsupportedServerVersion):
                status = .unsupported
                generation += 1; dropClient()
            case .failed:
                status = runtime() == nil ? .notRunning : .connecting
            }
        }
    }

    /// Notices T3 Code starting, stopping, or moving to another port.
    private func tick() {
        guard hasSession, !busy else { return }
        let rt = runtime()
        switch status {
        case .notRunning where rt != nil: reconnect()
        case .connecting, .connected:
            if rt == nil { generation += 1; dropClient(); status = .notRunning }
            else if let rt, let endpoint,
                    rt.port != endpoint.port || rt.pid != endpoint.pid || rt.startedAt != endpoint.startedAt { reconnect() }
        default: break
        }
    }

    /// The runtime file of a live server process; nil when T3 Code isn't running.
    private func runtime() -> T3CodeRuntime? {
        guard let d = FileManager.default.contents(atPath: paths.runtime), let rt = T3CodeRuntime.parse(d) else { return nil }
        if let pid = rt.pid, kill(pid, 0) != 0 && errno == ESRCH { return nil }
        return rt
    }

    // MARK: Commands (user-confirmed only)

    public func intent(for thread: T3CodeThread, action: T3CodeActionIntent.Action) -> T3CodeActionIntent? {
        guard status.isConnected, let endpoint else { return nil }
        return T3CodeActionIntent(connection: endpoint, thread: thread, action: action, clientConnection: snapshot?.connection)
    }

    @discardableResult public func validate(_ intent: T3CodeActionIntent) -> Bool {
        let rt = runtime()
        let sameRuntime = rt?.port == endpoint?.port && rt?.pid == endpoint?.pid && rt?.startedAt == endpoint?.startedAt
        let valid = status.isConnected && client != nil && rt != nil && sameRuntime
            && intent.isValid(connection: endpoint, thread: snapshot?.threads.first { $0.id == intent.threadID })
        if !valid { notice = T3CodeActionIntent.changedMessage }
        return valid
    }

    public func beginAction() -> Bool {
        guard !actionBusy else { return false }
        actionBusy = true; return true
    }
    public func endAction() { actionBusy = false }

    public func stop(_ intent: T3CodeActionIntent) async {
        guard validate(intent), intent.action == .stop, let client else { return }
        do { try await client.stop(threadID: intent.threadID, expectedRunID: intent.runID, expectedConnection: intent.clientConnection); notice = "Stop sent" }
        catch { notice = (error as? T3CodeError)?.errorDescription ?? "Stop failed" }
    }

    @discardableResult
    public func resume(_ intent: T3CodeActionIntent) async -> Bool {
        guard validate(intent), intent.action == .resume, let client else { return false }
        do { try await client.resumeLimited(threadID: intent.threadID, expectedRunID: intent.runID, expectedConnection: intent.clientConnection); notice = "Resume sent"; return true }
        catch { notice = (error as? T3CodeError)?.errorDescription ?? "Resume failed"; return false }
    }

    // MARK: Opening T3 Code

    public static func open(thread: T3CodeThread) {
        let url = T3CodeLinks.environmentID().flatMap { T3CodeLinks.threadURL(environmentID: $0, thread: thread) }
        open(url: url)
    }

    /// Opens the thread in the desktop app, or just activates the app when the link can't be built.
    public static func open(threadID: String?) {
        let url = threadID.flatMap { id in
            T3CodeLinks.environmentID().flatMap { T3CodeLinks.threadURL(environmentID: $0, threadID: id) }
        }
        open(url: url)
    }

    private static func open(url: URL?) {
        if let url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url); return
        }
        T3CodePane.openApp()
    }
}
