import Foundation

public enum T3CodeError: String, Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint, invalidToken, notConnected, disconnected, timedOut
    case authenticationFailed, permissionDenied, unsupportedServerVersion, invalidResponse
    case commandRejected, notUsageLimited, cliFailed, threadChanged

    public var errorDescription: String? {
        switch self {
        case .unsupportedServerVersion: "Unsupported server version"
        case .invalidEndpoint: "T3 Code must use 127.0.0.1"
        case .invalidToken: "A T3 Code session token is required"
        case .authenticationFailed: "T3 Code session expired or was rejected"
        case .permissionDenied: "T3 Code session lacks the required scope"
        case .notConnected, .disconnected: "T3 Code is disconnected"
        case .timedOut: "T3 Code request timed out; its outcome may be unknown"
        case .invalidResponse: "Unexpected T3 Code response"
        case .commandRejected: "T3 Code rejected the request"
        case .notUsageLimited: "This thread cannot be resumed from a usage limit"
        case .cliFailed: "T3 Code CLI session operation failed"
        case .threadChanged: T3CodeActionIntent.changedMessage
        }
    }
}

public enum T3CodeThreadStatus: String, Decodable, Sendable {
    case idle, preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled
    case rolledBack = "rolled_back"
    case unknown

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum T3CodeAttention: String, Sendable { case needsYou, running, waiting, finished, idle, unknown }

public struct T3CodePendingRequest: Decodable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let blocking: Bool?
    public let createdAt: Date?
    public var blocksRun: Bool { blocking != false }
}

public struct T3CodeModelSelection: Decodable, Sendable, Equatable {
    public let instanceId: String?
    public let provider: String?
    public let model: String
}

public struct T3CodeLineage: Decodable, Sendable, Equatable {
    public let parentThreadId: String?
    public let rootThreadId: String?
    public let relationshipToParent: String?
    public let sideChat: Bool?
}

public struct T3CodeLimitRecovery: Decodable, Sendable, Equatable {
    public let runId: String
    public let resetAt: Date
    public let requestId: String?
    public let autoResume: Bool
    public let snooze: Bool?
}

/// Task rosters currently use taskId/description; accept id/label from other shell versions.
public struct T3CodeBackgroundTask: Decodable, Sendable, Equatable {
    public let id: String?
    public let taskId: String?
    public let kind: String?
    public let label: String?
    public let description: String?
    public let childThreadId: String?
    public let status: String?
    public var displayLabel: String { label ?? description ?? kind ?? "Background task" }
}

public struct T3CodeThreadRuntime: Decodable, Sendable, Equatable {
    public let status: T3CodeThreadStatus?
}

/// A pull request linked to a thread: its number, and its state when T3 Code has synced it.
public struct T3CodePullRequest: Sendable, Equatable {
    public enum State: String, Sendable { case open, closed, merged, draft }
    public let number: Int
    public let state: State?
}

