import Foundation

/// The local server process and connection on which a confirmation was presented.
public struct T3CodeActionConnection: Sendable, Equatable {
    public let generation: Int
    public let port: Int
    public let pid: Int32?
    public let startedAt: Date?

    public init(generation: Int, port: Int, pid: Int32?, startedAt: Date?) {
        self.generation = generation; self.port = port; self.pid = pid; self.startedAt = startedAt
    }
}

public struct T3CodeActionIntent: Sendable, Equatable {
    public enum Action: Sendable { case stop, resume }
    public let connection: T3CodeActionConnection
    public let threadID: String
    public let runID: String
    public let action: Action
    /// The client connection whose snapshot the user was looking at (T3CodeSnapshot.connection).
    public let clientConnection: Int?
    private let recoveryRunID: String?

    public init?(connection: T3CodeActionConnection, thread: T3CodeThread, action: Action, clientConnection: Int? = nil) {
        guard let run = action == .stop ? thread.activeRunId : thread.latestRunId, !run.isEmpty else { return nil }
        self.connection = connection; threadID = thread.id; runID = run; self.action = action
        self.clientConnection = clientConnection
        recoveryRunID = thread.limitRecovery?.runId
        guard isValid(connection: connection, thread: thread) else { return nil }
    }

    public func isValid(connection: T3CodeActionConnection?, thread: T3CodeThread?) -> Bool {
        guard connection == self.connection, let thread, thread.id == threadID,
              thread.archivedAt == nil, thread.deletedAt == nil else { return false }
        switch action {
        case .stop: return thread.activeRunId == runID && (thread.attention == .running || thread.attention == .waiting)
        case .resume:
            return thread.latestRunId == runID && thread.isUsageLimited && thread.activeRunId == nil
                && thread.activityRunStatus == nil && thread.pendingRuntimeRequest == nil
                && thread.limitRecovery?.runId == recoveryRunID
                && (recoveryRunID == nil || recoveryRunID == runID)
        }
    }

    public static let changedMessage = "The thread changed while the dialog was open; nothing was done."
}

public enum ResetAttemptResult: Sendable, Equatable {
    case succeeded, notAttempted, failed
}

public enum T3ResetAndResume {
    public static func canConsume(quota: QuotaReading, at now: Date, threadIsValid: Bool) -> Bool {
        threadIsValid && QuotaWindowKind.allCases.contains { (quota.remaining($0, at: now) ?? 1) <= 0 }
    }

    public static func shouldResume(result: ResetAttemptResult, threadIsValid: Bool) -> Bool {
        result == .succeeded && threadIsValid
    }
}

/// Persist only nonsecret session IDs, before discarding local credentials.
public struct T3CodePendingRevocations {
    private let defaults: UserDefaults
    private let key = "t3code.pendingRevocations"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var sessionIDs: [String] { defaults.stringArray(forKey: key) ?? [] }
    public func insert(_ sessionID: String) {
        guard !sessionIDs.contains(sessionID) else { return }
        defaults.set(sessionIDs + [sessionID], forKey: key)
    }
    /// Called only after successful revocation; failures leave the record intact.
    public func didRevoke(_ sessionID: String) {
        defaults.set(sessionIDs.filter { $0 != sessionID }, forKey: key)
    }
}
