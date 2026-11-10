import Foundation
import CryptoKit

public enum PlanGroup: String, Sendable, CaseIterable {
    case subscription, team
    public static func classify(_ plan: String?) -> PlanGroup? {
        guard let p = plan?.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ") else { return nil }
        if ["team", "team premium", "business", "enterprise"].contains(p) { return .team }
        if ["pro", "plus", "max"].contains(p) || p.range(of: #"^max [1-9][0-9]{0,2}x$"#, options: .regularExpression) != nil { return .subscription }
        return nil
    }
}

public struct PriorityChange: Sendable, Identifiable, Equatable {
    public var id: String { credential.name }
    public let credential: Credential
    public let priority: Int
}
public struct PriorityRule: Sendable, Equatable {
    public var subscription: Int
    public var team: Int
    public init(subscription: Int = 10, team: Int = 0) { self.subscription = subscription; self.team = team }
    public func changes(_ credentials: [Credential]) -> [PriorityChange] {
        credentials.compactMap { c in
            guard !c.runtimeOnly, c.provider != .other, let group = PlanGroup.classify(c.plan) else { return nil }
            let p = group == .subscription ? subscription : team
            guard ManagementRules.priorityRange.contains(p), c.priority != p else { return nil }
            return PriorityChange(credential: c, priority: p)
        }
    }
}

/// A credential joined to the Monitor's best current quota reading.
public struct RoutingAccount: Sendable {
    public var credential: Credential
    public var quota: QuotaReading
    public var planUnclear: Bool
    public init(credential: Credential, quota: QuotaReading, planUnclear: Bool = false) {
        self.credential = credential; self.quota = quota; self.planUnclear = planUnclear
    }
}
/// Cache files without observation times are deliberately ineligible for guard decisions.
public enum GuardPlan {
    /// `profile` is the plan from this credential's own profile read (LiveQuotaService.verifiedPlan), already
    /// bound to its auth index. The hub never reports Claude plans, so without it Claude Team accounts are never guarded.
    public static func resolve(_ c: Credential, quota: QuotaReading, identityMatches: Bool, now: Date,
                               profile: (plan: String, readAt: Date)? = nil) -> (plan: String?, unclear: Bool) {
        let fresh = quota.observedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 300 } == true
        let profileFresh = profile.map { now.timeIntervalSince($0.readAt) >= 0 && now.timeIntervalSince($0.readAt) <= 24 * 3600 } == true
        let fallbacks = (identityMatches && fresh ? [quota.planInfo?.plan, quota.plan].compactMap { $0 } : [])
            + (profileFresh ? [profile!.plan] : [])
        let plans = [c.plan].compactMap { $0 } + fallbacks
        let team = plans.contains { PlanGroup.classify($0) == .team }
        let nonTeam = plans.contains { PlanGroup.classify($0) != .team }
        return (c.plan ?? fallbacks.first, team && nonTeam)
    }
}
public enum GuardResumeStatus: String, Codable, Sendable { case pending, retry, manual, authBlocked }
public enum GuardResumeFailure: Sendable { case definitive, ambiguous, unauthorized }
public enum GuardTransportError: Error { case offline }
public enum GuardResumeResult {
    public static func failure(_ error: Error) -> GuardResumeFailure {
        switch error {
        case ProxyError.unauthorized, ManagementError.locked: .unauthorized
        case GuardTransportError.offline: .definitive
        case ProxyError.http(let code) where (500...599).contains(code): .definitive
        default: .ambiguous
        }
    }
}
public struct GuardWriteLimiter: Sendable {
    private var lastWrite: TimeInterval?
    public init() {}
    public mutating func reserve(at uptime: TimeInterval) -> Bool {
        guard lastWrite.map({ uptime - $0 >= 5 }) ?? true else { return false }
        lastWrite = uptime; return true
    }
    public mutating func completed(at uptime: TimeInterval) { lastWrite = uptime }
}
public struct GuardPause: Codable, Sendable, Equatable {
    public var resetAt: Date
    public var previousMarker: String?
    public var ownedMarker: String?
    public var identity: String
    public var resumeStatus: GuardResumeStatus?
    public var retryAfter: Date?
}
public enum TeamGuardAction: Sendable, Equatable { case none, pause(Date), resume }

/// New pauses reserve a quota window before writing. Resumes retain ownership until a read confirms
/// enabled status, backing off definitive failures and withholding ambiguous/auth-rejected retries.
/// Only a verified pause of a credential that is still disabled, with unchanged identity, can be resumed.
///
/// The hub's `updated_at` is not a sign of user intent: the hub bumps it on its own (token refreshes, status
/// bookkeeping) while the account sits disabled, so a changed marker is adopted, not treated as an override.
/// Ownership ends when the account is seen enabled, its identity changes, or the user changes it in T3 Proxy.
public struct TeamGuardState: Codable, Sendable, Equatable {
    public private(set) var pauses: [String: GuardPause] = [:]
    private var attemptedUntil: [String: Date] = [:]
    public private(set) var recoveryNotices: [String: String]? = nil
    public init() {}
    public static func accountID(_ c: Credential) -> String { digest("\(c.providerName):\(c.name)") }
    private static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func identity(_ c: Credential) -> String {
        let base = "\(c.providerName):\(c.name):\(c.authIndex ?? "")"
        return digest(base + (c.chatgptAccountID.map { ":\($0)" } ?? ""))
    }
    public func pause(for c: Credential) -> GuardPause? { pauses[Self.accountID(c)] }

