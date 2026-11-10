import Foundation
import Testing
@testable import T3ProxyCore

// Synthetic fixtures only.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private func thread(_ id: String, status: String = "running", instance: String = "codex", project: String = "p1",
                    updated: Date = now, extra: [String: Any] = [:]) -> T3CodeThread {
    var o: [String: Any] = ["id": id, "title": "Title \(id)", "projectId": project, "status": status,
                            "providerInstanceId": instance, "modelSelection": ["instanceId": instance, "model": "m-1"],
                            "latestRunId": "run-\(id)", "updatedAt": iso(updated)]
    for (k, v) in extra { o[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: o)
    return try! T3CodeWire.decode(T3CodeThread.self, from: data)
}
private func snap(_ threads: [T3CodeThread]) -> T3CodeSnapshot {
    let projects = try! T3CodeWire.decode([T3CodeProject].self, from: Data(#"[{"id":"p1","title":"Proj"}]"#.utf8))
    return T3CodeSnapshot(sequence: 1, projects: projects, threads: threads, archivedThreads: [])
}
private func limited(_ id: String, instance: String = "codex") -> T3CodeThread {
    thread(id, status: "failed", instance: instance, extra: ["lastErrorClass": "usage_limit", "usageLimitResetAt": iso(now + 3600)])
}

@Suite struct T3ThreadBoardTests {
    @Test func limitDetailOnlyPromisesMatchingAutomaticRecovery() {
        for autoResume in [true, false] {
            for run in ["run-L", "older-run"] {
                let t = thread("L", status: "failed", extra: ["lastErrorClass": "usage_limit",
                    "limitRecovery": ["runId": run, "resetAt": iso(now + 3600), "autoResume": autoResume]])
                let status = T3ThreadBoard.sections(snap([t]), now: now)[0].rows[0].status
                let prefix = autoResume && run == "run-L" ? "resumes " : "limit resets "
                #expect(status.detail(now: now)?.hasPrefix(prefix) == true)
            }
        }
        let t = thread("L", status: "failed", extra: ["lastErrorClass": "usage_limit"])
        #expect(T3ThreadBoard.sections(snap([t]), now: now)[0].rows[0].status.detail(now: now) == nil)
    }
    @Test func groupsAndOmitsEmpty() {
        let s = T3ThreadBoard.sections(snap([thread("a"), thread("b", status: "completed", updated: now - 60)]), now: now)
        #expect(s.map(\.group) == [.running, .finished])
    }
    @Test func needsYouKinds() {
        let q = thread("q", extra: ["pendingRuntimeRequest": ["id": "r1", "kind": "user_input"]])
        let a = thread("a", extra: ["pendingRuntimeRequest": ["id": "r2", "kind": "command", "createdAt": iso(now - 300)]])
        let p = thread("p", status: "completed", extra: ["hasActionableProposedPlan": true])
        let rows = T3ThreadBoard.sections(snap([q, a, p]), now: now)[0].rows
        #expect(Set(rows.map(\.status.label)) == ["Question", "Approval", "Plan"])
        let ar = rows.first { $0.id == "a" }!
        #expect(ar.status.detail(now: now) == "5m")
    }
    @Test func excludesSubagentsSideChatsArchivedDeletedAndCountsChildren() {
        let child = thread("c", extra: ["lineage": ["parentThreadId": "a", "relationshipToParent": "subagent", "rootThreadId": "a"]])
        let side = thread("s", extra: ["lineage": ["parentThreadId": "a", "rootThreadId": "a", "sideChat": true]])
        let arch = thread("x", extra: ["archivedAt": iso(now)])
        let del = thread("d", extra: ["deletedAt": iso(now)])
        let s = T3ThreadBoard.sections(snap([thread("a"), child, side, arch, del]), now: now)
        #expect(s.count == 1 && s[0].rows.map(\.id) == ["a"])
        #expect(s[0].rows[0].subtitle == "Proj · m-1 · 1 subagent running")
    }
    @Test func finishedWindowSettledCapAndOrder() {
        var ts = (0..<7).map { thread("f\($0)", status: "completed", updated: now - Double($0) * 60) }
        ts.append(thread("old", status: "completed", updated: now - 25 * 3600))
        ts.append(thread("settled", status: "failed", extra: ["settledOverride": "settled"]))
        ts.append(thread("int", status: "interrupted"))
        let rows = T3ThreadBoard.sections(snap(ts), now: now)[0].rows
        #expect(rows.map(\.id) == ["f0", "f1", "f2", "f3", "f4"])
        #expect(rows[1].status == .done(at: now - 60))
        #expect(rows[1].status.detail(now: now) == "1m ago")
    }
    @Test func limitRowsFirstUncapped() {
        var ts = (0..<6).map { thread("f\($0)", status: "failed", updated: now - Double($0)) }
        ts.append(limited("L"))
        let rows = T3ThreadBoard.sections(snap(ts), now: now)[0].rows
        #expect(rows.first?.id == "L" && rows.count == 6)
        #expect(rows.first?.status == .limit(resumesAt: now + 3600))
        #expect(rows.first?.canResume == true)
        #expect(rows[1].status.label == "Failed")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(rows.first?.status.detail(now: now, calendar: cal, locale: Locale(identifier: "en_US"))?.hasPrefix("limit resets ") == true)
    }
    @Test func runningElapsedUsesFirstSeen() {
        let s = T3ThreadBoard.sections(snap([thread("a")]), now: now, runningSince: ["a": now - 3725])
        #expect(s[0].rows[0].status.detail(now: now) == "1h 2m")
        #expect(T3ThreadStatus.elapsed(from: now - 42, to: now) == "42s")
    }
    @Test func footerAndDot() {
        let n = thread("n", extra: ["pendingRuntimeRequest": ["id": "r", "kind": "permission"]])
        let s = T3ThreadBoard.sections(snap([n, thread("a"), thread("b")]), now: now)
        #expect(T3ThreadBoard.footer(s) == "1 needs you · 2 running")
        #expect(T3ThreadBoard.footer([]) == "No active threads")
        #expect(T3ThreadBoard.needsAttention(snap([n])))
        #expect(!T3ThreadBoard.needsAttention(snap([thread("a")])))
        #expect(!T3ThreadBoard.needsAttention(nil))
    }
    @Test func providerMapping() {
        #expect(T3ThreadProvider(instanceID: "claudeAgent") == .claude)
        #expect(T3ThreadProvider(instanceID: "claude_proxy") == .claude)
        #expect(T3ThreadProvider(instanceID: "codex_proxy") == .codex)
        #expect(T3ThreadProvider(instanceID: "cursor") == .other)
        #expect(T3ThreadProvider(instanceID: nil) == .other)
    }
    @Test func deepLink() {
        #expect(T3CodeLinks.threadURL(environmentID: "db39-ab", threadID: "t_1")?.absoluteString == "t3code://threads/db39-ab/t_1")
        #expect(T3CodeLinks.threadURL(environmentID: "a/b", threadID: "t") == nil)
        #expect(T3CodeLinks.threadURL(environmentID: "a", threadID: "t?x=1") == nil)
        #expect(T3CodeLinks.threadURL(environmentID: "", threadID: "t") == nil)
    }
}

@Suite struct T3CodeActionTests {
    private let connection = T3CodeActionConnection(generation: 1, port: 3773, pid: 100, startedAt: now)

    @Test func stopConfirmationRejectsNewRunOrConnection() throws {
        let t = thread("a", extra: ["activeRunId": "first"])
        let intent = try #require(T3CodeActionIntent(connection: connection, thread: t, action: .stop))
        #expect(intent.isValid(connection: connection, thread: t))
        #expect(!intent.isValid(connection: connection, thread: thread("a", extra: ["activeRunId": "second"])))
        #expect(!intent.isValid(connection: nil, thread: t))
        for changed in [T3CodeActionConnection(generation: 2, port: 3773, pid: 100, startedAt: now),
                        .init(generation: 1, port: 4000, pid: 100, startedAt: now),
                        .init(generation: 1, port: 3773, pid: 200, startedAt: now),
                        .init(generation: 1, port: 3773, pid: 100, startedAt: now + 1)] {
            #expect(!intent.isValid(connection: changed, thread: t))
        }
    }

    @Test func resumeConfirmationRejectsNewRunOrRecovery() throws {
        let t = limited("a")
        let intent = try #require(T3CodeActionIntent(connection: connection, thread: t, action: .resume))
        #expect(intent.isValid(connection: connection, thread: t))
        #expect(!intent.isValid(connection: connection, thread: thread("a", status: "failed",
            extra: ["lastErrorClass": "usage_limit", "latestRunId": "new-run"])))
        #expect(!intent.isValid(connection: connection, thread: thread("a", status: "failed",
            extra: ["lastErrorClass": "usage_limit", "activeRunId": "new-run"])))
        let recovery = thread("a", status: "failed", extra: ["lastErrorClass": "usage_limit",
            "limitRecovery": ["runId": "run-a", "resetAt": iso(now + 3600), "autoResume": true]])
        let recoveredIntent = try #require(T3CodeActionIntent(connection: connection, thread: recovery, action: .resume))
        #expect(recoveredIntent.isValid(connection: connection, thread: recovery))
        #expect(!recoveredIntent.isValid(connection: connection, thread: t))
        #expect(!recoveredIntent.isValid(connection: .init(generation: 2, port: 3773, pid: 100, startedAt: now), thread: recovery))
    }

    @Test func resetNeedsCurrentExhaustionAndOwnSuccess() {
        var quota = QuotaReading(observedAt: now, windows: [
            .init(id: "five-hour", label: "Session", usedPercent: 100, resetAt: now + 30)], models: [:], plan: nil)
        #expect(T3ResetAndResume.canConsume(quota: quota, at: now, threadIsValid: true))
        #expect(!T3ResetAndResume.canConsume(quota: quota, at: now, threadIsValid: false))
        #expect(!T3ResetAndResume.canConsume(quota: quota, at: now + 31, threadIsValid: true))
        quota.windows[0].usedPercent = 50
        #expect(!T3ResetAndResume.canConsume(quota: quota, at: now, threadIsValid: true))
        quota.windows.append(.init(id: "weekly", label: "Weekly", usedPercent: 100, resetAt: now + 60))
        #expect(T3ResetAndResume.canConsume(quota: quota, at: now, threadIsValid: true))
        #expect(!T3ResetAndResume.canConsume(quota: .none, at: now, threadIsValid: true))
        for result in [ResetAttemptResult.notAttempted, .failed] {
            #expect(!T3ResetAndResume.shouldResume(result: result, threadIsValid: true))
        }
        #expect(T3ResetAndResume.shouldResume(result: .succeeded, threadIsValid: true))
        #expect(!T3ResetAndResume.shouldResume(result: .succeeded, threadIsValid: false))
    }

    @Test func revocationsSurviveRelaunchUntilSuccessfulAndPreserveOtherSessions() throws {
        let suite = "T3ProxyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = T3CodePendingRevocations(defaults: defaults)
        records.insert("synthetic-old-session")
        records.insert("synthetic-old-session")
        // A failed revoke doesn't acknowledge the record; a new owner still finds it.
        let relaunched = T3CodePendingRevocations(defaults: defaults)
        #expect(relaunched.sessionIDs == ["synthetic-old-session"])
        relaunched.insert("synthetic-other-session")
        relaunched.didRevoke("synthetic-old-session")
        #expect(records.sessionIDs == ["synthetic-other-session"])
        records.didRevoke("synthetic-other-session")
        #expect(relaunched.sessionIDs.isEmpty)
    }
}