public struct T3CodeThread: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let projectId: String
    public let status: T3CodeThreadStatus
    public let providerInstanceId: String?
    public let modelSelection: T3CodeModelSelection?
    public let lineage: T3CodeLineage?
    public let latestRunId: String?
    public let activeRunId: String?
    public let activityRunStatus: T3CodeThreadStatus?
    public let pendingRuntimeRequest: T3CodePendingRequest?
    public let pendingGuestMessageCount: Int?
    public let hasActionableProposedPlan: Bool?
    public let lastErrorClass: String?
    public let usageLimitResetAt: Date?
    public let snoozedUntil: Date?
    public let snoozedAt: Date?
    public let limitRecovery: T3CodeLimitRecovery?
    public let settledOverride: String?
    public let settledAt: Date?
    public let archivedAt: Date?
    public let deletedAt: Date?
    public let updatedAt: Date?
    public let pendingBackgroundTasks: [T3CodeBackgroundTask]?
    public let blockedOnThreadWait: Bool?
    public let runtime: T3CodeThreadRuntime?
    public let creationSource: String?
    public let latestRunRequestedAt: Date?
    public let latestRunStartedAt: Date?
    public let latestRunCompletedAt: Date?
    public let activityRunStartedAt: Date?
    /// Explicit null suppresses the sidebar's legacy active-run fallback.
    public let hasActivityRunStartedAt: Bool
    /// Git branch and worktree the thread works in (nil when it works in the project checkout).
    public let branch: String?
    public let worktreePath: String?
    /// The thread's pull request (linked, or found for its branch), if any.
    public let pullRequest: T3CodePullRequest?
    /// Provider instances the thread ran on before, oldest first ("Handed off from …").
    public let providerInstanceHistory: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, projectId, status, providerInstanceId, modelSelection, lineage
        case latestRunId, activeRunId, activityRunStatus, pendingRuntimeRequest, pendingGuestMessageCount
        case hasActionableProposedPlan, lastErrorClass, usageLimitResetAt, snoozedUntil, snoozedAt
        case limitRecovery, settledOverride, settledAt, archivedAt, deletedAt, updatedAt
        case pendingBackgroundTasks, blockedOnThreadWait, runtime, creationSource
        case latestRunRequestedAt, latestRunStartedAt, latestRunCompletedAt, activityRunStartedAt
        case branch, worktreePath, linkedPullRequest, branchPullRequest, pullRequests, providerInstanceHistory
    }
    private struct PRKey: Decodable { let number: Int? }
    private struct PRLink: Decodable {
        let number: Int?
        let snapshot: Snap?
        struct Snap: Decodable { let state: String?; let isDraft: Bool? }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        projectId = try c.decode(String.self, forKey: .projectId)
        status = try c.decode(T3CodeThreadStatus.self, forKey: .status)
        providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
        modelSelection = try c.decodeIfPresent(T3CodeModelSelection.self, forKey: .modelSelection)
        lineage = try c.decodeIfPresent(T3CodeLineage.self, forKey: .lineage)
        latestRunId = try c.decodeIfPresent(String.self, forKey: .latestRunId)
        activeRunId = try c.decodeIfPresent(String.self, forKey: .activeRunId)
        activityRunStatus = try c.decodeIfPresent(T3CodeThreadStatus.self, forKey: .activityRunStatus)
        pendingRuntimeRequest = try c.decodeIfPresent(T3CodePendingRequest.self, forKey: .pendingRuntimeRequest)
        pendingGuestMessageCount = try c.decodeIfPresent(Int.self, forKey: .pendingGuestMessageCount)
        hasActionableProposedPlan = try c.decodeIfPresent(Bool.self, forKey: .hasActionableProposedPlan)
        lastErrorClass = try c.decodeIfPresent(String.self, forKey: .lastErrorClass)
        usageLimitResetAt = try c.decodeIfPresent(Date.self, forKey: .usageLimitResetAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        snoozedAt = try c.decodeIfPresent(Date.self, forKey: .snoozedAt)
        limitRecovery = try c.decodeIfPresent(T3CodeLimitRecovery.self, forKey: .limitRecovery)
        settledOverride = try c.decodeIfPresent(String.self, forKey: .settledOverride)
        settledAt = try c.decodeIfPresent(Date.self, forKey: .settledAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        pendingBackgroundTasks = try c.decodeIfPresent([T3CodeBackgroundTask].self, forKey: .pendingBackgroundTasks)
        blockedOnThreadWait = try c.decodeIfPresent(Bool.self, forKey: .blockedOnThreadWait)
        runtime = try c.decodeIfPresent(T3CodeThreadRuntime.self, forKey: .runtime)
        creationSource = try? c.decodeIfPresent(String.self, forKey: .creationSource)
        latestRunRequestedAt = try? c.decodeIfPresent(Date.self, forKey: .latestRunRequestedAt)
        latestRunStartedAt = try? c.decodeIfPresent(Date.self, forKey: .latestRunStartedAt)
        latestRunCompletedAt = try? c.decodeIfPresent(Date.self, forKey: .latestRunCompletedAt)
        activityRunStartedAt = try? c.decodeIfPresent(Date.self, forKey: .activityRunStartedAt)
        hasActivityRunStartedAt = c.contains(.activityRunStartedAt)
        // Display-only fields: every one is optional, and a malformed value is ignored, never fatal.
        branch = (try? c.decodeIfPresent(String.self, forKey: .branch)) ?? nil
        worktreePath = (try? c.decodeIfPresent(String.self, forKey: .worktreePath)) ?? nil
        let linked = (try? c.decodeIfPresent(PRKey.self, forKey: .linkedPullRequest))??.number
            ?? (try? c.decodeIfPresent(PRKey.self, forKey: .branchPullRequest))??.number
        let links = (try? c.decodeIfPresent([PRLink].self, forKey: .pullRequests)) ?? nil
        let number = linked ?? links?.last?.number
        pullRequest = number.flatMap { n in
            guard n > 0 else { return nil }
            let snap = links?.last { $0.number == n }?.snapshot
            let state = snap?.isDraft == true && snap?.state?.lowercased() == "open" ? .draft : snap?.state.flatMap { T3CodePullRequest.State(rawValue: $0.lowercased()) }
            return T3CodePullRequest(number: n, state: state)
        }
        providerInstanceHistory = ((try? c.decodeIfPresent([String].self, forKey: .providerInstanceHistory)) ?? nil) ?? []
    }

    /// Instances the thread was handed off from (its history without the current one), most recent first.
    public var handedOffFrom: [String] {
        let current = providerInstanceId ?? modelSelection?.instanceId
        var seen = Set<String>()
        return providerInstanceHistory.reversed().filter { $0 != current && seen.insert($0).inserted }
    }

    public var isListed: Bool { lineage?.relationshipToParent != "subagent" && lineage?.sideChat != true }
    public var isSettled: Bool { settledOverride == "settled" }
    public var isUsageLimited: Bool { status == .failed && lastErrorClass == "usage_limit" }
    public func isSnoozed(at date: Date = .now) -> Bool { snoozedUntil.map { $0 > date } ?? false }
    /// Proves the snooze came from the recovery setting, rather than a manual snooze.
    public func isSnoozedByUsageLimit(at date: Date = .now) -> Bool {
        isUsageLimited && isSnoozed(at: date) && limitRecovery?.snooze == true
            && limitRecovery?.runId == latestRunId && limitRecovery?.resetAt == usageLimitResetAt
            && snoozedUntil == usageLimitResetAt
    }
    /// Attention is independent of whether a question blocks the running agent.
    public var attention: T3CodeAttention {
        if pendingRuntimeRequest != nil || hasActionableProposedPlan == true || (pendingGuestMessageCount ?? 0) > 0 {
            return .needsYou
        }
        if !(pendingBackgroundTasks ?? []).isEmpty || (blockedOnThreadWait == true && (runtime?.status ?? activityRunStatus ?? status) == .running) { return .waiting }
        switch runtime?.status ?? activityRunStatus ?? status {
        case .preparing, .queued, .starting, .running, .waiting: return .running
        case .completed, .interrupted, .failed, .cancelled, .rolledBack: return .finished
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }
}

public struct T3CodeProject: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workspaceRoot: String?
    public let faviconPath: String?
    public let projectIcon: T3ProjectIcon?

    private enum CodingKeys: String, CodingKey { case id, title, workspaceRoot, faviconPath, projectIcon }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        workspaceRoot = try c.decodeIfPresent(String.self, forKey: .workspaceRoot)
        faviconPath = try? c.decodeIfPresent(String.self, forKey: .faviconPath)
        projectIcon = try? c.decodeIfPresent(T3ProjectIcon.self, forKey: .projectIcon)
    }
}

public struct T3CodeSnapshot: Sendable, Equatable {
    public let sequence: Int
    public let projects: [T3CodeProject]
    public let threads: [T3CodeThread]
    public let archivedThreads: [T3CodeThread]
    /// Which connection of the client produced this snapshot (set by the client, not decoded). Confirmations
    /// made on one connection are refused on the next, even if no reconnect event reached the UI.
    public var connection: Int = 0
}

public enum T3CodeConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected
    case reconnecting(attempt: Int)
    case failed(T3CodeError)
}

public enum T3CodeClientEvent: Sendable, Equatable {
    case connection(T3CodeConnectionState)
    case snapshot(T3CodeSnapshot)
}