    public mutating func userOverride(_ c: Credential) { pauses.removeValue(forKey: Self.accountID(c)) }
    public mutating func confirmPause(_ c: Credential) {
        let id = Self.accountID(c)
        // Enabled before the write, disabled right after it: the pause is ours. The hub may or may not bump the marker.
        guard var p = pauses[id], c.disabled, Self.identity(c) == p.identity,
              let marker = c.updatedMarker ?? p.previousMarker else { return }
        p.ownedMarker = marker; pauses[id] = p
    }
    public mutating func resumeFailed(_ c: Credential, failure: GuardResumeFailure, now: Date) {
        let id = Self.accountID(c)
        guard var p = pauses[id] else { return }
        switch failure {
        case .definitive: p.resumeStatus = .retry; p.retryAfter = now.addingTimeInterval(60)
        case .ambiguous: p.resumeStatus = .manual; p.retryAfter = nil
        case .unauthorized: p.resumeStatus = .authBlocked; p.retryAfter = nil
        }
        pauses[id] = p
    }
    public mutating func requestManualResume(_ c: Credential, now: Date) -> Bool {
        let id = Self.accountID(c)
        guard var p = pauses[id], c.disabled, Self.identity(c) == p.identity,
              p.ownedMarker != nil,
              p.resumeStatus == .manual || p.resumeStatus == .pending else { return false }
        p.resumeStatus = .retry; p.retryAfter = now; pauses[id] = p
        return true
    }

    public mutating func evaluate(_ account: RoutingAccount, enabledCount: Int, threshold: Int = 100,
                                  enabled: Bool = true, now: Date) -> TeamGuardAction {
        let c = account.credential, id = Self.accountID(c)
        let limit = [95, 98, 100].contains(threshold) ? threshold : 100
        let reset = QuotaWindowKind.allCases.compactMap { kind -> Date? in
            guard let remaining = account.quota.remaining(kind, at: now), 100 - remaining >= Double(limit),
                  let reset = account.quota.window(kind)?.resetAt, reset > now else { return nil }
            return reset
        }.max()
        if var p = pauses[id] {
            guard Self.identity(c) == p.identity else {
                if recoveryNotices == nil { recoveryNotices = [:] }
                recoveryNotices?[id] = "The credential identity changed. Automatic recovery was cancelled; review Accounts."
                pauses.removeValue(forKey: id); return .none
            }
            if !c.disabled { pauses.removeValue(forKey: id); return .none }
            guard p.ownedMarker != nil else {
                if recoveryNotices == nil { recoveryNotices = [:] }
                recoveryNotices?[id] = "The pause could not be verified, so it will not be re-enabled automatically. Review Accounts."
                pauses.removeValue(forKey: id); return .none
            }
            if let marker = c.updatedMarker, marker != p.ownedMarker { p.ownedMarker = marker; pauses[id] = p }
            // A newer exhausted window must reset too, before the credential becomes safe to use.
            if enabled, let reset, reset > p.resetAt {
                p.resetAt = reset; pauses[id] = p; attemptedUntil[id] = reset
            }
            guard now >= p.resetAt else { return .none }
            if let status = p.resumeStatus {
                guard status == .retry, let retry = p.retryAfter, now >= retry else { return .none }
            }
            // Write ahead: a crash or uncertain result requires reconciliation/manual recovery.
            p.resumeStatus = .pending; p.retryAfter = nil; pauses[id] = p
            return .resume
        }
        // Seen enabled again: an old recovery notice no longer applies.
        if !c.disabled, recoveryNotices?[id] != nil {
            recoveryNotices?.removeValue(forKey: id)
            if recoveryNotices?.isEmpty == true { recoveryNotices = nil }
        }
        guard c.provider != .other, PlanGroup.classify(c.plan) == .team, !account.planUnclear,
              enabled, !c.disabled, !c.runtimeOnly, c.updatedMarker != nil, enabledCount > 1, let reset,
              attemptedUntil[id].map({ $0 > now || $0 >= reset }) != true else { return .none }
        attemptedUntil[id] = reset
        pauses[id] = GuardPause(resetAt: reset, previousMarker: c.updatedMarker, identity: Self.identity(c))
        return .pause(reset)
    }
}

public enum RoutingError: Error, Equatable {
    case invalidProvider, invalidModels, invalidKey, staleReference, tooManyKeys, randomFailed, staleCredential
}
public enum RoutingConfigField: String, Sendable, CaseIterable { case aliases = "model-alias", excluded = "excluded-models" }
public struct ModelAlias: Codable, Sendable, Equatable {
    public var name: String
    public var alias: String
    public var fork: Bool?
    public init(name: String, alias: String, fork: Bool = false) { self.name = name; self.alias = alias; self.fork = fork ? true : nil }
}
public enum RoutingValidation {
    public static func provider(_ s: String) throws {
        guard !["management", "remote-management", "secret-key", "auth-dir"].contains(s),
              s.range(of: #"\A[a-z0-9-]{1,40}\z"#, options: .regularExpression) != nil else { throw RoutingError.invalidProvider }
    }
    private static func model(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "•…".unicodeScalars.contains($0) }
    }
    public static func aliases(_ list: [ModelAlias]) throws -> [ModelAlias] {
        guard list.count <= 500, list.allSatisfy({ model($0.name) && model($0.alias) }) else { throw RoutingError.invalidModels }
        return list.map { ModelAlias(name: $0.name, alias: $0.alias, fork: $0.fork == true) }
    }
    public static func modelNames(_ list: [String]) throws -> [String] {
        guard list.count <= 500, list.allSatisfy(model) else { throw RoutingError.invalidModels }
        var seen: Set<String> = []
        return list.filter { seen.insert($0).inserted }
    }
    public static func clientKey(_ s: String) throws {
        guard (8...512).contains(s.utf8.count), s.range(of: #"\A[A-Za-z0-9._~+/=:@-]+\z"#, options: .regularExpression) != nil else { throw RoutingError.invalidKey }
    }
}
