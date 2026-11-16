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
    @Test func snoozesRemainVisibleWithoutBecomingWorkAttentionOrCompletion() {
        let until = ISO8601DateFormatter().string(from: clock + 60)
        let snooze: [String: Any] = ["snoozedUntil": until]
        var reducer = AgentActivityReducer()
        _ = reducer.update(shell([agent("sleep")]), now: clock)
        let sleeping = reducer.update(shell([agent("sleep", "completed", extra: snooze),
            agent("archived", extra: snooze.merging(["archivedAt": until]) { _, new in new }),
            agent("settled", extra: snooze.merging(["settledOverride": "settled"]) { _, new in new })], 2), now: clock)
        #expect(sleeping.snoozedThreadCount == 1)
        #expect(sleeping.label == "1 snoozed")
        #expect(sleeping.state == .idle && !sleeping.hasWorkingThread && !sleeping.hasDelegatedWork && !sleeping.needsAttention)
        #expect(sleeping.effect == nil)
        let mixed = reducer.update(shell([agent("sleep", "completed", extra: snooze), agent("work")], 3), now: clock)
        #expect(mixed.hasWorkingThread && mixed.snoozedThreadCount == 1)
        #expect(mixed.label == "Working · 1 snoozed")
        let awake = reducer.update(shell([agent("sleep", "completed", extra: snooze), agent("work")], 4), now: clock + 61)
        #expect(awake.snoozedThreadCount == 0 && awake.effect == nil)
    }

    @Test func waitingAndWorkingThreadsKeepSeparateSignals() {
        var reducer = AgentActivityReducer()
        for waiting in [agent("wait", extra: ["runtime": ["status": "idle"]]),
                        agent("wait", extra: ["blockedOnThreadWait": true])] {
            let alone = reducer.update(shell([waiting]), now: clock)
            #expect(alone.hasWaitingThread && alone.hasDelegatedWork && !alone.hasWorkingThread && !alone.needsAttention)
            #expect(alone.label == "Waiting on work")
            let mixed = reducer.update(shell([waiting, agent("work")], 2), now: clock)
            #expect(mixed.hasWaitingThread && mixed.hasWorkingThread && mixed.hasDelegatedWork)
            #expect(mixed.label == "Working · Waiting on work")
            reducer.disconnect()
        }
        let needsYou = reducer.update(shell([agent("ask", "waiting", extra: ["pendingRuntimeRequest": ["id": "ask", "kind": "user_input"]])]), now: clock)
        #expect(needsYou.needsAttention && !needsYou.hasWaitingThread && !needsYou.hasWorkingThread)
        reducer.disconnect()
        let runtimeWorking = reducer.update(shell([agent("work", extra: ["runtime": ["status": "waiting"]])]), now: clock)
        #expect(runtimeWorking.hasWorkingThread && !runtimeWorking.hasWaitingThread)
    }

    @Test func waitingChildDelaysParentFinishAndSleepingChildRemainsQuiet() {
        let lineage: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        var reducer = AgentActivityReducer()
        _ = reducer.update(shell([agent("p"), agent("child", extra: lineage)]), now: clock)
        let waitingChild = agent("child", "completed", extra: lineage.merging(["runtime": ["status": "idle"]]) { _, new in new })
        let waiting = reducer.update(shell([agent("p", "completed"), waitingChild], 2), now: clock)
        #expect(waiting.hasWaitingThread && waiting.hasDelegatedWork && !waiting.hasWorkingThread)
        #expect(waiting.effect != .finished)
        let finished = reducer.update(shell([agent("p", "completed"), agent("child", "completed", extra: lineage)], 3), now: clock)
        #expect(finished.effect == .finished && !finished.hasWaitingThread)
        let until = ISO8601DateFormatter().string(from: clock + 60)
        let sleepingChild = agent("child", extra: lineage.merging(["snoozedUntil": until]) { _, new in new })
        let sleeping = reducer.update(shell([agent("p", "completed"), sleepingChild], 4), now: clock)
        #expect(sleeping.snoozedThreadCount == 1 && !sleeping.hasDelegatedWork && !sleeping.hasWaitingThread)
        #expect(sleeping.effect == nil)
    }

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