@Suite struct T3ResetChoiceTests {
    @Test func onlyExhaustedWithCreditsSoonestFirst() {
        let c = [T3ResetCandidate(accountID: "a", exhausted: true, creditExpiries: [now + 900]),
                 T3ResetCandidate(accountID: "b", exhausted: true, creditExpiries: [nil, now + 100]),
                 T3ResetCandidate(accountID: "c", exhausted: false, creditExpiries: [now + 1]),
                 T3ResetCandidate(accountID: "d", exhausted: true, creditExpiries: [])]
        #expect(T3ResetChoice.pick(c) == "b")
        #expect(T3ResetChoice.pick(c.filter { $0.accountID != "b" }) == "a")
        #expect(T3ResetChoice.pick([c[2], c[3]]) == nil)
        #expect(T3ResetChoice.pick([T3ResetCandidate(accountID: "z", exhausted: true, creditExpiries: [nil]),
                                    T3ResetCandidate(accountID: "y", exhausted: true, creditExpiries: [nil])]) == "y")
    }
    @Test func onlyCodexLimitedThreads() {
        let c = [T3ResetCandidate(accountID: "a", exhausted: true, creditExpiries: [now])]
        #expect(T3ResetChoice.pick(for: limited("x"), now: now, candidates: c) == "a")
        #expect(T3ResetChoice.pick(for: limited("x", instance: "claudeAgent"), now: now, candidates: c) == nil)
        #expect(T3ResetChoice.pick(for: thread("r"), now: now, candidates: c) == nil)
    }
}

