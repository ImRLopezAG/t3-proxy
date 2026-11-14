import Foundation
import Testing
@testable import T3ProxyCore

private let clock = Date(timeIntervalSince1970: 1_800_000_000)
private func agent(_ id: String, _ status: String = "running", run: String = "r1", extra: [String: Any] = [:]) -> T3CodeThread {
    var json: [String: Any] = ["id": id, "title": id, "projectId": "p", "status": status, "latestRunId": run]
    json.merge(extra) { _, new in new }
    return try! T3CodeWire.decode(T3CodeThread.self, from: JSONSerialization.data(withJSONObject: json))
}
private func shell(_ threads: [T3CodeThread], _ sequence: Int = 1, connection: Int = 1) -> T3CodeSnapshot {
    T3CodeSnapshot(sequence: sequence, projects: [], threads: threads, archivedThreads: [], connection: connection)
}
@Suite struct AgentActivityTests {
    @Test func baselinesAndConcurrentActivity() {
        var reducer = AgentActivityReducer()
        let first = reducer.update(shell([agent("old", "completed"), agent("a")]), now: clock)
        #expect(first.state == .working && first.effect == nil)
        let second = reducer.update(shell([agent("old", "completed"), agent("a", "completed"), agent("b")], 2), now: clock)
        #expect(second.state == .working && second.effect == .finished)
        #expect(second.threadTitle == "b")
        #expect(reducer.update(shell([agent("a", "completed"), agent("b")], 3), now: clock).effect == nil)
    }
    @Test func subagentsAndReports() {
        var reducer = AgentActivityReducer()
        let child: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        #expect(reducer.update(shell([agent("p"), agent("c", extra: child)]), now: clock).state == .subagent)
        let report = reducer.update(shell([agent("p"), agent("c", "completed", extra: child)], 2), now: clock)
        #expect(report.state == .working && report.effect == .report)
        #expect(reducer.update(shell([agent("p"), agent("c", extra: child)], 3), now: clock).effect == nil)
        #expect(reducer.update(shell([agent("p"), agent("c", "completed", extra: child)], 4), now: clock).effect == nil)
    }
    @Test func reconnectStaleAndNewHistoricalThreadsAreQuiet() {
        var reducer = AgentActivityReducer()
        _ = reducer.update(shell([agent("a")], 10), now: clock)
        #expect(reducer.update(shell([agent("a", "completed")], 9), now: clock).state == .working)
        #expect(reducer.update(shell([agent("a", "completed")], 1, connection: 2), now: clock).effect == nil)
        #expect(reducer.update(shell([agent("new", "completed")], 2, connection: 2), now: clock).effect == nil)
        reducer.disconnect()
        #expect(reducer.update(shell([agent("a", "completed")], 3, connection: 2), now: clock).effect == nil)
    }
    @Test func visibilityAndSleepingParentDoNotAnimate() {
        let until = ISO8601DateFormatter().string(from: clock + 60)
        let child: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        var reducer = AgentActivityReducer()
        #expect(reducer.update(shell([agent("p", extra: ["snoozedUntil": until]), agent("c", extra: child),
            agent("archived", extra: ["archivedAt": until]), agent("settled", extra: ["settledOverride": "settled"])]), now: clock).state == .idle)
        #expect(reducer.update(shell([agent("p", "completed", extra: ["snoozedUntil": until]), agent("c", "completed", extra: child)], 2), now: clock).effect == nil)
        #expect(reducer.update(shell([agent("p", "completed"), agent("c", "completed", extra: child)], 3), now: clock + 61).effect == nil)
    }
    @Test func waitingErrorsAndNewRuns() {
        var reducer = AgentActivityReducer()
        let question = agent("q", extra: ["pendingRuntimeRequest": ["id": "ask", "kind": "user_input"]])
        #expect(reducer.update(shell([question]), now: clock).state == .waiting)
        let busy = reducer.update(shell([question, agent("b")], 2), now: clock)
        #expect(busy.state == .working && busy.needsAttention)
        #expect(reducer.update(shell([agent("b", "failed")], 3), now: clock).effect == .error)
        _ = reducer.update(shell([agent("b", run: "r2")], 4), now: clock)
        #expect(reducer.update(shell([agent("b", "completed", run: "r2")], 5), now: clock).effect == .finished)
    }
    @Test func missingRosterChildStillShowsSubagentButSnoozedChildDoesNot() {
        var reducer = AgentActivityReducer()
        let roster: [String: Any] = ["pendingBackgroundTasks": [["taskId": "t", "kind": "subagent", "childThreadId": "c"]]]
        #expect(reducer.update(shell([agent("p", extra: roster)]), now: clock).state == .subagent)
        let until = ISO8601DateFormatter().string(from: clock + 60)
        #expect(reducer.update(shell([agent("p", extra: roster), agent("c", extra: ["snoozedUntil": until])], 2), now: clock).state == .working)
    }
}

extension AgentActivityTests {
    @Test func staleRosterCannotKeepCompletedChildAnimating() {
        var reducer = AgentActivityReducer()
        let parent = agent("p", extra: ["pendingBackgroundTasks": [["taskId": "task", "kind": "subagent", "childThreadId": "c"]]])
        let lineage: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        _ = reducer.update(shell([parent, agent("c", extra: lineage)]), now: clock)
        let update = reducer.update(shell([parent, agent("c", "completed", extra: lineage)], 2), now: clock)
        #expect(update.state == .working && update.effect == .report)
    }
    @Test func cancellationRemovalAndRunMismatchAreNotCompletion() {
        for next in [agent("a", "cancelled"), agent("a", "completed", run: "unobserved") ] {
            var reducer = AgentActivityReducer()
            _ = reducer.update(shell([agent("a")]), now: clock)
            #expect(reducer.update(shell([next], 2), now: clock).effect == nil)
        }
        var reducer = AgentActivityReducer()
        _ = reducer.update(shell([agent("a")]), now: clock)
        #expect(reducer.update(shell([], 2), now: clock).effect == nil)
    }
}

extension AgentActivityTests {
    @Test func completedParentAndRosterReturnToIdle() {
        let roster: [String: Any] = ["pendingBackgroundTasks": [["taskId": "task", "kind": "subagent", "childThreadId": "c", "status": "completed"]]]
        let lineage: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        var reducer = AgentActivityReducer()
        let update = reducer.update(shell([agent("p", "completed", extra: roster), agent("c", "completed", extra: lineage)]), now: clock)
        #expect(update.state == .idle)
        #expect(update.effect == nil)
    }
}
