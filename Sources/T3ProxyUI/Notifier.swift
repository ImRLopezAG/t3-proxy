import Foundation
import Combine
import UserNotifications
import T3ProxyCore

/// Watches Monitor and LiveQuotaModel, runs `AlertRules`, and posts user notifications.
/// Also feeds the quota history used for forecasts (`QuotaForecaster`).
@MainActor
public final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private static var instances: [ObjectIdentifier: Notifier] = [:]
    public static func shared(for monitor: Monitor, live: LiveQuotaModel) -> Notifier {
        if let n = instances[ObjectIdentifier(monitor)] { return n }
        let n = Notifier(monitor: monitor, live: live)
        instances[ObjectIdentifier(monitor)] = n
        return n
    }

    private static let settingsKey = "alerts.settings.v1", stateKey = "alerts.state.v1"

    @Published public var settings: AlertSettings { didSet { save(settings, Self.settingsKey) } }
    @Published public private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let monitor: Monitor
    private let live: LiveQuotaModel
    private var state: AlertState?
    /// In memory only: the first snapshot after launch seeds it, so pre-existing states never notify.
    private var threadState = T3ThreadAlertState()
    private var bag: Set<AnyCancellable> = []
    private var started = false

    private init(monitor: Monitor, live: LiveQuotaModel) {
        self.monitor = monitor; self.live = live
        settings = Self.load(AlertSettings.self, Self.settingsKey) ?? AlertSettings()
        state = Self.load(AlertState.self, Self.stateKey)
        super.init()
    }

    /// Notification APIs need a real app bundle; `swift run` / tests have none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : .current()
    }

    public func start() {
        guard !started else { return }
        started = true
        center?.delegate = self
        Task { await refreshAuthorization() }
        QuotaForecaster.shared.start(monitor: monitor)
        // Coalesce the 60 s poll, live reads and credit lists into one evaluation.
        Publishers.CombineLatest3(monitor.$accounts, monitor.$reachability, live.$credits)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &bag)
        let t3 = T3CodeModel.shared()
        t3.$snapshot.combineLatest(t3.$status)
            .sink { [weak self] snapshot, status in
                guard let self, status.isConnected, let snapshot else { return }
                self.evaluateThreads(snapshot)
            }
            .store(in: &bag)
    }

    private func evaluateThreads(_ snapshot: T3CodeSnapshot) {
        let (alerts, next) = T3ThreadAlertRules.evaluate(threadState, snapshot, settings: settings, now: Date())
        threadState = next
        guard !alerts.isEmpty else { return }
        Task { await post(alerts) }
    }

    private func evaluate() {
        let now = Date()
        let known = monitor.management == .connected && monitor.accountsUpdatedAt != nil
        let accounts = monitor.accounts
        var credits: [String: [Date]] = [:]
        if known {
            for a in accounts where a.provider == .codex && !a.disabled {
                if let list = live.credits[a.id] { credits[accountHistoryKey(a)] = list.compactMap(\.expiresAt) }
            }
        }
        let labeled = accounts.compactMap { a -> AlertAccount? in
            guard var alert = AlertAccount(a, now: now) else { return nil }
            alert.label = a.quotaLabel(among: accounts)
            return alert
        }
        let snapshot = AlertSnapshot(reachability: monitor.reachability,
                                     accounts: known ? labeled : nil,
                                     credits: credits)
        let (alerts, next) = AlertRules.evaluate(state ?? AlertState(), snapshot, settings: settings, now: now)
        if next != state { state = next; save(next, Self.stateKey) }
        guard !alerts.isEmpty else { return }
        Task { await post(alerts) }
    }

    private func post(_ alerts: [Alert]) async {
        guard let center else { return }
        if await refreshAuthorization() == .notDetermined { _ = await requestPermission() }
        guard [.authorized, .provisional].contains(authorization) else { return }
        for a in alerts {
            let c = UNMutableNotificationContent()
            c.title = LogRedactor.redact(a.title, secrets: [])
            c.body = LogRedactor.redact(a.body, secrets: [])
            c.threadIdentifier = a.kind.rawValue
            if let id = a.threadID { c.userInfo = ["t3ThreadID": id] }
            // The identifier is the hashed de-dup key, so a re-post replaces rather than stacks.
            try? await center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
        }
    }

    @discardableResult
    public func requestPermission() async -> Bool {
        guard let center else { return false }
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        return ok
    }

    @discardableResult
    public func refreshAuthorization() async -> UNAuthorizationStatus {
        guard let center else { return authorization }
        authorization = await center.notificationSettings().authorizationStatus
        return authorization
    }

    public var notificationsAvailable: Bool { center != nil }

    public func sendTest() {
        Task { await post([Alert(kind: .lowQuota, id: "test", title: "T3 Proxy notifications are on",
                                 body: "You'll be told when quota runs low, a reset is about to expire, an account is held, or the proxy stops.")]) }
    }

    // Show banners even while the panel or Settings is in front.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Clicking a T3 Code notification opens its thread.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["t3ThreadID"] as? String else { return }
        await MainActor.run { T3CodeModel.open(threadID: id) }
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
    private static func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
}