@Suite struct T3ThreadAlertTests {
    private var all: AlertSettings { var s = AlertSettings(); for k in AlertKind.t3CodeKinds { s.set(k, on: true) }; return s }

    @Test func defaults() {
        let s = AlertSettings()
        #expect(s.isOn(.threadNeedsYou) && s.isOn(.threadLimited))
        #expect(!s.isOn(.threadFinished) && !s.isOn(.threadFailed))
        var t = s; t.set(.threadFinished, on: true); t.set(.threadNeedsYou, on: false)
        #expect(t.isOn(.threadFinished) && !t.isOn(.threadNeedsYou))
        // Older saved settings (no `enabled`) decode.
        let old = try! JSONDecoder().decode(AlertSettings.self, from: Data(#"{"disabled":["lowQuota"],"threshold":10}"#.utf8))
        #expect(!old.isOn(.lowQuota) && !old.isOn(.threadFinished) && old.isOn(.threadNeedsYou))
    }
    @Test func seedsWithoutAlertingThenFiresOncePerTransition() {
        let needs = thread("a", extra: ["pendingRuntimeRequest": ["id": "r1", "kind": "command"]])
        var (alerts, st) = T3ThreadAlertRules.evaluate(.init(), snap([needs]), settings: all, now: now)
        #expect(alerts.isEmpty)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a")]), settings: all, now: now)
        #expect(alerts.isEmpty)
        // Same request again after running: already notified (seeded) → nothing.
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([needs]), settings: all, now: now)
        #expect(alerts.isEmpty)
        let needs2 = thread("a", extra: ["pendingRuntimeRequest": ["id": "r2", "kind": "command"]])
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([needs2]), settings: all, now: now)
        #expect(alerts.count == 1 && alerts[0].kind == .threadNeedsYou)
        #expect(alerts[0].title == "Title a" && alerts[0].body == "Proj · Needs you" && alerts[0].threadID == "a")
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([needs2]), settings: all, now: now)
        #expect(alerts.isEmpty)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([limited("a")]), settings: all, now: now)
        #expect(alerts.map(\.kind) == [.threadLimited])
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a", status: "completed")]), settings: all, now: now)
        #expect(alerts.map(\.kind) == [.threadFinished])
    }
    @Test func respectsSettingsAndForgetsRemovedThreads() {
        var (alerts, st) = T3ThreadAlertRules.evaluate(.init(), snap([thread("a")]), settings: AlertSettings(), now: now)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a", status: "failed")]), settings: AlertSettings(), now: now)
        #expect(alerts.isEmpty)   // failed is off by default
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([]), settings: AlertSettings(), now: now)
        // History survives an empty/partial snapshot (reconnect), so "a" coming back failed is not news.
        #expect(st.last["a"] != nil)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a", status: "failed")]), settings: all, now: now)
        #expect(alerts.isEmpty)
        // A new thread appearing after seeding in a non-alert state, then failing.
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("b")]), settings: all, now: now)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("b", status: "failed")]), settings: all, now: now)
        #expect(alerts.map(\.kind) == [.threadFailed])
    }
}

