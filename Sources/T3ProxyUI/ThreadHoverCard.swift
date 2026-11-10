import AppKit
import SwiftUI
import T3ProxyCore

/// Provider instance names ("Claude Proxy") from T3 Code's settings.json, read-only and only that field.
@MainActor
final class T3InstanceNames: ObservableObject {
    static let shared = T3InstanceNames()
    @Published private var names: [String: String] = [:]
    private var loadedAt: Date?
    private var loading = false

    func name(_ id: String?) -> String? {
        refreshIfStale()
        guard let id else { return nil }
        return names[id]
    }

    private func refreshIfStale() {
        guard !loading, loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        loading = true
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [String: String] in
                let paths = T3CodePaths()
                guard let data = FileManager.default.contents(atPath: paths.settings), data.count < 4 << 20,
                      let s = T3CodeSettings.parse(data, home: paths.home) else { return [:] }
                return Dictionary(s.instances.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            }.value
            names = loaded; loadedAt = Date(); loading = false
        }
    }
}

enum T3Display {
    /// "claude-opus-5-5" → "Opus 5.5", "gpt-6.1-sol" → "GPT-6.1 Sol", unknown shapes unchanged.
    static func model(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" {
            parts.removeFirst()
            guard let family = parts.first else { return id }
            let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return family.capitalized + (version.isEmpty ? "" : " \(version)")
        }
        if parts.first == "gpt", parts.count >= 2 {
            return "GPT-" + parts[1] + parts.dropFirst(2).map { " " + $0.capitalized }.joined()
        }
        return id
    }

    /// The Mac's name ("Angel's MacBook Pro"), as T3 Code labels the local environment.
    static let machine: String = Host.current().localizedName ?? "This Mac"

    /// T3 Code's badge text for a provider instance: initials of its name ("Claude Proxy" → "CP").
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(words.first?.prefix(2) ?? "")
        return String(letters).uppercased()
    }
}

/// The card beside the panel for one thread: title, project, machine, model and provider, state.
struct ThreadHoverCard: View {
    let row: T3ThreadRow
    let project: T3CodeProject?
    let now: Date
    /// Observed so the provider name appears once settings.json has been read.
    @ObservedObject private var names = T3InstanceNames.shared

    var body: some View {
        let instanceName = names.name(row.thread.providerInstanceId ?? row.thread.modelSelection?.instanceId)
        VStack(alignment: .leading, spacing: 9) {
            Text(row.thread.title.cardSafe).font(.system(size: 12.5, weight: .semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                line { ProjectIconView(project: project, size: 14) } text: { Text((project?.title ?? row.projectTitle ?? "Project").cardSafe) }
                line { Image(systemName: "laptopcomputer") } text: { Text(T3Display.machine) }
                if let branch = row.thread.branch {
                    line { Image(systemName: "arrow.triangle.branch") } text: {
                        Text(branch.cardSafe + (row.thread.worktreePath != nil ? " · worktree" : ""))
                    }
                }
                if let pr = row.thread.pullRequest {
                    line { PullRequestGlyph(size: 11) } text: {
                        Text("Pull request #\(pr.number)" + (pr.state.map { " · \($0.rawValue)" } ?? ""))
                    }
                }
                if let model = T3Display.model(row.thread.modelSelection?.model ?? row.model) {
                    line { providerGlyph } text: {
                        Text(instanceName.map { "\(model) · \($0)" } ?? model)
                    }
                }
                let handoff = row.thread.handedOffFrom.map { names.name($0) ?? $0 }
                if !handoff.isEmpty {
                    line { Image(systemName: "arrow.left.arrow.right") } text: { Text("Handed off from " + handoff.joined(separator: ", ")) }
                }
                line { Circle().fill(statusColor).frame(width: 7, height: 7) } text: {
                    Text([row.status.label, row.status.detail(now: now)].compactMap { $0 }.joined(separator: " · "))
                }
                if row.runningSubagents > 0 {
                    line { Image(systemName: "person.2") } text: {
                        Text("\(row.runningSubagents) subagent\(row.runningSubagents == 1 ? "" : "s") running")
                    }
                }
                if !row.backgroundTasks.isEmpty {
                    line { Image(systemName: "gearshape.2") } text: {
                        Text("\(row.backgroundTasks.count) background task\(row.backgroundTasks.count == 1 ? "" : "s")")
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.8))
        }
    }

    @ViewBuilder private var providerGlyph: some View {
        switch row.provider {
        case .claude: ProviderMark(provider: .claude, size: 13).grayscale(1).opacity(0.75)
        case .codex: ProviderMark(provider: .codex, size: 13).opacity(0.75)
        case .other: Image(systemName: "sparkles")
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .needsYou: .orange
        case .running: .green
        case .failed: .red
        case .waiting: .blue
        case .limit, .done: .secondary
        }
    }

    private func line<I: View, T: View>(@ViewBuilder _ icon: () -> I, @ViewBuilder text: () -> T) -> some View {
        HStack(spacing: 8) {
            icon().font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16, alignment: .center)
            text().lineLimit(1).truncationMode(.tail)
        }
    }
}

private extension String {
    /// Thread and project titles are free text: hide emails and credential-shaped strings.
    var cardSafe: String { LogRedactor.redact(self, secrets: []) }
}

/// The git pull-request glyph T3 Code uses (Lucide's), drawn as a stroke so it stays crisp at 10–12 pt.
struct PullRequestGlyph: View {
    var size: CGFloat = 11
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            var path = Path()
            path.addEllipse(in: CGRect(x: 3.5 * k, y: 3.5 * k, width: 5 * k, height: 5 * k))      // top-left dot
            path.move(to: p(6, 8.5)); path.addLine(to: p(6, 21))                                    // stem
            path.addEllipse(in: CGRect(x: 15.5 * k, y: 15.5 * k, width: 5 * k, height: 5 * k))    // bottom-right dot
            path.move(to: p(18, 15.5)); path.addLine(to: p(18, 9))
            path.addQuadCurve(to: p(15, 6), control: p(18, 6))
            path.addLine(to: p(11, 6))                                                              // into the head
            path.move(to: p(13.5, 3.5)); path.addLine(to: p(11, 6)); path.addLine(to: p(13.5, 8.5))
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2.1 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
