import Foundation
import Combine
import T3ProxyCore

/// One account change awaiting confirmation.
enum AccountChange: Identifiable, Equatable {
    case rename(Credential, String)
    case priority(Credential, Int)
    case setDisabled(Credential, Bool)
    case resetCooldown(Credential)
    case refresh(Credential)
    case delete(Credential)

    var id: String { title }
    var credential: Credential {
        switch self {
        case .rename(let c, _), .priority(let c, _), .setDisabled(let c, _), .resetCooldown(let c), .refresh(let c), .delete(let c): c
        }
    }
    var title: String {
        let n = "“\(credential.label.emailHidden)”"
        switch self {
        case .rename(_, let s): return s.isEmpty ? "Clear the nickname of \(n)?" : "Rename \(n) to “\(s.emailHidden)”?"
        case .priority(let c, let p): return "Change the priority of \(n) from \(c.priority) to \(p)?"
        case .setDisabled(_, let d): return d ? "Disable \(n)?" : "Enable \(n)?"
        case .resetCooldown: return "Reset the cooldown of \(n)?"
        case .refresh: return "Refresh the token of \(n)?"
        case .delete: return "Delete \(n) from the hub?"
        }
    }
    var message: String {
        switch self {
        case .rename: "Only the nickname (the file's note) changes on the hub."
        case .priority: "The hub routes to the highest ready priority first. 0 is the default."
        case .setDisabled(_, let d): d ? "The hub stops routing requests to this account until it is enabled again." : "The hub can route requests to this account again."
        case .resetCooldown: "The hub may send requests to this account right away, even if the provider is still limiting it."
        case .refresh: "The hub asks the provider for a new access token. This can take a while."
        case .delete: "The hub deletes this account's credential file and stops using it. This can't be undone: to use the account again, sign in with Add Account. Your subscription itself is not affected."
        }
    }
    var confirmLabel: String {
        switch self {
        case .rename(_, let s): s.isEmpty ? "Clear Nickname" : "Rename"
        case .priority: "Change Priority"
        case .setDisabled(_, let d): d ? "Disable" : "Enable"
        case .resetCooldown: "Reset Cooldown"
        case .refresh: "Refresh Token"
        case .delete: "Delete Account"
        }
    }
    var isDestructive: Bool {
        switch self {
        case .setDisabled(_, true), .delete: true
        default: false
        }
    }
}

/// Reads and writes `/v8` credentials through `Monitor.management`, so it shares the rejected-key lock.
@MainActor
final class AccountsModel: ObservableObject {
    @Published private(set) var credentials: [Credential] = []
    @Published private(set) var loading = false
    @Published private(set) var updatedAt: Date?
    @Published var error: String?
    @Published private(set) var busy: String?
    @Published var notice: String?

    let monitor: Monitor
    init(monitor: Monitor) { self.monitor = monitor }

    var locked: Bool { monitor.management == .rejected || !monitor.hasKey }

    private var loadGeneration = 0

    /// Reads may overlap (e.g. Reload, then a write's follow-up read); only the newest one publishes.
    func load() async {
        guard !locked else { credentials = []; return }
        loadGeneration += 1
        let g = loadGeneration
        loading = true
        defer { if g == loadGeneration { loading = false } }
        do {
            let fresh = try await monitor.management { try await $0.credentials(key: $1) }
            guard g == loadGeneration else { return }
            let plans = await Task.detached(priority: .utility) { PlanCache.load() }.value
            guard g == loadGeneration else { return }
            credentials = fresh.map { c in
                var result = c.with(c.accountKey.flatMap { plans[$0] })
                let q = accountQuota(monitor, c)
                result.plan = q?.planInfo?.plan ?? q?.plan ?? c.plan ?? result.plan
                return result
            }
            updatedAt = Date(); error = nil
        } catch {
            guard g == loadGeneration else { return }
            if case ProxyError.unauthorized = error { credentials = [] }
            self.error = Self.describe(error)
        }
    }

    func apply(_ change: AccountChange) async {
        guard busy == nil else { return }
        let name = change.credential.name
        busy = name; error = nil; notice = nil
        do {
            switch change {
            case .rename(_, let s): try await monitor.management { try await $0.setNickname(s, name: name, key: $1) }
            case .priority(_, let p): try await monitor.management { try await $0.setPriority(p, name: name, key: $1) }
            case .setDisabled(let c, let d):
                RoutingGuard.shared(for: monitor).userOverride(c)
                try await monitor.management { try await $0.setDisabled(d, name: name, key: $1) }
            case .resetCooldown: try await monitor.management { try await $0.resetCooldown(name: name, key: $1) }
            case .refresh: try await monitor.management { try await $0.refresh(name: name, key: $1) }
            case .delete(let c):
                try await monitor.management { try await $0.deleteCredential(c, key: $1) }
                // Only now is it gone: the Team guard forgets its pause (a failed delete keeps it, so a paused
                // account still resumes), and the panel drops the account and its live reading at once.
                RoutingGuard.shared(for: monitor).userOverride(c)
                await monitor.forget(accountID: c.name)
            }
            notice = "\(change.confirmLabel): done for “\(change.credential.label.emailHidden)”."
        } catch {
            self.error = "\(change.confirmLabel) failed for “\(change.credential.label.emailHidden)”: \(Self.describe(error))"
        }
        busy = nil
        let failure = self.error
        let before = updatedAt
        await load()
        let reloaded = updatedAt != nil && updatedAt != before
        if let failure { self.error = failure }
        // A DELETE whose answer was lost may still have worked: if a fresh list no longer has it, finish the cleanup.
        if case .delete(let c) = change, failure != nil, reloaded, !credentials.contains(where: { $0.name == c.name }) {
            RoutingGuard.shared(for: monitor).userOverride(c)
            await monitor.forget(accountID: c.name)
        }
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case ManagementError.locked: "No accepted management key. Set one in Connection."
        case ManagementError.invalidName: "The account's file name is not one T3 Proxy will send."
        case ManagementError.invalidPriority: "Priority must be a whole number from -100 to 100."
        case ManagementError.nicknameTooLong: "Keep the nickname to 60 characters or fewer."
        case ManagementError.notFound: "That account is no longer on the hub."
        case ManagementError.refreshFailed: "The hub could not refresh the token."
        case ManagementError.runtimeOnly: "This account only exists in the hub's memory (no file), so it can't be deleted here."
        case RoutingError.staleCredential: "The account changed since you confirmed. Check the list and try again."
        case ProxyError.unauthorized: "The management key was rejected. Requests are paused until it is replaced."
        case ProxyError.unreachable: "Could not reach the proxy."
        case ProxyError.incompatible: "The proxy answered in an unexpected shape."
        case ProxyError.http(let c): "The proxy answered HTTP \(c)."
        default: "Request failed."
        }
    }
}