@Suite struct T3ThreadWaitingTests {
    @Test func runningChildrenMapByLineageAndRosterWithoutDuplicates() throws {
        let parent = thread("parent", status: "completed", extra: ["pendingBackgroundTasks": [
            ["taskId": "native", "kind": "subagent", "childThreadId": "native"],
            ["id": "delegated", "kind": "subagent", "childThreadId": "thread:delegated-task:sample"],
            ["taskId": "shell", "kind": "command", "description": "Build package"]]])
        let native = thread("native", extra: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"]])
        let delegated = thread("thread:delegated-task:sample", extra: ["activeRunId": "child-run"])
        let grandchild = thread("grandchild", extra: ["lineage": ["parentThreadId": "native", "relationshipToParent": "subagent"]])
        let snapshot = snap([parent, native, delegated, grandchild])
        let sections = T3ThreadBoard.sections(snapshot, now: now, runningSince: ["parent": now - 65])
        let row = try #require(sections.first?.rows.first)
        #expect(sections.count == 1 && sections[0].rows.count == 1)
        #expect(row.status == .waiting(since: now - 65))
        #expect(row.status.detail(now: now) == "1m")
        #expect(row.runningSubagents == 2)
        #expect(row.hasChildren)
        #expect(Set(row.children.map(\.id)) == ["native", "thread:delegated-task:sample"])
        #expect(row.backgroundTasks.count == 1 && row.backgroundTasks[0].displayLabel == "Build package")
        #expect(row.children.first { $0.id == "native" }?.moreChildrenLabel == "+1 more")
        #expect(row.children.allSatisfy { $0.children.isEmpty })
        #expect(!T3ThreadBoard.needsAttention(snapshot))
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", threadID: delegated.id)?.absoluteString == "t3code://threads/sample-env/thread:delegated-task:sample")
    }
    @Test func runningChildAlonePreventsCompletionAndNeedsYouPropagates() throws {
        let parent = thread("parent", status: "completed")
        let lineage = ["parentThreadId": "parent", "relationshipToParent": "subagent"]
        let running = thread("child", extra: ["lineage": lineage])
        let row = try #require(T3ThreadBoard.sections(snap([parent, running]), now: now).first?.rows.first)
        #expect(row.status.label == "Waiting")
        let question = thread("child", extra: ["lineage": lineage, "pendingRuntimeRequest": ["id": "request", "kind": "user_input"]])
        let snapshot = snap([parent, question])
        let sections = T3ThreadBoard.sections(snapshot, now: now)
        #expect(sections.first?.group == .needsYou)
        #expect(sections.first?.rows.first?.status.label == "Needs you")
        #expect(sections.first?.rows.first?.children.first?.status.label == "Needs you")
        #expect(T3ThreadBoard.needsAttention(snapshot))
    }
    @Test func blockedRunningRuntimeAndFooterCounts() {
        let blocked = thread("blocked", extra: ["runtime": ["status": "running"], "blockedOnThreadWait": true])
        #expect(blocked.attention == .waiting)
        let pending = thread("pending", status: "completed", extra: ["pendingBackgroundTasks": [["id": "job", "label": "Check", "kind": "future_kind", "status": "future_status"]]])
        #expect(pending.pendingBackgroundTasks?.first?.displayLabel == "Check")
        let question = thread("question", extra: ["pendingRuntimeRequest": ["id": "q", "kind": "permission"]])
        let sections = T3ThreadBoard.sections(snap([blocked, pending, question, thread("active")]), now: now)
        #expect(T3ThreadBoard.footer(sections) == "1 needs you · 1 running · 2 waiting")
        #expect(T3ThreadStatus.needsYou(kind: "Question", since: now - 5).detail(now: now) == "just now")
    }
    @Test func childStopUsesConfirmedRunAndConnection() throws {
        let child = thread("child", extra: ["activeRunId": "child-run", "lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"]])
        let connection = T3CodeActionConnection(generation: 1, port: 3773, pid: 100, startedAt: now)
        let intent = try #require(T3CodeActionIntent(connection: connection, thread: child, action: .stop, clientConnection: 1))
        #expect(intent.threadID == "child" && intent.runID == "child-run")
        #expect(intent.isValid(connection: connection, thread: child))
        #expect(!intent.isValid(connection: connection, thread: thread("child", extra: ["activeRunId": "new-run"])))
        #expect(!intent.isValid(connection: nil, thread: child))
        let row = T3ThreadBoard.sections(snap([thread("parent"), child]), now: now)[0].rows[0].children[0]
        #expect(row.canStop)
    }
    @Test func completedParentWithBackgroundWorkIsNotDone() {
        let parent = thread("parent", status: "completed", extra: ["pendingBackgroundTasks": [["taskId": "task", "kind": "subagent", "description": "Research", "childThreadId": "child"]]])
        let sections = T3ThreadBoard.sections(snap([parent]), now: now)
        #expect(sections.first?.group == .running)
        #expect(sections.first?.rows.first?.status.label == "Waiting")
        #expect(!T3ThreadBoard.needsAttention(snap([parent])))
    }
    @Test func recentFinishSaysJustNow() {
        #expect(T3ThreadStatus.done(at: now - 20).detail(now: now) == "just now")
        #expect(T3ThreadStatus.failed(at: now).detail(now: now) == "just now")
    }
    @Test func finishedNotificationWaitsForBackgroundCompletion() {
        let pending = thread("parent", status: "completed", extra: ["pendingBackgroundTasks": [["taskId": "task", "kind": "subagent"]]])
        var settings = AlertSettings(); settings.set(.threadFinished, on: true)
        var (_, state) = T3ThreadAlertRules.evaluate(.init(), snap([thread("parent")]), settings: settings, now: now)
        var alerts: [Alert]
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([pending]), settings: settings, now: now)
        #expect(alerts.isEmpty)
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([thread("parent", status: "completed")]), settings: settings, now: now)
        #expect(alerts.map(\.kind) == [.threadFinished])
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([thread("parent", status: "completed")]), settings: settings, now: now)
        #expect(alerts.isEmpty)
    }
    @Test func childWorkDefersFailureAndSeededWaitingCanFinish() {
        let parent = thread("parent", status: "failed")
        let child = thread("child", extra: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"]])
        var settings = AlertSettings(); settings.set(.threadFailed, on: true); settings.set(.threadFinished, on: true)
        var (alerts, state) = T3ThreadAlertRules.evaluate(.init(), snap([parent, child]), settings: settings, now: now)
        #expect(alerts.isEmpty && state.last["parent"] == "waiting")
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([parent, child]), settings: settings, now: now)
        #expect(alerts.isEmpty)
        let completed = thread("child", status: "completed", extra: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"]])
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([parent, completed]), settings: settings, now: now)
        #expect(alerts.map(\.kind) == [.threadFailed])
        let waiting = thread("second", status: "completed", extra: ["pendingBackgroundTasks": [["taskId": "task", "kind": "background_task"]]])
        (_, state) = T3ThreadAlertRules.evaluate(.init(), snap([waiting]), settings: settings, now: now)
        (alerts, state) = T3ThreadAlertRules.evaluate(state, snap([thread("second", status: "completed")]), settings: settings, now: now)
        #expect(alerts.map(\.kind) == [.threadFinished])
    }
}

