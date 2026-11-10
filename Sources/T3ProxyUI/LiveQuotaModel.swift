import Foundation
import Combine
import T3ProxyCore

/// Drives live quota reads (every 5 minutes, and on demand) and the Codex reset-credit flow.
/// Live reads go through the hub's api-call with the account's own token; the service throttles
/// each account to one read a minute and two hub calls at a time.
///
/// Everything here belongs to one management key: when the key is saved or removed, the service,
/// its caches, the credit lists and any unfinished reset are dropped, and late results are ignored.
@MainActor
public final class LiveQuotaModel: ObservableObject {
    private static var instances: [ObjectIdentifier: LiveQuotaModel] = [:]
    public static func shared(for monitor: Monitor) -> LiveQuotaModel {
        if let m = instances[ObjectIdentifier(monitor)] { return m }
        let m = LiveQuotaModel(monitor: monitor)
        instances[ObjectIdentifier(monitor)] = m
        return m
    }

    /// The app's instance, for views (the menu bar panel) that aren't handed the Monitor; nil before `shared(for:)`.
    public static var primary: LiveQuotaModel? { instances.values.first }

    public struct Outcome: Equatable {
        public var accountID: String; public var text: String; public var isError: Bool
        /// True only when this attempt reset the account's limits.
        public var succeeded = false
    }

    /// A reset whose result is unknown (network error or an unrecognised answer). Retrying sends the
    /// exact same credit and request id, so it can't spend a second credit.
    public struct PendingReset { public let credit: ResetCredit; fileprivate let confirmed: ConfirmedResetCredit }

    /// What the user confirmed: the exact credential and credit shown in the dialog.
    public struct ResetIntent: Equatable {
        public let accountID: String
        fileprivate let authIndex: String?
        fileprivate let chatgptAccountID: String?
        fileprivate let creditID: String
        fileprivate let keyEpoch: Int
    }

    /// The intent for the reset that "Use Reset" / "Retry Reset" would send now, or nil if there is none.
    /// See LiveQuotaService.verifiedPlan. Dropped with the service when the key changes.
    public func verifiedPlan(provider: Provider, authIndex: String, chatgptAccountID: String?) -> (plan: String, readAt: Date)? {
        service.verifiedPlan(provider: provider, authIndex: authIndex, chatgptAccountID: chatgptAccountID)
    }

    public func intent(for account: Account) -> ResetIntent? {
        guard let credit = pending[account.id]?.credit ?? credits[account.id]?.first else { return nil }
        return ResetIntent(accountID: account.id, authIndex: account.authIndex, chatgptAccountID: account.chatgptAccountID,
                           creditID: credit.id, keyEpoch: keyEpoch)
    }

    @Published public private(set) var refreshing = false
    @Published public private(set) var lastRefresh: Date?
    /// Available reset credits per Codex Account.id, soonest-expiring first.
    @Published public private(set) var credits: [String: [ResetCredit]] = [:]
    @Published public private(set) var pending: [String: PendingReset] = [:]
    @Published public private(set) var claiming: String?
    @Published public var outcome: Outcome?

    private let monitor: Monitor
    private var service: LiveQuotaService
    private var confirmations = ResetCreditConfirmationStore()
    /// The key epoch this state belongs to, and a counter bumped whenever state is dropped (guards late results).
    private var keyEpoch: Int
    private var epoch = 0
    /// Credit lists are read at most every 5 minutes per account, failures included.
    private var creditsReadAt: [String: Date] = [:]
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var started = false

    private init(monitor: Monitor) {
        self.monitor = monitor
        self.service = LiveQuotaService(monitor: monitor)
        self.keyEpoch = monitor.keyEpoch
    }

