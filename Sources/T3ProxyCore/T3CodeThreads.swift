import Foundation

// Pure presentation logic for the menu-bar "Threads" tab, the limit-resume choice and T3 Code
// notifications. Nothing here talks to the server; the UI feeds it snapshots.

public enum T3ThreadProvider: Sendable, Equatable {
    case claude, codex, other

    /// `claudeAgent` / `claude_proxy` → Claude; `codex` / `codex_proxy` → Codex. Anything else is generic.
    public init(instanceID: String?) {
        let id = (instanceID ?? "").lowercased()
        if id.hasPrefix("claude") { self = .claude }
        else if id.hasPrefix("codex") { self = .codex }
        else { self = .other }
    }
}

extension T3CodeThread {
    /// Mirrors sidebar Working/Waiting clocks; first-seen is only for shells without a usable clock.
    public func elapsedSince(waiting: Bool, fallback: Date?) -> Date? {
        if waiting { return latestRunCompletedAt ?? fallback }
        if hasActivityRunStartedAt { return activityRunStartedAt ?? fallback }
        if let latestRunId, latestRunId == activeRunId, latestRunCompletedAt == nil {
            return latestRunStartedAt ?? latestRunRequestedAt ?? fallback
        }
        return fallback
    }
    /// Settlement wins over stale run, request and child-work summaries.
    var isVisibleOnThreadBoard: Bool { !isSettled && archivedAt == nil && deletedAt == nil }

    public var providerKind: T3ThreadProvider {
        T3ThreadProvider(instanceID: providerInstanceId ?? modelSelection?.instanceId ?? modelSelection?.provider)
    }
    /// Stopped by a provider usage limit (failed `usage_limit` run, or snoozed until the reset).
    public func isLimitStopped(at now: Date) -> Bool { isUsageLimited || isSnoozedByUsageLimit(at: now) }
    /// The thread's own reset time; never derived from T3 Proxy's pooled quota.
    public var limitResetAt: Date? { usageLimitResetAt ?? limitRecovery?.resetAt }
}

public enum T3ThreadGroup: String, Sendable, CaseIterable { case needsYou = "NEEDS YOU", running = "RUNNING", finished = "FINISHED" }

public enum T3ThreadStatus: Sendable, Equatable {
    case needsYou(kind: String, since: Date?)
    case running(since: Date?)
    case waiting(since: Date?)
    case limit(resumesAt: Date?, autoResume: Bool = false)
    case done(at: Date?)
    case failed(at: Date?)

    /// The primary status word shown on the right of the row.
    public var label: String {
        switch self {
        case .needsYou(let kind, _): kind
        case .running: "Running"
        case .waiting: "Waiting"
        case .limit: "Limit"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// The secondary detail: age, elapsed time, resume time, or relative finish time.
    public func detail(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch self {
        case .needsYou(_, let since): since.map { T3ThreadStatus.age(from: $0, to: now) }
        case .running(let since), .waiting(let since): since.map { T3ThreadStatus.elapsed(from: $0, to: now) }
        case .limit(let at, let autoResume):
            at.map { d in
                let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
                f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, inSameDayAs: now) ? "jmm" : "EEEjmm")
                return "\(autoResume ? "resumes" : "limit resets") \(f.string(from: d))"
            }
        case .done(let at), .failed(let at): at.map { now.timeIntervalSince($0) < 60 ? "just now" : T3ThreadStatus.age(from: $0, to: now) + " ago" }
        }
    }