@Suite struct T3ThreadReviewFixTests {
    @Test func settledParentsStayHiddenDespiteStaleChildAttention() {
        let settled = thread("parent", status: "completed", extra: ["settledOverride": "settled"])
        let child = thread("child", extra: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"],
            "pendingRuntimeRequest": ["id": "old-request", "kind": "user_input"]])
        let snapshot = snap([settled, child])
        let sections = T3ThreadBoard.sections(snapshot, now: now)
        #expect(sections.isEmpty)
        #expect(T3ThreadBoard.footer(sections) == "No active threads")
        #expect(!T3ThreadBoard.needsAttention(snapshot))
        var all = AlertSettings(); for kind in AlertKind.t3CodeKinds { all.set(kind, on: true) }
        let (_, seeded) = T3ThreadAlertRules.evaluate(.init(), snap([thread("parent")]), settings: all, now: now)
        let (alerts, _) = T3ThreadAlertRules.evaluate(seeded, snapshot, settings: all, now: now)
        #expect(alerts.isEmpty)
    }

    @Test func settlementSuppressesEveryOwnAttentionState() {
        let variants: [[String: Any]] = [
            [:],
            ["pendingRuntimeRequest": ["id": "old-request", "kind": "command"]],
            ["hasActionableProposedPlan": true],
            ["pendingBackgroundTasks": [["taskId": "old-task", "kind": "subagent"]]],
            ["blockedOnThreadWait": true, "runtime": ["status": "running"]]
        ]
        for status in ["running", "completed", "failed"] {
            for variant in variants {
                var extra = variant; extra["settledOverride"] = "settled"
                let snapshot = snap([thread("settled", status: status, extra: extra)])
                #expect(T3ThreadBoard.sections(snapshot, now: now).isEmpty)
                #expect(!T3ThreadBoard.needsAttention(snapshot))
            }
        }
    }

    @Test func settledChildDoesNotReviveAnUnsettledParent() throws {
        let parent = thread("parent", status: "completed")
        let child = thread("child", extra: ["settledOverride": "settled",
            "lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"],
            "pendingRuntimeRequest": ["id": "old-request", "kind": "permission"]])
        let snapshot = snap([parent, child])
        let row = try #require(T3ThreadBoard.sections(snapshot, now: now).first?.rows.first)
        #expect(row.status.label == "Done")
        #expect(row.runningSubagents == 0 && row.children.isEmpty)
        #expect(!T3ThreadBoard.needsAttention(snapshot))
        let reopened = thread("parent", extra: ["settledOverride": "active"])
        #expect(T3ThreadBoard.sections(snap([reopened]), now: now).first?.group == .running)
    }

    @Test func reconnectDoesNotAnnounceHistory() {
        var all = AlertSettings(); for k in AlertKind.t3CodeKinds { all.set(k, on: true) }
        var (alerts, st) = T3ThreadAlertRules.evaluate(.init(), snap([thread("a"), thread("b")]), settings: all, now: now)
        // Reconnect: an empty snapshot, then the full list where "a" finished meanwhile and "old" was always done.
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([]), settings: all, now: now)
        #expect(alerts.isEmpty)
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a", status: "completed"), thread("b"), thread("old", status: "completed")]),
                                                   settings: all, now: now)
        // "a" was tracked as running, so its finish is real news; "old" is first seen and stays quiet.
        #expect(alerts.map(\.threadID) == ["a"])
        // First sight of a thread that needs the user is still announced.
        let needs = thread("new", extra: ["pendingRuntimeRequest": ["id": "r9", "kind": "command"]])
        (alerts, st) = T3ThreadAlertRules.evaluate(st, snap([thread("a", status: "completed"), needs]), settings: all, now: now)
        #expect(alerts.map(\.kind) == [.threadNeedsYou])
    }

    @Test func childCycleKeepsARootVisible() {
        let a = thread("a", extra: ["pendingBackgroundTasks": [["taskId": "t1", "kind": "subagent", "childThreadId": "b"]]])
        let b = thread("b", extra: ["pendingBackgroundTasks": [["taskId": "t2", "kind": "subagent", "childThreadId": "a"]]])
        let sections = T3ThreadBoard.sections(snap([a, b]), now: now)
        let top = sections.flatMap(\.rows).map(\.thread.id)
        #expect(top == ["a"], "\(top)")
        #expect(sections.flatMap(\.rows).first?.children.map(\.thread.id) == ["b"])
    }
}

