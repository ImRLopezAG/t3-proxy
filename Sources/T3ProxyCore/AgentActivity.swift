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
    public var threadTitle: String?
    public var effect: AgentEffect?
    public init(state: AgentActivity = .idle, needsAttention: Bool = false, threadTitle: String? = nil, effect: AgentEffect? = nil) {
        self.state = state; self.needsAttention = needsAttention; self.threadTitle = threadTitle; self.effect = effect
    }
}

/// Shell summaries do not contain text deltas: `.streaming` is reserved for a future verified signal.
/// Only observed, run-bound transitions produce overlays; historical terminal snapshots stay quiet.
public struct AgentActivityReducer: Sendable {
    private var connection: Int?
    private var sequence = -1
    private struct Observation: Sendable { let run: String?; let active: Bool }
    private var previous: [String: Observation] = [:]
    private var fired: Set<String> = []
    private var current = AgentActivityUpdate()
    public init() {}
    public mutating func disconnect() { self = Self() }

    public mutating func update(_ snapshot: T3CodeSnapshot, now: Date) -> AgentActivityUpdate {
        let baseline = connection != snapshot.connection
        if !baseline && snapshot.sequence < sequence {
            var unchanged = current; unchanged.effect = nil; return unchanged
        }
        if baseline { previous = [:]; fired = [] }
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
        var result = AgentActivityUpdate()
        var observations: [String: Observation] = [:]
        // Deterministic title choice across otherwise equivalent active threads.
        for thread in visible.values.sorted(by: { $0.id < $1.id }) {
            let status = thread.runtime?.status ?? thread.activityRunStatus ?? thread.status
            let active = [.preparing, .queued, .starting, .running, .waiting].contains(status)
            let run = thread.activeRunId ?? thread.latestRunId
            observations[thread.id] = Observation(run: run, active: active)
            let needs = thread.attention == .needsYou
            result.needsAttention = result.needsAttention || needs
            let subagent = family.childIDs.contains(thread.id) || thread.lineage?.relationshipToParent == "subagent"
            let roster = (thread.pendingBackgroundTasks ?? []).contains { task in
                task.kind == "subagent"
                    && !knownIDs.contains(task.childThreadId ?? "")
                    && !["completed", "failed", "cancelled", "interrupted"].contains(task.status ?? "")
            }
            let candidate: AgentActivity = needs ? .waiting : (active || roster ? (subagent || roster ? .subagent : .working) : .idle)
            func rank(_ state: AgentActivity) -> Int {
                switch state { case .idle: 0; case .waiting: 1; case .working: 2; case .subagent: 3; case .streaming: 4 }
            }
            if rank(candidate) > rank(result.state) { result.state = candidate; result.threadTitle = thread.title }
            guard !baseline, let run, let old = previous[thread.id], old.active, old.run == run,
                  !active, status == .completed || status == .failed else { continue }
            let key = "\(thread.id)|\(run)|\(status.rawValue)"
            guard fired.insert(key).inserted else { continue }
            let effect: AgentEffect = status == .failed ? .error : (subagent ? .report : .finished)
            // A single bounded overlay represents simultaneous transitions; active siblings continue underneath.
            if result.effect == nil || effect == .error || (effect == .finished && result.effect == .report) { result.effect = effect }
        }
        previous = observations
        if fired.count > 2000 { fired = [] }
        current = result
        return result
    }
}