/// Records quota samples (Application Support/T3 Proxy/quota-history.json) and publishes pool forecasts.
@MainActor
public final class QuotaForecaster: ObservableObject {
    public static let shared = QuotaForecaster()
    /// Forecast per "provider|kind"; absent when there isn't enough data.
    @Published public private(set) var forecasts: [String: PoolForecast] = [:]

    private let store = QuotaHistoryStore()
    private var history = QuotaHistory()
    private var loaded = false
    private var savedAt = Date.distantPast
    private var dirty = false
    private var bag: Set<AnyCancellable> = []
    private var monitor: Monitor?
    private var timer: Timer?

    public func forecast(_ p: Provider, _ k: QuotaWindowKind) -> PoolForecast? { forecasts[p.rawValue + "|" + k.rawValue] }

    func start(monitor: Monitor) {
        guard self.monitor == nil else { return }
        self.monitor = monitor
        let store = self.store
        Task { [weak self] in
            let h = await Task.detached { await store.load() }.value
            guard let self else { return }
            history = h; loaded = true
            update(monitor.accounts)
            Publishers.CombineLatest3(monitor.$accounts, monitor.$management, monitor.$reachability)
                .sink { [weak self] accounts, management, reachability in
                    self?.update(accounts, management: management, reachability: reachability)
                }.store(in: &bag)
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let monitor = self.monitor else { return }
                    self.update(monitor.accounts)
                }
            }
        }
    }

    private func update(_ accounts: [Account], management: ManagementState? = nil, reachability: Reachability? = nil) {
        guard loaded, let monitor, (management ?? monitor.management) == .connected,
              (reachability ?? monitor.reachability) == .live else { forecasts = [:]; return }
        let now = Date()
        if history.record(quotaSamples(from: accounts), now: now) > 0 { dirty = true }
        var next: [String: PoolForecast] = [:]
        for p in [Provider.claude, .codex] {
            for k in QuotaWindowKind.allCases {
                if let f = Forecast.pool(history.samples, accounts: accounts, provider: p, kind: k, now: now) {
                    next[p.rawValue + "|" + k.rawValue] = f
                }
            }
        }
        if next != forecasts { forecasts = next }
        // At most one write every 5 minutes; encoding and the atomic write run off the main thread.
        if dirty, now.timeIntervalSince(savedAt) >= 300 {
            dirty = false; savedAt = now
            let snapshot = history, store = self.store
            Task.detached(priority: .utility) { try? await store.save(snapshot) }
        }
    }
}

extension PoolForecast {
    /// "runs out Thu 3:10 PM" / "lasts until reset".
    public var phrase: String {
        switch self {
        case .runsOut(let d): "at this pace runs out \(d.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        case .lastsUntilReset: "lasts until reset"
        }
    }
}