@Suite struct T3ThreadChildOrderTests {
    @Test func activeChildrenFirstAndFinishedCapped() {
        let kids = ["k1", "k2", "k3", "k4", "k5"].enumerated().map { i, id in
            thread(id, status: "completed", updated: now - Double(i * 60),
                   extra: ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]])
        }
        let live = thread("live", extra: ["lineage": ["parentThreadId": "p", "relationshipToParent": "subagent"]])
        let parent = thread("p", status: "completed")
        let row = T3ThreadBoard.sections(snap([parent, live] + kids), now: now).flatMap(\.rows).first { $0.id == "p" }
        #expect(row?.children.map(\.id) == ["live", "k1", "k2", "k3"])
        #expect(row?.hiddenFinishedChildren == 2)
    }
}


@Suite struct T3ThreadTimingAndNavigationTests {
    @Test func sidebarElapsedSourcesAndCompatibility() {
        let fallback = now - 9
        let working = thread("working", extra: ["activeRunId": "run-working",
            "activityRunStartedAt": iso(now - 120), "latestRunStartedAt": iso(now - 300),
            "latestRunRequestedAt": iso(now - 400), "latestUserMessageAt": iso(now - 500)])
        #expect(working.elapsedSince(waiting: false, fallback: fallback) == now - 120)
        #expect(working.elapsedSince(waiting: true, fallback: fallback) == fallback)
        let waiting = thread("waiting", status: "completed", extra: [
            "latestRunCompletedAt": iso(now - 1020), "pendingBackgroundTasks": [["taskId": "task", "kind": "subagent"]]])
        let row = T3ThreadBoard.sections(snap([waiting]), now: now, runningSince: ["waiting": fallback])[0].rows[0]
        #expect(row.status == .waiting(since: now - 1020))
        #expect(row.status.detail(now: now) == "17m")
        let legacy = thread("legacy", extra: ["activeRunId": "run-legacy", "latestRunStartedAt": iso(now - 300), "latestRunRequestedAt": iso(now - 400)])
        #expect(legacy.elapsedSince(waiting: false, fallback: fallback) == now - 300)
        let requested = thread("requested", extra: ["activeRunId": "run-requested", "latestRunRequestedAt": iso(now - 400)])
        #expect(requested.elapsedSince(waiting: false, fallback: fallback) == now - 400)
        let mismatched = thread("mismatch", extra: ["activeRunId": "other-run", "latestRunStartedAt": iso(now - 300)])
        #expect(mismatched.elapsedSince(waiting: false, fallback: fallback) == fallback)
        let explicitNull = thread("null", extra: ["activityRunStartedAt": NSNull(), "activeRunId": "run-null", "latestRunStartedAt": iso(now - 300)])
        #expect(explicitNull.elapsedSince(waiting: false, fallback: fallback) == fallback)
        let malformed = thread("bad", extra: ["activityRunStartedAt": "not-a-date", "latestRunCompletedAt": 123])
        #expect(malformed.elapsedSince(waiting: false, fallback: fallback) == fallback)
        #expect(malformed.elapsedSince(waiting: true, fallback: fallback) == fallback)
        #expect(thread("missing").elapsedSince(waiting: false, fallback: fallback) == fallback)
        #expect(thread("missing").elapsedSince(waiting: true, fallback: nil) == nil)
        // Without a shell clock, preserve first-seen rather than using unrelated thread updates.
        #expect(thread("old", status: "completed", updated: now - 60).elapsedSince(waiting: true, fallback: fallback) == fallback)
        #expect(thread("old-null", status: "completed", extra: ["latestRunCompletedAt": NSNull()]).elapsedSince(waiting: true, fallback: fallback) == fallback)
    }