    /// "just now", "4m", "2h", "3d".
    static func age(from: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
    /// Sidebar format: "42s", "17m", "1h 5m".
    static func elapsed(from: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }

    /// Approval / Question / Plan / Message from the pending request summary.
    static func needsKind(_ t: T3CodeThread) -> String {
        if let r = t.pendingRuntimeRequest {
            switch r.kind {
            case "user_input", "mcp-elicitation": return "Question"
            default: return "Approval"
            }
        }
        if t.hasActionableProposedPlan == true { return "Plan" }
        return "Message"
    }
}

public struct T3ThreadRow: Sendable, Equatable, Identifiable {
    public var id: String { thread.id }
    public let thread: T3CodeThread
    public let group: T3ThreadGroup
    public let status: T3ThreadStatus
    public let projectTitle: String?
    public let model: String?
    public let runningSubagents: Int
    public var children: [T3ThreadRow] = []
    public var backgroundTasks: [T3CodeBackgroundTask] = []
    public var moreChildren: Int = 0
    /// Finished children left out of `children` (only the most recent few are listed).
    public var hiddenFinishedChildren: Int = 0
    public static let finishedChildLimit = 3
    public var moreChildrenLabel: String? { moreChildren > 0 ? "+\(moreChildren) more" : nil }
    public var hasChildren: Bool { !children.isEmpty || !backgroundTasks.isEmpty }
    public var provider: T3ThreadProvider { thread.providerKind }
    /// "project title · model · N subagents running".
    public var subtitle: String {
        var parts = [projectTitle, model].compactMap { $0?.isEmpty == false ? $0 : nil }
        if runningSubagents > 0 { parts.append("\(runningSubagents) subagent\(runningSubagents == 1 ? "" : "s") running") }
        if let moreChildrenLabel { parts.append(moreChildrenLabel) }
        return parts.joined(separator: " · ")
    }
    public var canStop: Bool { thread.activeRunId != nil && (thread.attention == .running || thread.attention == .waiting) }
    public var canResume: Bool { if case .limit = status { return thread.isUsageLimited && thread.activeRunId == nil } else { return false } }
}

public struct T3ThreadSection: Sendable, Equatable, Identifiable {
    public var id: T3ThreadGroup { group }
    public let group: T3ThreadGroup
    public let rows: [T3ThreadRow]
}

/// Only work children participate: ordinary forks and side chats remain independent.
struct T3ThreadFamily {
    var children: [String: [T3CodeThread]] = [:]
    var childIDs: Set<String> = []
    init(_ snapshot: T3CodeSnapshot) {
        let threads = snapshot.threads.filter(\.isVisibleOnThreadBoard)
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for parent in threads {
            let linked = Set((parent.pendingBackgroundTasks ?? []).compactMap(\.childThreadId))
            for id in linked where id != parent.id {
                if let child = byID[id] { children[parent.id, default: []].append(child); childIDs.insert(id) }
            }
        }
        for child in threads where child.lineage?.relationshipToParent == "subagent" {
            guard let parent = child.lineage?.parentThreadId, parent != child.id, byID[parent] != nil else { continue }
            if !children[parent, default: []].contains(where: { $0.id == child.id }) { children[parent, default: []].append(child) }
            childIDs.insert(child.id)
        }
        // A cycle (A lists B and B lists A) would make every member a child and hide the whole family.
        // Break each cycle at its smallest id, which stays visible as the root.
        var parentOf: [String: String] = [:]
        for (parent, kids) in children.sorted(by: { $0.key < $1.key }) { for k in kids where parentOf[k.id] == nil { parentOf[k.id] = parent } }
        for start in childIDs.sorted() where childIDs.contains(start) {
            var path: [String] = [], at: String? = start
            while let id = at, childIDs.contains(id), !path.contains(id) { path.append(id); at = parentOf[id] }
            guard let loopAt = at, let i = path.firstIndex(of: loopAt) else { continue }
            let root = path[i...].min()!
            childIDs.remove(root)
            if let p = parentOf[root] { children[p]?.removeAll { $0.id == root } }
            parentOf[root] = nil
        }
        for id in Array(children.keys) { children[id]?.sort { $0.id < $1.id } }
    }
    func attention(_ thread: T3CodeThread, visited: Set<String> = []) -> T3CodeAttention {
        guard !visited.contains(thread.id) else { return thread.attention }
        var visited = visited; visited.insert(thread.id)
        let states = children[thread.id, default: []].map { attention($0, visited: visited) }
        if thread.attention == .needsYou || states.contains(.needsYou) { return .needsYou }
        if states.contains(.running) || states.contains(.waiting) { return .waiting }
        return thread.attention
    }
    func row(_ thread: T3CodeThread, group: T3ThreadGroup, status: T3ThreadStatus, projects: [String: String]) -> T3ThreadRow {
        let children = children[thread.id, default: []]
        let mapped = Set(children.map(\.id))
        let tasks = (thread.pendingBackgroundTasks ?? []).filter { $0.childThreadId.map { !mapped.contains($0) } ?? true }
        let active = children.filter { [.running, .waiting, .needsYou].contains(attention($0)) }.count
        let missing = tasks.filter { $0.kind == "subagent" }.count
        return T3ThreadRow(thread: thread, group: group, status: status, projectTitle: projects[thread.projectId],
                           model: thread.modelSelection?.model, runningSubagents: active + missing, backgroundTasks: tasks)
    }
}

public enum T3ThreadBoard {
    public static let finishedWindow: TimeInterval = 24 * 3600
    public static let finishedLimit = 5

