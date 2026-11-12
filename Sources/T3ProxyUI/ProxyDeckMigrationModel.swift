import Foundation
import Combine
import T3ProxyCore

/// Owns launch/retry only. Requests acquire a current key/client together through Monitor.management.
@MainActor public final class T3LimitsServerModel: ObservableObject {
    public static let shared = T3LimitsServerModel()
    @Published public private(set) var status: T3LimitsServerStatus = .stopped
    private var server: T3LimitsServer?
    private var timer: Timer?
    private var watch: AnyCancellable?
    public init() {}
    public func start(monitor: Monitor) {
        guard server == nil else { return }
        let server = T3LimitsServer { [weak monitor] request in
            await Self.handle(request, monitor: monitor)
        }
        self.server = server
        watch = server.$status.sink { [weak self] status in
            self?.status = status
            if case .listening(let port) = status { ProxyDeckDetector.shared.setShimOwnsPort(port == 8318) }
            else { ProxyDeckDetector.shared.setShimOwnsPort(false) }
        }
        retry()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        }
    }
    private static func handle(_ request: T3LimitsRequest, monitor: Monitor?) async -> T3LimitsResponse {
        guard let monitor else { return .error(503, "Management access is unavailable.") }
        do {
            return try await monitor.management { client, key in
                let handler = T3LimitsHandler(key: {
                    guard client.gate.permits(key) else { throw ManagementError.locked }
                    return key
                }, hub: client)
                return await handler.handle(request)
            }
        } catch { return .error(503, "Management access is unavailable.") }
    }
    /// Binds 8318 only once a probe shows Proxy Deck's launch agent is not loaded; otherwise waits for the next try.
    public func retry() {
        guard let server else { return }
        if case .listening = server.status { return }
        guard ProxyDeckDetector.shared.mayClaimPort else {
            if case .stopped = server.status { status = .portBusy(8318) }
            _ = ProxyDeckDetector.shared.cachedState   // schedules a probe for the next try
            return
        }
        server.start()
    }
    public func stop() {
        timer?.invalidate(); timer = nil; server?.stop(); watch = nil; server = nil
        status = .stopped; ProxyDeckDetector.shared.setShimOwnsPort(false)
    }
}

@MainActor public final class ProxyDeckMigrationModel: ObservableObject {
    public static let shared = ProxyDeckMigrationModel()
    @Published public private(set) var proxyDeckState: ProxyDeckState = .active
    @Published public private(set) var importing = false
    @Published public private(set) var importResult: ProxyDeckImport.Result?
    @Published public private(set) var importedPlans: Int?
    @Published public private(set) var error: String?
    @Published public private(set) var actionInProgress = false
    @Published public private(set) var retirementResult: ProxyDeckRetirement.Result?
    @Published public private(set) var shimStatus: T3LimitsServerStatus = .stopped
    /// Proxy Deck was stopped but its database changed in the last 15 minutes ("Stopped · waiting to go quiet").
    @Published public private(set) var stoppedButSettling = false
    private weak var monitor: Monitor?
    private var timer: Timer?
    private var watch: AnyCancellable?
    /// Persisted, so a restart between Retire and the end of the quiet period still turns recording on.
    private var enableRecordingWhenInactive: Bool {
        get { UserDefaults.standard.bool(forKey: "proxyDeck.enableRecordingWhenRetired") }
        set { UserDefaults.standard.set(newValue, forKey: "proxyDeck.enableRecordingWhenRetired") }
    }
    public init() {}
    /// The lead calls once at launch. Never stops Proxy Deck or imports automatically.
    public func start(monitor: Monitor) {
        guard self.monitor == nil else { return }
        self.monitor = monitor
        T3LimitsServerModel.shared.start(monitor: monitor)
        watch = T3LimitsServerModel.shared.$status.sink { [weak self] in self?.shimStatus = $0 }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    public func refresh() async {
        proxyDeckState = await Task.detached(priority: .utility) { ProxyDeckDetector.shared.refresh() }.value
        stoppedButSettling = proxyDeckState == .active && ProxyDeckDetector.shared.agentLoaded == false
        if enableRecordingWhenInactive && proxyDeckState != .active {
            enableRecordingWhenInactive = false
            UsageRecorderModel.shared.enabled = true
            UsageModel.shared.refresh()
        }
    }
    public func importHistory() async {
        guard !importing, !actionInProgress else { return }
        importing = true; error = nil
        defer { importing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                let history = try ProxyDeckImport.importHistory(from: URL(fileURLWithPath: SQLiteUsageSource.proxyDeckPath))
                let plans = try ProxyDeckImport.importPlans()
                return (history, plans)
            }.value
            importResult = result.0; importedPlans = result.1
            UsageModel.shared.refresh()
        } catch { self.error = "Couldn't import Proxy Deck history. You can safely retry." }
        await refresh()
    }
    /// Explicit confirmed action only. Source files and history are retained.
    public func retire() async {
        guard !actionInProgress, !importing else { return }
        actionInProgress = true; error = nil
        defer { actionInProgress = false }
        ProxyDeckDetector.shared.invalidate()
        let result = await Task.detached(priority: .utility) { ProxyDeckRetirement().retire() }.value
        retirementResult = result
        await refresh()   // probe first: the shim claims 8318 only once the launch agent is gone
        if result.succeeded {
            if let monitor { T3LimitsServerModel.shared.start(monitor: monitor) }
            T3LimitsServerModel.shared.retry()
            // The required 15-minute mtime guard can outlive bootout. Never pop while it says ACTIVE.
            enableRecordingWhenInactive = true
        } else { error = "Proxy Deck could not be fully retired. Check the command results before retrying." }
        await refresh()
    }
    /// Explicit undo: release our listener before asking Proxy Deck to reclaim 8318.
    public func restore() async {
        guard !actionInProgress, !importing else { return }
        actionInProgress = true; error = nil; enableRecordingWhenInactive = false
        defer { actionInProgress = false }
        // Switch recording off (an in-flight batch still finishes and is saved); not the quit shutdown, which would
        // stop this recorder for good.
        UsageRecorderModel.shared.enabled = false
        T3LimitsServerModel.shared.stop()
        ProxyDeckDetector.shared.invalidate()
        let result = await Task.detached(priority: .utility) { ProxyDeckRetirement().restore() }.value
        ProxyDeckDetector.shared.invalidate()   // anything probed before the bootstrap is stale
        retirementResult = result
        if !result.succeeded || result.plistMissing { error = "Proxy Deck could not be restored. Check that its launch-agent plist is present." }
        await refresh()
        if let monitor {
            UsageRecorderModel.shared.start(monitor: monitor)
            T3LimitsServerModel.shared.start(monitor: monitor)
        }
    }
}
