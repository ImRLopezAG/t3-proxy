import SwiftUI
import AppKit
import T3ProxyCore

/// T3 Code threads: NEEDS YOU / RUNNING / FINISHED in the same glass card style as Accounts.
struct ThreadsTab: View {
    let c: PanelContent
    let openSettings: () -> Void
    @ObservedObject private var model = T3CodeModel.shared()
    @Environment(\.colorScheme) private var s

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let sections = model.snapshot.map { T3ThreadBoard.sections($0, now: now, runningSince: model.runningSince) } ?? []
        let count = sections.reduce(0) { $0 + $1.rows.count }
        VStack(alignment: .leading, spacing: 0) {
            HStack { SectionTitle(text: "Threads"); Spacer(); if model.status.isConnected { Pill(text: "\(count)") } }.padding(.vertical, 8)
            switch model.status {
            case .connected:
                if sections.isEmpty { Note(text: "No threads need you, are running, or finished in the last 24 hours.").padding(.bottom, 8) }
                else { list(sections, now: now) }
            case .notRunning:
                unavailable("T3 Code isn't running", symbol: "moon.zzz", button: "Open T3 Code") { T3CodeModel.open(threadID: nil) }
            case .connecting:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Note(text: "Connecting to T3 Code…") }.padding(.bottom, 10)
            case .notConnected, .expired, .unsupported, .failed:
                unavailable(model.status == .notConnected ? "T3 Code isn't connected" : model.status.text,
                            symbol: "bubble.left.and.text.bubble.right", button: "Connect T3 Code…") {
                    SettingsRouter.shared.pane = .t3code
                    openSettings()
                }
            }
        }
    }

    private func unavailable(_ title: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            Button(button, action: action).buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }

    private func list(_ sections: [T3ThreadSection], now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Text(section.group.rawValue).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, section.group == sections.first?.group ? 0 : 8).padding(.bottom, 2)
                    ForEach(section.rows) { row in
                        HStack(spacing: 6) {
                            if row.hasChildren {
                                Button {
                                    if !model.expandedThreads.insert(row.id).inserted { model.expandedThreads.remove(row.id) }
                                } label: {
                                    Image(systemName: model.expandedThreads.contains(row.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        // The whole left gutter is the target, not just the 9 pt glyph.
                                        .frame(width: 16, height: 34).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(model.expandedThreads.contains(row.id) ? "Hide subagents" : "Show subagents")
                                .accessibilityLabel(model.expandedThreads.contains(row.id) ? "Collapse subagents" : "Expand subagents")
                            }
                            ThreadRowView(row: row, now: now, accounts: c.accounts)
                        }
                        .padding(.leading, row.hasChildren ? 0 : 22)
                        if model.expandedThreads.contains(row.id) {
                            ForEach(row.children) { child in
                                ThreadRowView(row: child, now: now, accounts: c.accounts, isChild: true)
                                    .padding(.leading, 22)
                            }
                            if row.hiddenFinishedChildren > 0 {
                                Text("+\(row.hiddenFinishedChildren) more finished")
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    .padding(.leading, 22).padding(.vertical, 3)
                            }
                            ForEach(Array(row.backgroundTasks.enumerated()), id: \.offset) { _, task in
                                HStack(spacing: 6) {
                                    Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                                    Text(task.displayLabel.safeText).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(task.kind?.safeText ?? "Background task").foregroundStyle(.secondary)
                                }
                                .font(.system(size: 9.5)).padding(.leading, 22).padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { T3CodeModel.open(threadID: task.childThreadId ?? row.id) }
                                .contextMenu {
                                    Button("Open in T3 Code") { T3CodeModel.open(threadID: task.childThreadId ?? row.id) }
                                }
                            }
                        }
                    }
                }
            }
            .overlayScroller()
        }
        .frame(maxHeight: 340).fixedSize(horizontal: false, vertical: true)
    }
}

/// Footer text for the Threads tab ("2 need you · 2 running").
@MainActor func threadsFooter(_ model: T3CodeModel) -> String {
    guard model.status.isConnected, let snap = model.snapshot else { return model.status.text }
    return T3ThreadBoard.footer(T3ThreadBoard.sections(snap, now: Date(), runningSince: model.runningSince))
}

struct ThreadRowView: View {
    let row: T3ThreadRow
    let now: Date
    let accounts: [Account]
    /// Subagent rows show their provider (the project is the parent's); top-level rows show the project icon.
    var isChild = false
    /// Design stills: the project to show (no live snapshot) and no hover sensor (ImageRenderer can't draw it).
    var sampleProject: T3CodeProject? = nil
    var sample = false
    @ObservedObject private var model = T3CodeModel.shared()
    @ObservedObject private var names = T3InstanceNames.shared
    @State private var hover = false
    @Environment(\.colorScheme) private var s

    private var project: T3CodeProject? { sampleProject ?? model.snapshot?.projects.first { $0.id == row.thread.projectId } }