    /// Groups top-level listed threads into NEEDS YOU / RUNNING / FINISHED, omitting empty groups.
    /// Limit-stopped threads appear first under FINISHED and aren't subject to the 24 h / 5-row cap.
    /// `runningSince` is a first-seen fallback for shells without usable run timestamps.
    public static func sections(_ snapshot: T3CodeSnapshot, now: Date, runningSince: [String: Date] = [:]) -> [T3ThreadSection] {
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let family = T3ThreadFamily(snapshot)
        var needs: [T3ThreadRow] = [], running: [T3ThreadRow] = [], limited: [T3ThreadRow] = [], finished: [T3ThreadRow] = []
        for t in snapshot.threads where t.isListed && !family.childIDs.contains(t.id) && t.isVisibleOnThreadBoard {
            func row(_ g: T3ThreadGroup, _ s: T3ThreadStatus) -> T3ThreadRow {
                var result = family.row(t, group: g, status: s, projects: projects)
                let all = family.children[t.id, default: []].map { child in
                    let attention = family.attention(child)
                    let group: T3ThreadGroup = attention == .needsYou ? .needsYou : [.running, .waiting].contains(attention) ? .running : .finished
                    let status: T3ThreadStatus
                    switch attention {
                    case .needsYou: status = .needsYou(kind: "Needs you", since: child.pendingRuntimeRequest?.createdAt ?? child.updatedAt)
                    case .running: status = .running(since: child.elapsedSince(waiting: false, fallback: runningSince[child.id]))
                    case .waiting: status = .waiting(since: child.elapsedSince(waiting: true, fallback: runningSince[child.id]))
                    default: status = child.status == .failed ? .failed(at: child.updatedAt) : .done(at: child.updatedAt)
                    }
                    var row = family.row(child, group: group, status: status, projects: [:])
                    row.moreChildren = family.children[child.id, default: []].count + row.backgroundTasks.count
                    return row
                }
                // Active children first (needs you, running, waiting), then the most recent finished ones.
                func rank(_ r: T3ThreadRow) -> Int { switch r.status { case .needsYou: 0; case .running: 1; case .waiting: 2; default: 3 } }
                let active = all.filter { rank($0) < 3 }.sorted { (rank($0), $0.thread.title) < (rank($1), $1.thread.title) }
                let done = all.filter { rank($0) == 3 }.sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
                result.children = active + done.prefix(T3ThreadRow.finishedChildLimit)
                result.hiddenFinishedChildren = max(0, done.count - T3ThreadRow.finishedChildLimit)
                return result
            }
            switch family.attention(t) {
            case .needsYou:
                needs.append(row(.needsYou, .needsYou(kind: family.attention(t) == t.attention ? T3ThreadStatus.needsKind(t) : "Needs you", since: t.pendingRuntimeRequest?.createdAt ?? t.updatedAt)))
            case .waiting:
                running.append(row(.running, .waiting(since: t.elapsedSince(waiting: true, fallback: runningSince[t.id]))))
            case .running:
                running.append(row(.running, .running(since: t.elapsedSince(waiting: false, fallback: runningSince[t.id]))))
            case .finished where t.isLimitStopped(at: now):
                limited.append(row(.finished, .limit(resumesAt: t.limitResetAt,
                    autoResume: t.limitRecovery.map { $0.autoResume && $0.runId == t.latestRunId } ?? false)))
            case .finished:
                guard t.status == .completed || t.status == .failed,
                      let at = t.updatedAt, now.timeIntervalSince(at) <= finishedWindow else { continue }
                finished.append(row(.finished, t.status == .completed ? .done(at: at) : .failed(at: at)))
            case .idle, .unknown: continue
            }
        }
        func newest(_ a: T3ThreadRow, _ b: T3ThreadRow) -> Bool {
            let x = a.thread.updatedAt ?? .distantPast, y = b.thread.updatedAt ?? .distantPast
            return x == y ? a.id < b.id : x > y
        }
        needs.sort(by: newest); running.sort(by: newest); limited.sort(by: newest); finished.sort(by: newest)
        let done = limited + finished.prefix(finishedLimit)
        return [T3ThreadSection(group: .needsYou, rows: needs), T3ThreadSection(group: .running, rows: running),
                T3ThreadSection(group: .finished, rows: done)].filter { !$0.rows.isEmpty }
    }

