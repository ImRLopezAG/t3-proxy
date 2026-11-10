import Foundation
import Combine
import UserNotifications
import T3ProxyCore

/// One runner per Monitor. All hub I/O shares Monitor's AuthGate. No provider requests.
@MainActor
public final class RoutingGuard: ObservableObject {
    private static var instances: [ObjectIdentifier: RoutingGuard] = [:]
    public static func shared(for monitor: Monitor) -> RoutingGuard {
        let id = ObjectIdentifier(monitor)
        if let value = instances[id] { return value }
        let value = RoutingGuard(monitor: monitor)
        instances[id] = value
        return value
    }

    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "routing.guard.enabled") } }
    @Published public var threshold: Int { didSet { defaults.set(threshold, forKey: "routing.guard.threshold") } }
    @Published var subscriptionPriority: Int { didSet { defaults.set(subscriptionPriority, forKey: "routing.priority.subscription") } }
    @Published var teamPriority: Int { didSet { defaults.set(teamPriority, forKey: "routing.priority.team") } }
    /// Detect and offer new-account changes, but every batch still needs a confirmation.
    @Published var offerNewAccountPriorities: Bool { didSet { defaults.set(offerNewAccountPriorities, forKey: "routing.priority.offerNew") } }
    @Published private(set) var credentials: [Credential] = []
    @Published private(set) var state: TeamGuardState
    @Published private(set) var newAccountChanges: [PriorityChange] = []
    @Published private(set) var busy = false
    @Published var error: String?
    private let monitor: Monitor
    private let defaults: UserDefaults
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var started = false
    private var writeLimiter = GuardWriteLimiter()
    private var guardReadings: [Account] = []
    @Published private(set) var unclearPlans: Set<String> = []
    private var known: Set<String>
    private var newAccounts: Set<String> = []
    private var baselineEstablished: Bool
    private var overridden: Set<String> = []

    private init(monitor: Monitor, defaults: UserDefaults = .standard) {
        self.monitor = monitor; self.defaults = defaults
        enabled = defaults.object(forKey: "routing.guard.enabled") as? Bool ?? true
        let t = defaults.integer(forKey: "routing.guard.threshold")
        threshold = [95, 98, 100].contains(t) ? t : 100
        subscriptionPriority = defaults.object(forKey: "routing.priority.subscription") as? Int ?? 10
        teamPriority = defaults.object(forKey: "routing.priority.team") as? Int ?? 0
        offerNewAccountPriorities = defaults.bool(forKey: "routing.priority.offerNew")
        state = defaults.data(forKey: "routing.guard.state").flatMap { try? JSONDecoder().decode(TeamGuardState.self, from: $0) } ?? TeamGuardState()
        known = Set(defaults.stringArray(forKey: "routing.priority.known") ?? [])
        baselineEstablished = defaults.object(forKey: "routing.priority.known") != nil
    }

    public func start() {
        guard !started else { return }
        started = true
        monitor.$accountsUpdatedAt.sink { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }.store(in: &bag)
        // Live reads can change the best reading between Monitor's regular polls.
        monitor.$accounts.dropFirst().sink { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func pause(for c: Credential) -> GuardPause? { state.pause(for: c) }
    /// Called before a confirmed account status write, so even an uncertain write relinquishes ownership.
    func userOverride(_ c: Credential) {
        overridden.insert(TeamGuardState.accountID(c))
        state.userOverride(c); persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "routing.guard.state") }
    }

    private func snapshot(_ c: Credential) -> RoutingAccount {
        // Monitor merges live readings by file name and profile plans have no observation time.
        // Use an unmerged hub read so neither an old identity nor an old profile can supply a plan.
        let a = guardReadings.first {
            ($0.name + ".json" == c.name || $0.name == c.name) && $0.provider == c.provider &&
            c.authIndex?.isEmpty == false && $0.authIndex == c.authIndex && $0.chatgptAccountID == c.chatgptAccountID
        }
        let q = a?.quota ?? .none
        let profile = c.authIndex.flatMap { index in
            LiveQuotaModel.shared(for: monitor).verifiedPlan(provider: c.provider, authIndex: index, chatgptAccountID: c.chatgptAccountID)
        }
        let plan = GuardPlan.resolve(c, quota: q, identityMatches: a != nil, now: Date(), profile: profile)
        var credential = c; credential.plan = plan.plan
        return .init(credential: credential, quota: q, planUnclear: plan.unclear)
    }

    func manualResume(_ c: Credential) async {
        guard !busy, state.requestManualResume(c, now: Date()) else { return }
        persist()
        await refresh()
    }

    func refresh() async {
        guard !busy, monitor.management == .connected, monitor.hasKey else { return }
        busy = true; overridden.removeAll(); defer { busy = false }
        let epoch = monitor.keyEpoch
        do {
            let raw = try await monitor.management { try await $0.credentials(key: $1) }
            let readings = try await monitor.management { _, key in try await monitor.client.accounts(key: key) }
            // Cache labels remain useful for the separately confirmed priority controls.
            // They never enter the automatic guard's raw credential snapshots.
            let plans = await Task.detached(priority: .utility) { PlanCache.load() }.value
            guard epoch == monitor.keyEpoch, monitor.management == .connected else { return }
            guardReadings = readings
            credentials = raw.map { $0.with($0.accountKey.flatMap { plans[$0] }) }
            unclearPlans = Set(raw.filter { snapshot($0).planUnclear }.map(TeamGuardState.accountID))
            detectNewAccounts()
            for c in raw {
                var preview = state
                let action = preview.evaluate(snapshot(c), enabledCount: credentials.filter { $0.provider == c.provider && !$0.disabled }.count,
                                              threshold: threshold, enabled: enabled, now: Date())
                if action == .none { state = preview; continue }
                // Re-check identity, status and the provider's enabled count immediately before each write.
                let latest = try await monitor.management { try await $0.credentials(key: $1) }
                guard epoch == monitor.keyEpoch, monitor.management == .connected else { return }
                guard let current = latest.first(where: { $0.name == c.name && $0.provider == c.provider }) else {
                    state.userOverride(c); continue
                }
                guard !overridden.contains(TeamGuardState.accountID(current)) else { continue }
                var candidate = state
                let next = candidate.evaluate(snapshot(current), enabledCount: latest.filter { $0.provider == current.provider && !$0.disabled }.count,
                                          threshold: threshold, enabled: enabled, now: Date())
                guard next != .none else { state = candidate; continue }
                guard writeLimiter.reserve(at: ProcessInfo.processInfo.systemUptime) else { continue }
                defer { writeLimiter.completed(at: ProcessInfo.processInfo.systemUptime) }
                state = candidate
                persist() // write-ahead reservation, including pending resumes
                switch next {
                case .none: continue
                case .pause(let reset):
                    try await monitor.management { try await $0.setDisabled(true, name: current.name, key: $1) }
                    let after = try await monitor.management { try await $0.credentials(key: $1) }
                    guard epoch == monitor.keyEpoch else { return }
                    if let paused = after.first(where: { $0.name == current.name && $0.provider == current.provider }),
                       !overridden.contains(TeamGuardState.accountID(current)) {
                        state.confirmPause(paused)
                    }
                    persist()
                    if state.pause(for: current)?.ownedMarker != nil {
                        await notify("Team account paused", "\(current.label.emailHidden) is paused until \(reset.formatted(date: .abbreviated, time: .shortened)).")
                    } else { error = "A Team pause could not be verified. Check Accounts; automatic resume has been withheld." }
                case .resume:
                    do {
                        try await monitor.management { try await $0.resumeGuardCredential(name: current.name, key: $1) }
                    } catch {
                        state.resumeFailed(current, failure: GuardResumeResult.failure(error), now: Date())
                        persist()
                        throw error
                    }
                }
                guard epoch == monitor.keyEpoch else { return }
                let after = try await monitor.management { try await $0.credentials(key: $1) }
                credentials = after.map { $0.with($0.accountKey.flatMap { plans[$0] }) }
                for fresh in after {
                    // Only reconcile existing pending attempts; never reserve another write here.
                    if state.pause(for: fresh)?.resumeStatus == .pending {
                        _ = state.evaluate(snapshot(fresh), enabledCount: 0, enabled: false, now: Date())
                        if !fresh.disabled, state.pause(for: fresh) == nil {
                            await notify("Team account resumed", "\(fresh.label.emailHidden) is available after its subscription window reset.")
                        }
                    }
                }
            }
            persist()
        } catch {
            persist(); self.error = AccountsModel.describe(error)
        }
    }

    private func detectNewAccounts() {
        let ids = Set(credentials.map(TeamGuardState.accountID))
        if baselineEstablished { newAccounts.formUnion(ids.subtracting(known)) }
        else { baselineEstablished = true }
        known.formUnion(ids)
        defaults.set(Array(known), forKey: "routing.priority.known")
        newAccountChanges = offerNewAccountPriorities
            ? PriorityRule(subscription: subscriptionPriority, team: teamPriority).changes(credentials.filter { newAccounts.contains(TeamGuardState.accountID($0)) }) : []
    }
    func applyPriorities(_ changes: [PriorityChange]) async {
        guard !busy else { return }
        busy = true; error = nil
        do {
            for change in changes {
                while !writeLimiter.reserve(at: ProcessInfo.processInfo.systemUptime) {
                    try await Task.sleep(for: .seconds(5))
                }
                defer { writeLimiter.completed(at: ProcessInfo.processInfo.systemUptime) }
                try await monitor.management { try await $0.applyPriority(change, key: $1) }
                newAccounts.remove(TeamGuardState.accountID(change.credential))
            }
        } catch { self.error = routingErrorDescription(error) }
        busy = false
        await refresh()
    }
    private func notify(_ title: String, _ body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body.emailHidden
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor func routingErrorDescription(_ error: Error) -> String {
    switch error {
    case RoutingError.invalidProvider: "Use a provider id containing lowercase letters, digits or hyphens (up to 40)."
    case RoutingError.invalidModels: "Use up to 500 models or aliases, each 1–200 characters without spaces or masked values."
    case RoutingError.invalidKey: "The key is invalid or already exists. Generate another key."
    case RoutingError.staleReference: "That client key changed. Reload before removing it."
    case RoutingError.tooManyKeys: "The client key list is limited to 200 keys."
    case RoutingError.randomFailed: "A secure random key could not be generated."
    case RoutingError.staleCredential: "The account changed since confirmation. Reload and review its priority."
    default: describeHubError(error)
    }
}