extension AgentActivityTests {
    @Test func nonblockingAttentionKeepsOwnWorkAndBackgroundSignals() {
        for attention: [String: Any] in [
            ["pendingRuntimeRequest": ["id": "ask", "kind": "user_input", "blocking": false]],
            ["pendingGuestMessageCount": 1], ["hasActionableProposedPlan": true],
        ] {
            var reducer = AgentActivityReducer()
            let result = reducer.update(shell([agent("a", extra: attention)]), now: clock)
            #expect(result.hasWorkingThread && result.needsAttention)
            var combined = attention
            combined["pendingBackgroundTasks"] = [["taskId": "cmd", "kind": "command"]]
            let mixed = reducer.update(shell([agent("a", extra: combined)], 2), now: clock)
            #expect(mixed.hasWorkingThread && mixed.hasDelegatedWork && mixed.needsAttention)
        }
    }

    @Test func simultaneousWorkAttentionAndDelegationRemainIndependent() {
        var reducer = AgentActivityReducer()
        let question = agent("q", extra: ["pendingRuntimeRequest": ["id": "ask", "kind": "user_input"]])
        let background = agent("bg", "completed", extra: ["pendingBackgroundTasks": [["taskId": "cmd", "kind": "command"]]])
        let result = reducer.update(shell([agent("a"), question, background]), now: clock)
        #expect(result.hasWorkingThread && result.hasDelegatedWork && result.needsAttention)
        #expect(result.label == "Working · Background work · Needs you")
        #expect(result.effect == nil)
        let waiting = reducer.update(shell([question, background], 2), now: clock)
        #expect(!waiting.hasWorkingThread && waiting.hasDelegatedWork && waiting.needsAttention)
    }

    @Test func childErrorDoesNotHideSiblingWorkOrAttention() {
        var reducer = AgentActivityReducer()
        let lineage: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        let question = agent("q", extra: ["pendingRuntimeRequest": ["id": "ask", "kind": "user_input"]])
        _ = reducer.update(shell([agent("p"), agent("c", extra: lineage), agent("s", extra: lineage), question]), now: clock)
        let result = reducer.update(shell([agent("p"), agent("c", "failed", extra: lineage), agent("s", extra: lineage), question], 2), now: clock)
        #expect(result.effect == .error)
        #expect(result.hasWorkingThread && result.hasDelegatedWork && result.needsAttention)
    }

    @Test func parentFinishesOnlyAfterItsObservedChildrenSettle() {
        var reducer = AgentActivityReducer()
        let lineage: [String: Any] = ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]]
        _ = reducer.update(shell([agent("p"), agent("c", extra: lineage)]), now: clock)
        let waiting = reducer.update(shell([agent("p", "completed"), agent("c", extra: lineage)], 2), now: clock)
        #expect(waiting.state == .subagent)
        #expect(waiting.effect == nil)
        let settled = reducer.update(shell([agent("p", "completed"), agent("c", "completed", extra: lineage)], 3), now: clock)
        #expect(settled.state == .idle && settled.effect == .finished)
        #expect(reducer.update(shell([agent("p", "completed"), agent("c", "completed", extra: lineage)], 4), now: clock).effect == nil)
    }

    @Test func backgroundCommandsKeepCompletedParentAliveUntilTheySettle() {
        var reducer = AgentActivityReducer()
        let tasks: [String: Any] = ["pendingBackgroundTasks": [["taskId": "cmd", "kind": "command", "status": "running"]]]
        _ = reducer.update(shell([agent("p")]), now: clock)
        let waiting = reducer.update(shell([agent("p", "completed", extra: tasks)], 2), now: clock)
        #expect(waiting.state == .subagent && !waiting.needsAttention)
        #expect(waiting.effect == nil)
        #expect(reducer.update(shell([agent("p", "completed")], 3), now: clock).effect == .finished)
    }

    @Test func blockedOnChildrenDoesNotMeanNeedsYou() {
        var reducer = AgentActivityReducer()
        let waiting = reducer.update(shell([agent("p", extra: ["blockedOnThreadWait": true])]), now: clock)
        #expect(waiting.state == .subagent && !waiting.needsAttention)
    }

    @Test func deferredFinishDoesNotSurviveRunReplacementOrReconnect() {
        let tasks: [String: Any] = ["pendingBackgroundTasks": [["taskId": "cmd", "kind": "command"]]]
        for reconnect in [false, true] {
            var reducer = AgentActivityReducer()
            _ = reducer.update(shell([agent("p")]), now: clock)
            _ = reducer.update(shell([agent("p", "completed", extra: tasks)], 2), now: clock)
            let next = reducer.update(shell([agent("p", "completed", run: reconnect ? "r1" : "r2")], 3, connection: reconnect ? 2 : 1), now: clock)
            #expect(next.effect == nil)
        }
    }
}
