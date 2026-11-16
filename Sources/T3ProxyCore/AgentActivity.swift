import Foundation

public enum AgentActivity: String, Sendable, CaseIterable {
    case idle, working, streaming, subagent, waiting
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .streaming: "Streaming"
        case .subagent: "Subagents running"
        case .waiting: "Needs you"
        }
    }
}
public enum AgentEffect: String, Sendable, CaseIterable { case report, finished, error }
public struct AgentActivityUpdate: Sendable, Equatable {
    public var state: AgentActivity = .idle
    public var needsAttention = false
    public var hasWorkingThread = false
    public var hasDelegatedWork = false
    public var snoozedThreadCount = 0
    public var hasWaitingThread = false
    public var threadTitle: String?
    public var effect: AgentEffect?
    public init(state: AgentActivity = .idle, needsAttention: Bool = false, threadTitle: String? = nil, effect: AgentEffect? = nil,
                hasWorkingThread: Bool? = nil, hasDelegatedWork: Bool? = nil,
                snoozedThreadCount: Int = 0, hasWaitingThread: Bool = false) {
        self.state = state; self.needsAttention = needsAttention; self.threadTitle = threadTitle; self.effect = effect
        self.hasWorkingThread = hasWorkingThread ?? (state == .working || state == .streaming)
        self.hasDelegatedWork = hasDelegatedWork ?? (state == .subagent)
        self.snoozedThreadCount = snoozedThreadCount; self.hasWaitingThread = hasWaitingThread
    }
    public var label: String {
        var parts: [String] = []
        if state == .streaming { parts.append("Streaming") }
        else if hasWorkingThread { parts.append("Working") }
        if hasWaitingThread { parts.append("Waiting on work") }
        else if hasDelegatedWork { parts.append("Background work") }
        if needsAttention || state == .waiting { parts.append("Needs you") }
        if snoozedThreadCount > 0 { parts.append("\(snoozedThreadCount) snoozed") }
        return parts.isEmpty ? state.label : parts.joined(separator: " · ")
    }
}

/// Shell summaries do not contain text deltas: `.streaming` is reserved for a future verified signal.
/// Only observed, run-bound transitions produce overlays; historical terminal snapshots stay quiet.
public struct AgentActivityReducer: Sendable {
    private var connection: Int?
    private var sequence = -1
    private struct Observation: Sendable { let run: String?; let active: Bool }
    private var previous: [String: Observation] = [:]
    private var pendingFinish: [String: String] = [:]
    private var fired: Set<String> = []
    private var current = AgentActivityUpdate()
    public init() {}
    public mutating func disconnect() { self = Self() }