    /// "2 need you · 2 running"; "No active threads" when both are zero.
    public static func footer(_ sections: [T3ThreadSection]) -> String {
        let n = sections.first { $0.group == .needsYou }?.rows.count ?? 0
        let active = sections.first { $0.group == .running }?.rows ?? []
        let w = active.filter { if case .waiting = $0.status { true } else { false } }.count
        let r = active.count - w
        if n == 0 && r == 0 && w == 0 { return "No active threads" }
        var parts: [String] = []
        if n > 0 { parts.append("\(n) need\(n == 1 ? "s" : "") you") }
        if r > 0 { parts.append("\(r) running") }
        if w > 0 { parts.append("\(w) waiting") }
        return parts.joined(separator: " · ")
    }

    /// Whether the menu-bar icon shows its attention dot.
    public static func needsAttention(_ snapshot: T3CodeSnapshot?) -> Bool {
        guard let snapshot else { return false }
        let family = T3ThreadFamily(snapshot)
        return snapshot.threads.contains { $0.isListed && $0.isVisibleOnThreadBoard && family.attention($0) == .needsYou }
    }
}

// MARK: - Deep link

public enum T3CodeLinks {
    /// Native provider work is inspected from its parent; delegated app-owned work has its own route.
    public static func threadURL(environmentID: String, thread: T3CodeThread) -> URL? {
        let native = thread.creationSource == "provider" && thread.lineage?.relationshipToParent == "subagent"
        let destination = native ? thread.lineage?.parentThreadId ?? thread.id : thread.id
        return threadURL(environmentID: environmentID, threadID: destination)
    }
    /// `t3code://threads/<environmentId>/<threadId>`, the desktop app's thread route (promptLinks.ts).
    /// Identifiers are restricted to URL-safe characters; anything else yields nil.
    public static func threadURL(environmentID: String, threadID: String, scheme: String = "t3code") -> URL? {
        func plain(_ s: Unicode.Scalar) -> Bool { s.isASCII && CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_" || s == ":" }
        // Delegated-task ids carry percent-escapes ("thread:delegated-task:command%3A…") and run past 128 characters.
        // T3 Code percent-decodes the path segment, so "%" is sent as "%25"; anything that could change the route
        // ("/", "?", "#", spaces, non-ASCII) is refused.
        func safeID(_ s: String) -> Bool { !s.isEmpty && s.count <= 512 && s.unicodeScalars.allSatisfy { plain($0) || $0 == "%" || $0 == "." } }
        guard !environmentID.isEmpty, environmentID.count <= 128, environmentID.unicodeScalars.allSatisfy(plain), safeID(threadID) else { return nil }
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:.")
        allowed.remove("%")
        guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://threads/\(environmentID)/\(encoded)")
    }

    /// Reads `~/.t3/userdata/environment-id` (a nonsecret UUID).
    public static func environmentID(paths: T3CodePaths = T3CodePaths()) -> String? {
        let path = (paths.userdata as NSString).appendingPathComponent("environment-id")
        guard let data = FileManager.default.contents(atPath: path), data.count < 256,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return threadURL(environmentID: s, threadID: "x") == nil ? nil : s
    }
}

// MARK: - Use Reset & Resume

/// One Codex account as seen for "Use Reset & Resume".
public struct T3ResetCandidate: Sendable, Equatable {
    public let accountID: String
    /// The 5-hour or weekly limit is used up (0% left).
    public let exhausted: Bool
    /// Banked reset expiry times, nil for credits without an expiry.
    public let creditExpiries: [Date?]
    public init(accountID: String, exhausted: Bool, creditExpiries: [Date?]) {
        self.accountID = accountID; self.exhausted = exhausted; self.creditExpiries = creditExpiries
    }
}

public enum T3ResetChoice {
    /// Only for a Codex thread stopped by a limit. Among exhausted accounts with banked resets,
    /// the one whose soonest credit expires first (credits without an expiry sort last; ties by id).
    public static func pick(for thread: T3CodeThread, now: Date, candidates: [T3ResetCandidate]) -> String? {
        guard thread.providerKind == .codex, thread.isLimitStopped(at: now) else { return nil }
        return pick(candidates)
    }
    public static func pick(_ candidates: [T3ResetCandidate]) -> String? {
        let ok = candidates.filter { $0.exhausted && !$0.creditExpiries.isEmpty }
        func soonest(_ c: T3ResetCandidate) -> Date { c.creditExpiries.map { $0 ?? .distantFuture }.min() ?? .distantFuture }
        return ok.min { a, b in
            let x = soonest(a), y = soonest(b)
            return x == y ? a.accountID < b.accountID : x < y
        }?.accountID
    }
}

// MARK: - Notifications

/// In-memory transition memory. The first snapshot seeds it without alerting.
public struct T3ThreadAlertState: Sendable, Equatable {
    public var seeded = false
    /// Thread id → last state key ("needs|<request>", "running", "done|<run>", …).
    public var last: [String: String] = [:]
    /// Thread id → state keys already notified (or seeded), so flapping doesn't re-post.
    public var fired: [String: Set<String>] = [:]
    static let historyCap = 2000
    public init() {}
}

public enum T3ThreadAlertRules {
    static func key(_ t: T3CodeThread, family: T3ThreadFamily, now: Date) -> (key: String, kind: AlertKind?) {
        let run = t.latestRunId ?? "-"
        switch family.attention(t) {
        case .needsYou:
            let what = t.pendingRuntimeRequest?.id ?? (t.hasActionableProposedPlan == true ? "plan|\(run)" : "message|\(run)")
            return ("needs|\(what)", .threadNeedsYou)
        case .running: return ("running", nil)
        case .waiting: return ("waiting", nil)
        case .finished where t.isLimitStopped(at: now): return ("limit|\(run)", .threadLimited)
        case .finished where t.status == .completed: return ("done|\(run)", .threadFinished)
        case .finished where t.status == .failed: return ("failed|\(run)", .threadFailed)
        default: return ("other|\(t.status.rawValue)", nil)
        }
    }