    @Test func childrenUseTheirOwnShellClockAndInlineSummary() throws {
        let parent = thread("parent", status: "completed", extra: ["latestRunCompletedAt": iso(now - 1000)])
        let child = thread("child", extra: ["activityRunStartedAt": iso(now - 240),
            "latestRunCompletedAt": iso(now - 180),
            "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"],
            "modelSelection": ["model": "gpt-6-astra"],
            "pendingBackgroundTasks": (0..<13).map { ["taskId": "task-\($0)", "kind": "command"] }])
        let grandchild = thread("grandchild", extra: ["lineage": ["relationshipToParent": "subagent", "parentThreadId": "child"]])
        let row = try #require(T3ThreadBoard.sections(snap([parent, child, grandchild]), now: now, runningSince: ["child": now - 3]).first?.rows.first?.children.first)
        #expect(row.status == .waiting(since: now - 180))
        #expect(row.subtitle == "gpt-6-astra · 1 subagent running · +14 more")
        let activeChild = thread("active-child", extra: ["activityRunStartedAt": iso(now - 240),
            "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"]])
        let active = try #require(T3ThreadBoard.sections(snap([parent, activeChild]), now: now).first?.rows.first?.children.first)
        #expect(active.status == .running(since: now - 240))
    }

    @Test func compactDurations() {
        for (seconds, label) in [(0, "0s"), (42, "42s"), (59, "59s"), (60, "1m"), (119, "1m"),
                                 (120, "2m"), (1020, "17m"), (3599, "59m"), (3600, "1h 0m"),
                                 (3900, "1h 5m"), (90000, "25h 0m")] {
            #expect(T3ThreadStatus.elapsed(from: now - Double(seconds), to: now) == label)
        }
        #expect(T3ThreadStatus.elapsed(from: now + 10, to: now) == "0s")
    }

    @Test func delegatedAndNativeDestinationsValidateComponents() {
        let lineage = ["relationshipToParent": "subagent", "parentThreadId": "parent"]
        let native = thread("native", extra: ["creationSource": "provider", "lineage": lineage])
        let delegated = thread("thread:delegated-task:sample", extra: ["creationSource": "api", "lineage": lineage])
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", thread: native)?.absoluteString == "t3code://threads/sample-env/parent")
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", thread: delegated)?.absoluteString == "t3code://threads/sample-env/thread:delegated-task:sample")
        #expect(T3CodeLinks.threadURL(environmentID: "bad/env", thread: native) == nil)
        let unsafe = thread("native", extra: ["creationSource": "provider", "lineage": ["relationshipToParent": "subagent", "parentThreadId": "bad?query"]])
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", thread: unsafe) == nil)
        let root = thread("root", extra: ["creationSource": "provider"])
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", thread: root)?.lastPathComponent == "root")
        // Real delegated ids hold percent-escapes and exceed 128 characters: encoded, not refused.
        let long = "thread:delegated-task:command%3Amcp%3A" + String(repeating: "b70866cb-0207-40d9", count: 6)
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", threadID: long)?.absoluteString
                == "t3code://threads/sample-env/" + long.replacingOccurrences(of: "%", with: "%25"))
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", threadID: "a b") == nil)
        #expect(T3CodeLinks.threadURL(environmentID: "sample-env", threadID: "a#b") == nil)
    }
}