    public func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // First read once the account list arrives (and again after a key change).
        monitor.$management.removeDuplicates().sink { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.syncEpoch()
                guard state == .connected else { return }
                try? await Task.sleep(for: .seconds(1))
                await self.refresh()
            }
        }.store(in: &bag)
    }

    /// Drops all state from a previous key.
    private func syncEpoch() {
        let keyChanged = keyEpoch != monitor.keyEpoch
        let noAccess = monitor.management == .rejected || monitor.management == .noKey
        guard keyChanged || (noAccess && (!credits.isEmpty || !pending.isEmpty || outcome != nil || refreshing)) else { return }
        keyEpoch = monitor.keyEpoch
        epoch += 1
        service = LiveQuotaService(monitor: monitor)
        confirmations = ResetCreditConfirmationStore()
        credits = [:]; creditsReadAt = [:]; pending = [:]; outcome = nil
    }

    public func label(for account: Account) -> String { account.quotaLabel(among: monitor.accounts) }

    private func current(_ id: String) -> Account? { monitor.accounts.first { $0.id == id } }

    public func refresh() async {
        syncEpoch()
        guard !refreshing, monitor.management == .connected else { return }
        refreshing = true; defer { refreshing = false }
        let started = epoch, svc = service
        let readings = await svc.refresh(monitor.accounts)
        guard started == epoch else { return }
        monitor.applyLive(readings, epoch: keyEpoch)
        lastRefresh = Date()
        for a in monitor.accounts where a.provider == .codex && !a.disabled {
            guard started == epoch else { return }
            let count = readings[a.id]?.availableResetCredits
            if count == 0 { credits[a.id] = []; continue }
            if let at = creditsReadAt[a.id], Date().timeIntervalSince(at) < 300 { continue }
            creditsReadAt[a.id] = Date()
            if let list = try? await svc.resetCredits(a), started == epoch { credits[a.id] = list }
        }
    }

    /// Spends a reset on `account`: the unfinished one if there is one, otherwise the soonest-expiring credit.
    /// Call only after the user confirmed.
    @discardableResult
    public func useReset(_ intent: ResetIntent, requireExhausted: Bool = false,
                         precondition: @escaping @MainActor @Sendable () -> Bool = { true }) async -> ResetAttemptResult {
        syncEpoch()
        let accountID = intent.accountID
        guard claiming == nil else { return .notAttempted }
        // Re-check the account as it is now: still there, enabled, Codex, same credential.
        guard let account = current(accountID), account.provider == .codex, !account.disabled else {
            outcome = .init(accountID: accountID, text: "That account is disabled or gone, so no reset was used.", isError: true)
            return .notAttempted
        }
        // The credential, the key and the credit must be the ones the user confirmed.
        guard self.intent(for: account) == intent else {
            outcome = .init(accountID: accountID, text: "The account or its resets changed while the dialog was open, so nothing was used. Check and try again.", isError: true)
            return .notAttempted
        }
        let started = epoch, svc = service
        let name = label(for: account)
        let attempt: PendingReset
        if let p = pending[accountID] {
            attempt = p
        } else {
            guard let credit = credits[accountID]?.first,
                  let prepared = try? confirmations.prepare(credit: credit, account: account) else { return .notAttempted }
            attempt = PendingReset(credit: credit, confirmed: prepared.confirm())
        }
        claiming = accountID; defer { claiming = nil }
        outcome = nil
        let result: ResetCreditResult?
        var validatedForDispatch = false
        do {
            result = try await svc.consume(account: account, confirmed: attempt.confirmed) { [weak self] in
                guard let self, self.monitor.keyEpoch == intent.keyEpoch,
                      self.monitor.management == .connected,
                      let current = self.current(accountID), current.provider == .codex, !current.disabled,
                      self.intent(for: current) == intent else { return false }
                let credit = self.pending[accountID]?.credit ?? self.credits[accountID]?.first
                guard credit == attempt.credit else { return false }
                guard precondition() else { return false }
                if requireExhausted && !T3ResetAndResume.canConsume(quota: current.quota, at: Date(), threadIsValid: true) { return false }
                validatedForDispatch = true
                return true
            }
        } catch is CancellationError where !validatedForDispatch {
            syncEpoch()
            guard started == epoch else { return .notAttempted }
            outcome = .init(accountID: accountID, text: "The account or its resets changed while waiting, so nothing was used. Check and try again.", isError: true)
            return .notAttempted
        } catch { result = nil }
        syncEpoch()
        guard started == epoch else { return .failed }

        let attemptResult: ResetAttemptResult

        switch result {
        case .reset(let windows)?:
            attemptResult = .succeeded
            pending[accountID] = nil
            var text = windows > 0
                ? "Reset used on \(name): \(windows) limit\(windows == 1 ? "" : "s") started over."
                : "Reset used on \(name)."
            if svc.cooldownClearFailed.contains(accountID) { text += " The hub's cooldown for it couldn't be cleared; it clears on its own." }
            outcome = .init(accountID: accountID, text: text, isError: false, succeeded: true)
        case .alreadyRedeemed?:
            attemptResult = .notAttempted
            pending[accountID] = nil
            outcome = .init(accountID: accountID, text: "That reset had already been used on \(name). No other credit was spent.", isError: false)
        case .nothingToReset?:
            attemptResult = .notAttempted
            pending[accountID] = nil
            outcome = .init(accountID: accountID, text: "\(name) doesn't need a reset right now. No credit was used.", isError: true)
        case .noCredit?:
            attemptResult = .notAttempted
            pending[accountID] = nil
            outcome = .init(accountID: accountID, text: "That reset is no longer available. The list was refreshed.", isError: true)
        case .failed?, nil:
            attemptResult = .failed
            pending[accountID] = attempt
            outcome = .init(accountID: accountID, text: "The reset on \(name) wasn't confirmed. “Retry Reset” sends the same request again and can't spend a second credit.", isError: true)
        }
        // The definitive outcomes change the list; re-read it on the next refresh.
        if pending[accountID] == nil { creditsReadAt[accountID] = nil; credits[accountID] = nil }
        await refresh()
        return attemptResult
    }
}