    var body: some View {
        Group { if isChild { compact } else { card } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { T3CodeModel.open(thread: row.thread) }
        .contextMenu {
            Button("Open in T3 Code") { T3CodeModel.open(thread: row.thread) }
            if row.canStop { Button("Stop…", role: .destructive) { confirmStop() } }
            if row.canResume { Button("Resume Now…") { confirmResume() } }
            if let pick = resetAccount { Button("Use Reset & Resume…") { confirmReset(pick) } }
        }
        .disabled(model.actionBusy)
        // Title, project, machine and model · provider beside the panel (a `.help` tooltip only had the title).
        .hoverCard(enabled: !sample) { ThreadHoverCard(row: row, project: project, now: now).id(row.id) }
    }

    /// Subagent row: provider mark, title, model, status.
    private var compact: some View {
        let t = Theme(s)
        return HStack(spacing: 10) {
            providerMark
            VStack(alignment: .leading, spacing: 1) {
                Text(row.thread.title.safeText).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle.safeText).font(.system(size: 9.5)).foregroundStyle(t.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if hover && hasActions { actions } else { status }
        }
        .padding(.vertical, 6)
    }

    /// Top-level row, laid out like T3 Code's sidebar card: project and state, title, then branch and badges.
    private var card: some View {
        let t = Theme(s)
        let branch = row.thread.branch?.safeText
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProjectIconView(project: project, size: 14)
                Text((project?.title ?? row.projectTitle ?? "No project").safeText)
                    .font(.system(size: 11)).foregroundStyle(t.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if hover && hasActions { actions } else { cardState }
            }
            HStack(spacing: 6) {
                Text(row.thread.title.safeText).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if branch == nil { Spacer(minLength: 4); badges }
            }
            if let branch {
                HStack(spacing: 5) {
                    // As in T3 Code: a folder for a worktree branch, plain text for a branch in the project checkout.
                    if row.thread.worktreePath != nil {
                        Image(systemName: "folder").font(.system(size: 9.5)).foregroundStyle(t.secondary).help("Worktree")
                    }
                    Text(branch).font(.system(size: 10.5)).foregroundStyle(t.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    badges
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// "◌ Working 1h 3m" while active, "Needs you", "Limit", or the age of a finished thread ("now", "15h", "1d").
    @ViewBuilder private var cardState: some View {
        switch row.status {
        case .running, .waiting:
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed").font(.system(size: 10, weight: .semibold))
                Text([isRunning ? "Working" : "Waiting", row.status.detail(now: now)].compactMap { $0 }.joined(separator: " "))
                    .monospacedDigit()
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(isRunning ? Color.blue : Color.blue.opacity(0.75))
            .lineLimit(1).fixedSize()
        case .done(let at), .failed(let at):
            Text(shortAge(at ?? row.thread.updatedAt))
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(row.status == .failed(at: at) ? Color.red : Color.secondary)
                .lineLimit(1).fixedSize()
        case .needsYou, .limit:
            status
        }
    }

    private func shortAge(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = max(0, now.timeIntervalSince(d))
        return s < 60 ? "now" : s < 3600 ? "\(Int(s / 60))m" : s < 86400 ? "\(Int(s / 3600))h" : "\(Int(s / 86400))d"
    }

    /// Subagents, the pull request (coloured by state) and the provider with its instance initials.
    private var badges: some View {
        HStack(spacing: 7) {
            if row.runningSubagents > 0 {
                Label("\(row.runningSubagents)", systemImage: "person.2").labelStyle(.titleAndIcon)
                    .font(.system(size: 10)).foregroundStyle(.secondary).help("\(row.runningSubagents) subagents running")
            }
            if let pr = row.thread.pullRequest {
                HStack(spacing: 2) {
                    PullRequestGlyph(size: 11)
                    Text("\(pr.number)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(prColor(pr.state))
                .help("Pull request #\(pr.number)" + (pr.state.map { " · \($0.rawValue)" } ?? ""))
            }
            providerBadge
        }
        .fixedSize()
    }

    private func prColor(_ state: T3CodePullRequest.State?) -> Color {
        switch state {
        case .merged: .purple
        case .closed: .red
        case .draft: .secondary
        case .open, nil: .green
        }
    }

    /// Provider mark (in colour while working) with the instance's initials, like T3 Code's "CP" badge.
    private var providerBadge: some View {
        let name = names.name(row.thread.providerInstanceId ?? row.thread.modelSelection?.instanceId)
        return ZStack(alignment: .bottomTrailing) {
            Group {
                switch row.provider {
                case .claude: ProviderMark(provider: .claude, size: 14)
                case .codex: ProviderMark(provider: .codex, size: 14)
                case .other: Image(systemName: "sparkles").font(.system(size: 11))
                }
            }
            .grayscale(isRunning ? 0 : 1).opacity(isRunning ? 1 : 0.55)
            .frame(width: 18, height: 18, alignment: .topLeading)
            if let name, !T3Display.initials(name).isEmpty {
                Text(T3Display.initials(name)).font(.system(size: 6.5, weight: .bold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 2).padding(.vertical, 0.5)
                    .background(.background.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
        .frame(width: 20, height: 18)
        .help(name.map { "\(T3Display.model(row.thread.modelSelection?.model ?? row.model) ?? "") · \($0)" } ?? "")
    }

    @ViewBuilder private var providerMark: some View {
        switch row.provider {
        case .claude: ProviderMark(provider: .claude, size: 16).frame(width: 18, height: 18)
        case .codex: ProviderMark(provider: .codex, size: 16).frame(width: 18, height: 18)
        case .other: Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18, height: 18)
        }
    }

    /// "project · Opus 5.5 · 2 subagents running"; subagent rows leave out the project they share with the parent.
    private var subtitle: String {
        var parts = [isChild ? nil : row.projectTitle, T3Display.model(row.model) ?? row.model].compactMap { $0?.isEmpty == false ? $0 : nil }
        if row.runningSubagents > 0 { parts.append("\(row.runningSubagents) subagent\(row.runningSubagents == 1 ? "" : "s") running") }
        if let more = row.moreChildrenLabel { parts.append(more) }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch row.status {
        case .needsYou: .orange
        case .running: .green
        case .failed: .red
        case .waiting: .blue.opacity(0.7)
        case .limit, .done: .secondary
        }
    }

    private var status: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(row.status.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            if let d = row.status.detail(now: now) {
                Text(d).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(isRunning ? Color.green : Color.secondary)
            }
        }.lineLimit(1).fixedSize()
    }
    private var isRunning: Bool { if case .running = row.status { true } else { false } }

    private var hasActions: Bool { row.canStop || row.canResume }

    private var actions: some View {
        HStack(spacing: 4) {
            if row.canStop {
                Button("Stop") { confirmStop() }.tint(.red)
            }
            if row.canResume {
                if let pick = resetAccount { Button("Reset & Resume…") { confirmReset(pick) } }
                Button("Resume Now…") { confirmResume() }
            }
        }
        .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 9.5))
    }

    // MARK: Use Reset & Resume

    /// The Codex account whose limit is used up and holds the soonest-expiring banked reset.
    private var resetAccount: Account? {
        guard row.canResume, let live = LiveQuotaModel.primary, live.claiming == nil else { return nil }
        let codex = accounts.filter { $0.provider == .codex && !$0.disabled }
        let candidates = codex.map { a in
            T3ResetCandidate(accountID: a.id,
                             exhausted: QuotaWindowKind.allCases.contains { (a.quota.remaining($0, at: now) ?? 1) <= 0 },
                             creditExpiries: (live.credits[a.id] ?? []).map(\.expiresAt))
        }
        guard let id = T3ResetChoice.pick(for: row.thread, now: now, candidates: candidates) else { return nil }
        return codex.first { $0.id == id }
    }

    // MARK: Confirmations

    /// NSAlert run app-modally: the panel is non-activating, where SwiftUI dialogs may never present.
    private static func confirm(_ title: String, _ info: String, _ button: String, destructive: Bool = false, then: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = info
            let b = alert.addButton(withTitle: button)
            b.hasDestructiveAction = destructive
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            NSApp.activate()
            alert.window.level = .popUpMenu
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { then() }
        }
    }

    private func confirmStop() {
        guard let intent = model.intent(for: row.thread, action: .stop) else { return }
        Self.confirm("Stop “\(row.thread.title.safeText)”?", "Stops the running work in T3 Code, including its delegated tasks.", "Stop", destructive: true) {
            Task {
                guard model.beginAction() else { return }
                defer { model.endAction() }
                await model.stop(intent)
            }
        }
    }

    private func confirmResume() {
        guard let intent = model.intent(for: row.thread, action: .resume) else { return }
        Self.confirm("Resume “\(row.thread.title.safeText)” now?", "Resumes the thread now. If the provider is still at its limit it will stop again.", "Resume Now") {
            Task {
                guard model.beginAction() else { return }
                defer { model.endAction() }
                await model.resume(intent)
            }
        }
    }

    private func confirmReset(_ account: Account) {
        guard let live = LiveQuotaModel.primary, let intent = live.intent(for: account),
              let threadIntent = model.intent(for: row.thread, action: .resume) else { return }
        let name = live.label(for: account)
        let expiry = live.credits[account.id]?.first?.expiresAt.map { " (the one expiring \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
        Self.confirm("Use a reset on “\(name)” and resume?",
                     "Starts the 5-hour and weekly Codex limits on “\(name)” over, then resumes “\(row.thread.title.safeText)”. This spends one banked reset\(expiry) and can't be undone.",
                     "Use Reset & Resume") {
            Task { @MainActor in
                guard model.beginAction() else { return }
                defer { model.endAction() }
                guard model.validate(threadIntent) else { return }
                let result = await live.useReset(intent, requireExhausted: true) { model.validate(threadIntent) }
                guard model.validate(threadIntent) else { return }
                guard T3ResetAndResume.shouldResume(result: result, threadIsValid: true) else {
                    model.notice = "Reset not used, so the thread wasn't resumed"
                    return
                }
                await model.resume(threadIntent)
            }
        }
    }
}

private extension String {
    /// Thread titles and task descriptions are free text from agents: hide emails and credential-shaped strings.
    var safeText: String { LogRedactor.redact(self, secrets: []) }
}