    /// Posts once per thread and state transition. Content is the thread title and project only.
    public static func evaluate(_ previous: T3ThreadAlertState, _ snapshot: T3CodeSnapshot, settings: AlertSettings, now: Date) -> (alerts: [Alert], state: T3ThreadAlertState) {
        var state = previous
        var out: [Alert] = []
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let family = T3ThreadFamily(snapshot)
        var seen: [String: String] = [:]
        for t in snapshot.threads where t.isListed && !family.childIDs.contains(t.id) && t.isVisibleOnThreadBoard {
            let (k, kind) = key(t, family: family, now: now)
            seen[t.id] = k
            let id = "t3|\(t.id)|\(k)"
            let already = state.fired[t.id]?.contains(k) ?? false
            // A thread this app hasn't seen before (first snapshot, or one that was missing from a partial
            // snapshot) is recorded quietly: its finished/failed/limit state is history, not news. Only a
            // thread that needs the user is announced on first sight.
            let firstSight = state.last[t.id] == nil
            guard state.seeded, state.last[t.id] != k, let kind, !already, !firstSight || kind == .threadNeedsYou else {
                if kind != nil, !state.seeded || firstSight { state.fired[t.id, default: []].insert(k) }
                continue
            }
            state.fired[t.id, default: []].insert(k)
            guard settings.isOn(kind) else { continue }
            let project = projects[t.projectId]
            let phrase: String = switch kind {
            case .threadNeedsYou: "Needs you"
            case .threadFinished: "Finished"
            case .threadFailed: "Failed"
            default: "Stopped by a usage limit"
            }
            out.append(Alert(kind: kind, id: id, title: t.title,
                             body: [project, phrase].compactMap { $0 }.joined(separator: " · "), threadID: t.id))
        }
        // Keep history for threads missing from this snapshot (a reconnect or partial snapshot must not make
        // old states look new), bounded: past the cap, only threads still present are kept.
        state.last.merge(seen) { _, new in new }
        state.seeded = true
        if state.last.count > T3ThreadAlertState.historyCap {
            state.last = state.last.filter { seen[$0.key] != nil }
            state.fired = state.fired.filter { seen[$0.key] != nil }
        }
        return (out, state)
    }
}

extension T3CodeSnapshot {
    /// Design stills only (rendered under the SAMPLE banner): four projects and threads in different states.
    public static func sample(now: Date) -> T3CodeSnapshot {
        func iso(_ ago: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago)) }
        let projects: [[String: Any]] = [
            ["id": "p1", "title": "T3 Proxy"], ["id": "p2", "title": "orchestrator"],
            ["id": "p3", "title": "accord", "projectIcon": ["kind": "lucide", "name": "sparkles", "color": "violet"]],
            ["id": "p4", "title": "rosa"],
        ]
        func t(_ id: String, _ title: String, _ p: String, _ status: String, _ inst: String, _ model: String, ago: TimeInterval,
               extra: [String: Any] = [:]) -> [String: Any] {
            var o: [String: Any] = ["id": id, "title": title, "projectId": p, "status": status, "providerInstanceId": inst,
                                    "modelSelection": ["instanceId": inst, "model": model], "latestRunId": "r-\(id)",
                                    "updatedAt": iso(ago), "latestRunCompletedAt": iso(ago)]
            if status == "running" { o["activeRunId"] = "r-\(id)"; o["activityRunStatus"] = "running"; o["activityRunStartedAt"] = iso(3780) }
            extra.forEach { o[$0.key] = $0.value }
            return o
        }
        let threads: [[String: Any]] = [
            t("a", "Continue enrollment intake in Local checkout", "p3", "running", "codex_proxy", "gpt-6.1-sol", ago: 10,
              extra: ["branch": "feat/enrollment-intake", "worktreePath": "/w", "linkedPullRequest": ["number": 32],
                      "pullRequests": [["number": 32, "snapshot": ["state": "open", "isDraft": false]]],
                      "providerInstanceHistory": ["claude_proxy", "codex_proxy"]]),
            t("b", "Build T3 Proxy macOS app", "p1", "completed", "claude_proxy", "claude-opus-5-5", ago: 20),
            t("c", "Orchestrator: generic durable task runtime", "p2", "completed", "claude_proxy", "claude-opus-5-5", ago: 15 * 3600,
              extra: ["branch": "feat/agent-task-runtime", "worktreePath": "/w2"]),
            t("d", "rosa v2: plan and build", "p4", "completed", "claude_proxy", "claude-opus-5-5", ago: 26 * 3600,
              extra: ["branch": "main", "linkedPullRequest": ["number": 18], "pullRequests": [["number": 18, "snapshot": ["state": "merged"]]]]),
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["p": projects, "t": threads])
        struct Box: Decodable { let p: [T3CodeProject]; let t: [T3CodeThread] }
        let box = try! T3CodeWire.decode(Box.self, from: data)
        return T3CodeSnapshot(sequence: 1, projects: box.p, threads: box.t, archivedThreads: [])
    }
}
