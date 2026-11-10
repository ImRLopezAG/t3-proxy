import SwiftUI
import T3ProxyCore

/// Hub log viewer. Every line arrives already redacted and capped by ManagementClient.
struct LogsPane: View {
    @ObservedObject var monitor: Monitor
    @State private var lines: [LogLine] = []
    @State private var cursor: String?
    @State private var enabled = true
    @State private var level: LogLine.Level?
    @State private var query = ""
    @State private var autoRefresh = false
    @State private var files: [LogFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var requestID = ""
    @State private var viewing: LogText?
    @State private var confirmClear = false
    @State private var hideManagement = false
    @State private var shown: [LogLine] = []
    @State private var selection: Set<LogLine.ID> = []
    @State private var sortOrder = [KeyPathComparator(\LogLine.seq, order: .reverse)]
    @State private var nextSeq = 0
    @State private var fileSelection: Set<String> = []
    @State private var fileSort = [KeyPathComparator(\ErrorRow.modifiedKey, order: .reverse)]

    private static let page = 500
    private static let poll: Duration = .seconds(5)
    private var locked: Bool { monitor.management == .rejected || !monitor.hasKey }

    var body: some View {
        Group {
            if locked { LockedView(monitor: monitor, what: "the hub's logs") } else { content }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem { Toggle(isOn: $autoRefresh) { Label("Auto-Refresh", systemImage: "timer") }.disabled(locked || !enabled) }
            ToolbarItem {
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }.disabled(loading || locked)
            }
            ToolbarItem {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear Logs…", systemImage: "trash") }
                    .disabled(locked || !enabled)
                    .help(enabled ? "Delete the hub's log files" : "The hub only clears logs while file logging is on.")
            }
        }
        .task(id: monitor.management) { await reload() }
        .task(id: autoRefresh) {
            while autoRefresh, !Task.isCancelled {
                try? await Task.sleep(for: Self.poll)
                if autoRefresh, !locked, enabled { await readTail(poll: true) }
            }
        }
        .confirmationDialog("Clear all logs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the hub's log files on disk\(files.isEmpty ? "" : ", including \(files.count) error log\(files.count == 1 ? "" : "s")"). It can't be undone. Request logs that are deleted can no longer be opened by id.")
        }
        .sheet(item: Binding(get: { viewing.map(Viewed.init) }, set: { if $0 == nil { viewing = nil } })) { v in
            LogTextSheet(log: v.log) { viewing = nil }
        }
    }

    private var content: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Level", selection: $level) {
                        Text("All").tag(LogLine.Level?.none)
                        ForEach([LogLine.Level.error, .warn, .info, .debug], id: \.self) { l in
                            Text("\(l.rawValue.capitalized) (\(lines.count { $0.level == l }))").tag(Optional(l))
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Toggle("Hide management API calls", isOn: $hideManagement)
                        .toggleStyle(.checkbox).fixedSize()
                        .help("Hide access entries for /v0/management and /v8/management, including this app's own polling")
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                }
                .padding(8)
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.horizontal, 8) }
                if let notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.horizontal, 8) }
                if !enabled {
                    ContentUnavailableView {
                        Label("File logging is off on the hub", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("The hub only keeps a readable log when logging-to-file is on. Turn it on in Config to tail the log here. Error logs below are written either way.")
                    }
                } else if lines.isEmpty {
                    ContentUnavailableView(loading ? "Loading…" : "No Log Lines", systemImage: "text.alignleft")
                } else {
                    logTable
                }
            }
            .frame(minHeight: 220)
            errorSection.frame(minHeight: 140)
        }
        .onChange(of: lines) { refilter() }
        .onChange(of: level) { refilter() }
        .onChange(of: query) { refilter() }
        .onChange(of: hideManagement) { refilter() }
        .onChange(of: sortOrder) { refilter() }
    }

    private var logTable: some View {
        Table(of: LogLine.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.seq) { l in Text(l.time ?? "").monospacedDigit().help(l.time ?? "") }
                .width(min: 120, ideal: 140, max: 200)
            TableColumn("Level", value: \.levelRank) { l in LevelBadge(level: l.level) }
                .width(min: 50, ideal: 64, max: 90)
            TableColumn("Request", value: \.requestKey) { l in Text(l.requestID ?? "").monospaced().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80, max: 160)
            TableColumn("Source", value: \.sourceKey) { l in Text(l.source ?? "").foregroundStyle(.secondary).truncationMode(.middle).help(l.source ?? "") }
                .width(min: 70, ideal: 130, max: 240)
            TableColumn("Status", value: \.statusKey) { l in
                if let s = l.access?.status { Text(String(s)).monospacedDigit().foregroundStyle(statusColor(s)) }
            }
            .width(min: 40, ideal: 50, max: 70)
            TableColumn("Latency", value: \.latencyKey) { l in Text(l.access?.latency ?? "").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 70, max: 110)
            TableColumn("Method", value: \.methodKey) { l in Text(l.access?.method ?? "").monospaced() }
                .width(min: 44, ideal: 60, max: 90)
            TableColumn("Path / Message", value: \.detail) { l in
                Text(l.detail).monospaced().lineLimit(1).truncationMode(.middle).help(l.raw)
            }
        } rows: {
            ForEach(shown) { TableRow($0) }
        }
        .font(.system(.callout))
        .contextMenu(forSelectionType: LogLine.ID.self) { ids in
            let picked = shown.filter { ids.contains($0.id) }
            Button(picked.count > 1 ? "Copy \(picked.count) Lines" : "Copy Line") { copy(picked.map(\.raw).joined(separator: "\n")) }
                .disabled(picked.isEmpty)
            if picked.count == 1, let id = picked.first?.requestID {
                Button("Open Request Log") { openRequest(id) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = shown.first(where: { ids.contains($0.id) })?.requestID { openRequest(id) }
        }
        .onChange(of: selection) {
            if selection.count == 1, let id = shown.first(where: { selection.contains($0.id) })?.requestID { requestID = id }
        }
    }

    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Error Logs").font(.headline)
                Spacer()
                TextField("Request id", text: $requestID).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { openRequest(requestID) }
                Button("Open Request Log") { openRequest(requestID) }
                    .disabled(!LogLimits.isRequestID(requestID.trimmingCharacters(in: .whitespaces)))
                    .help("Select a log row with a request id, or type one")
            }
            Table(of: ErrorRow.self, selection: $fileSelection, sortOrder: $fileSort) {
                TableColumn("Name", value: \.name) { Text($0.name).monospaced().truncationMode(.middle).help($0.name) }
                TableColumn("Size", value: \.sizeKey) { f in
                    Text(f.file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 120)
                TableColumn("Modified", value: \.modifiedKey) { f in
                    Text(f.file.modified?.formatted(date: .abbreviated, time: .standard) ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 170, max: 240)
            } rows: {
                ForEach(files.map(ErrorRow.init).sorted(using: fileSort)) { TableRow($0) }
            }
            .contextMenu(forSelectionType: String.self) { names in
                if names.count == 1, let n = names.first { Button("Open") { openErrorLog(n) } }
            } primaryAction: { names in
                if names.count == 1, let n = names.first { openErrorLog(n) }
            }
            .overlay { if files.isEmpty { Text("No error logs.").foregroundStyle(.secondary) } }
        }
        .padding(8)
    }

    private func statusColor(_ s: Int) -> Color {
        switch s { case 500...: .red; case 400..<500: .orange; case 200..<300: .green; default: .secondary }
    }

    private func refilter() {
        shown = LogLine.filter(lines, level: level, query: query, hideManagement: hideManagement).sorted(using: sortOrder)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func openRequest(_ id: String) { open { try await $0.requestLog(id: id, key: $1) } }
    private func openErrorLog(_ name: String) { open { try await $0.errorLog(name: name, key: $1) } }

    private func reload() async {
        guard !locked else { lines = []; files = []; cursor = nil; return }
        cursor = nil
        await readTail(poll: false)
        do { files = try await monitor.management { try await $0.errorLogs(key: $1) } }
        catch { self.error = describeHubError(error) }
    }

    /// Poll reads append after the hub's cursor, unless the hub reset it; otherwise the newest page replaces the list.
    private func readTail(poll: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let c = poll ? cursor : nil
        do {
            let t = try await monitor.management { try await $0.logsTail(cursor: c, limit: c == nil ? Self.page : LogLimits.maxLines, key: $1) }
            enabled = t.enabled
            let parsed = t.lines.enumerated().map { LogLine($1, seq: nextSeq + $0) }
            nextSeq += parsed.count
            if c != nil && !t.reset { lines = Array((lines + parsed).suffix(LogLimits.maxLines)) } else { lines = parsed }
            cursor = t.cursor ?? (t.reset ? nil : cursor)
            error = nil
        } catch LogsError.invalidCursor {
            cursor = nil
        } catch {
            self.error = describeHubError(error)
        }
    }

    private func open(_ op: @escaping @Sendable (ManagementClient, String) async throws -> LogText) {
        Task {
            do { viewing = try await monitor.management(op); error = nil } catch { self.error = describeHubError(error) }
        }
    }

    private func clear() async {
        notice = nil
        do {
            let n = try await monitor.management { try await $0.clearLogs(key: $1) }
            notice = n.map { "Cleared the hub's logs (\($0) file\($0 == 1 ? "" : "s"))." } ?? "Cleared the hub's logs."
        } catch { self.error = describeHubError(error) }
        await reload()
    }
}