    public mutating func update(_ snapshot: T3CodeSnapshot, now: Date) -> AgentActivityUpdate {
        let baseline = connection != snapshot.connection
        if !baseline && snapshot.sequence < sequence {
            var unchanged = current; unchanged.effect = nil; return unchanged
        }
        if baseline { previous = [:]; fired = []; pendingFinish = [:] }
        connection = snapshot.connection; sequence = snapshot.sequence
        let family = T3ThreadFamily(snapshot, now: now)
        let roots = snapshot.threads.filter { $0.isListed && !family.childIDs.contains($0.id) && $0.isVisibleOnThreadBoard(at: now) }
        var visible: [String: T3CodeThread] = [:]
        func collect(_ thread: T3CodeThread) {
            guard visible[thread.id] == nil else { return }
            visible[thread.id] = thread
            for child in family.children[thread.id, default: []] { collect(child) }
        }
        roots.forEach(collect)
        let knownIDs = Set(snapshot.threads.map(\.id))
        func hasBackground(_ thread: T3CodeThread) -> Bool {
            (thread.pendingBackgroundTasks ?? []).contains { task in
                // A known child's visible summary wins over stale roster entries, including snoozes.
                !knownIDs.contains(task.childThreadId ?? "")
                    && !["completed", "failed", "cancelled", "interrupted"].contains(task.status ?? "")
            } || (thread.blockedOnThreadWait == true && [.running, .waiting].contains(thread.runtime?.status ?? thread.activityRunStatus ?? thread.status))
        }
        func ownActive(_ thread: T3CodeThread) -> Bool {
            [.preparing, .queued, .starting, .running, .waiting].contains(thread.runtime?.status ?? thread.activityRunStatus ?? thread.status)
        }
        func waitingOnWork(_ thread: T3CodeThread) -> Bool {
            // Mirrors the sidebar: runtime "waiting" still means Working.
            (thread.runtime?.status == .idle && thread.attention != .needsYou)
                || (thread.blockedOnThreadWait == true && (thread.runtime?.status ?? thread.activityRunStatus ?? thread.status) == .running)
        }
        func unfinished(_ thread: T3CodeThread, visited: Set<String> = []) -> Bool {
            guard !visited.contains(thread.id) else { return false }
            let visited = visited.union([thread.id])
            return ownActive(thread) || waitingOnWork(thread) || thread.attention == .needsYou || hasBackground(thread)
                || family.children[thread.id, default: []].contains { unfinished($0, visited: visited) }
        }
        var result = AgentActivityUpdate()
        result.snoozedThreadCount = Set(snapshot.threads.filter {
            $0.isAvailableOnThreadBoard && $0.isSnoozed(at: now)
        }.map(\.id)).count
        var observations: [String: Observation] = [:]
        // Deterministic title choice across otherwise equivalent active threads.
        for thread in visible.values.sorted(by: { $0.id < $1.id }) {
            let status = thread.runtime?.status ?? thread.activityRunStatus ?? thread.status
            let active = ownActive(thread)
            let run = thread.activeRunId ?? thread.latestRunId
            observations[thread.id] = Observation(run: run, active: active)
            let needs = thread.attention == .needsYou
            result.needsAttention = result.needsAttention || needs
            let subagent = family.childIDs.contains(thread.id) || thread.lineage?.relationshipToParent == "subagent"
            let dependents = hasBackground(thread) || family.children[thread.id, default: []].contains { unfinished($0) }
            let waiting = waitingOnWork(thread)
            let delegated = waiting || dependents || (subagent && (active || needs))
            let userBlocked = thread.pendingRuntimeRequest?.blocksRun == true || (status == .waiting && needs)
            let working = active && !subagent && !userBlocked && !waiting
            result.hasWaitingThread = result.hasWaitingThread || waiting
            result.hasWorkingThread = result.hasWorkingThread || working
            result.hasDelegatedWork = result.hasDelegatedWork || delegated
            let candidate: AgentActivity = delegated ? .subagent : working ? .working : needs ? .waiting : .idle
            func rank(_ state: AgentActivity) -> Int {
                switch state { case .idle: 0; case .waiting: 1; case .working: 2; case .subagent: 3; case .streaming: 4 }
            }
            if rank(candidate) > rank(result.state) { result.state = candidate; result.threadTitle = thread.title }
            guard !baseline, let run else { continue }
            if pendingFinish[thread.id] != run { pendingFinish[thread.id] = nil }
            let transition = previous[thread.id].map { $0.active && $0.run == run && !active } ?? false
            if transition && status == .completed && (dependents || needs) { pendingFinish[thread.id] = run }
            let settled = status == .completed && !dependents && !needs
            guard (transition && status == .failed) || (settled && (transition || pendingFinish[thread.id] == run)) else { continue }
            pendingFinish[thread.id] = nil
            let key = "\(thread.id)|\(run)|\(status.rawValue)"
            guard fired.insert(key).inserted else { continue }
            let effect: AgentEffect = status == .failed ? .error : (subagent ? .report : .finished)
            // A single bounded overlay represents simultaneous transitions; active siblings continue underneath.
            if result.effect == nil || effect == .error || (effect == .finished && result.effect == .report) { result.effect = effect }
        }
        pendingFinish = pendingFinish.filter { visible[$0.key] != nil }
        previous = observations
        if fired.count > 2000 { fired = [] }
        current = result
        return result
    }
}