@Suite struct AlertSettingsMigrationTests {
    @Test func settingsSavedWithTheRemovedGameAlertStillLoad() throws {
        let saved = #"{"disabled":["hubOffline"],"enabled":["threadFinished","valleyRaid"],"threshold":20}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(saved.utf8))
        #expect(s.disabled == [.hubOffline])
        #expect(s.enabled == [.threadFinished])
        #expect(s.threshold == 20)
        #expect(try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(try JSONDecoder().decode(AlertSettings.self, from: Data("{}".utf8)) == AlertSettings())
    }
}

@Suite struct T3ThreadCardFieldsTests {
    @Test func branchPullRequestAndHandoffDecodeTolerantly() {
        let t = thread("a", instance: "claude_proxy", extra: [
            "branch": "feat/agent-task-runtime", "worktreePath": "/w/feat",
            "linkedPullRequest": ["projectId": "p1", "repository": "o/r", "number": 32, "url": "https://example.invalid/32"],
            "pullRequests": [["repository": "o/r", "number": 32, "snapshot": ["state": "open", "isDraft": false]]],
            "providerInstanceHistory": ["jarvis", "codex_proxy", "claude_proxy", "jarvis"],
        ])
        #expect(t.branch == "feat/agent-task-runtime" && t.worktreePath == "/w/feat")
        #expect(t.pullRequest == T3CodePullRequest(number: 32, state: .open))
        #expect(t.handedOffFrom == ["jarvis", "codex_proxy"])
        // Only a branch PR, a merged state, and malformed values that must not break the thread.
        let merged = thread("b", extra: ["branchPullRequest": ["number": 7], "pullRequests": [["number": 7, "snapshot": ["state": "MERGED"]]]])
        #expect(merged.pullRequest == T3CodePullRequest(number: 7, state: .merged))
        let bad = thread("c", extra: ["branch": 5, "linkedPullRequest": "x", "pullRequests": "y", "providerInstanceHistory": [1]])
        #expect(bad.branch == nil && bad.pullRequest == nil && bad.providerInstanceHistory.isEmpty && bad.title == "Title c")
    }
}