private struct LevelBadge: View {
    let level: LogLine.Level
    var body: some View {
        switch level {
        case .error: Label("Error", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .warn: Label("Warn", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Label("Info", systemImage: "info.circle").foregroundStyle(.secondary)
        case .debug: Label("Debug", systemImage: "ant").foregroundStyle(.tertiary)
        case .other: Label("—", systemImage: "circle.dashed").foregroundStyle(.tertiary)
        }
    }
}

/// Non-optional sort keys for the log table.
private extension LogLine {
    var levelRank: Int { [.error: 0, .warn: 1, .info: 2, .debug: 3][level] ?? 4 }
    var requestKey: String { requestID ?? "" }
    var sourceKey: String { source ?? "" }
    var statusKey: Int { access?.status ?? -1 }
    var latencyKey: Double { access?.latencyMs ?? -1 }
    var methodKey: String { access?.method ?? "" }
}

private struct ErrorRow: Identifiable {
    let file: LogFile
    var id: String { file.name }
    var name: String { file.name }
    var sizeKey: Int { file.size ?? -1 }
    var modifiedKey: Date { file.modified ?? .distantPast }
}

private struct Viewed: Identifiable { let log: LogText; var id: String { log.name } }

private struct LogTextSheet: View {
    let log: LogText
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(log.name).font(.headline).monospaced()
                if log.truncated { Text("Truncated to the first 1,000,000 characters").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(log.text.isEmpty ? "(empty)" : log.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }
}
