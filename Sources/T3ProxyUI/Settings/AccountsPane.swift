import SwiftUI
import T3ProxyCore

struct AccountsPane: View {
    @ObservedObject var model: AccountsModel
    @ObservedObject var monitor: Monitor
    @ObservedObject private var routingGuard: RoutingGuard
    @State private var selection: Credential.ID?
    @State private var showInspector = false
    @State private var pending: AccountChange?
    @State private var editing: EditRequest?

    init(model: AccountsModel, monitor: Monitor) {
        self.model = model; self.monitor = monitor
        routingGuard = RoutingGuard.shared(for: monitor)
    }

    private var selected: Credential? { model.credentials.first { $0.id == selection } }

    var body: some View {
        content
            .navigationTitle("Accounts")
            .navigationSubtitle(model.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            .safeAreaInset(edge: .bottom) { banner }
            .inspector(isPresented: $showInspector) {
                Group {
                    if let c = selected { AccountInspector(c: c, model: model, ask: ask, edit: { editing = $0 }) }
                    else { ContentUnavailableView("No Selection", systemImage: "person.crop.circle", description: Text("Select an account.")) }
                }
                .inspectorColumnWidth(min: 240, ideal: 270, max: 340)
            }
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(model.loading || model.locked)
                }
                ToolbarItem {
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                }
            }
            .task(id: monitor.management) { await model.load() }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { change in
                Button(change.confirmLabel, role: change.isDestructive ? .destructive : nil) {
                    Task { await model.apply(change) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.message) }
            .sheet(item: $editing) { req in
                EditSheet(request: req) { change in editing = nil; pending = change }
            }
    }

    @ViewBuilder private var content: some View {
        if model.locked {
            ContentUnavailableView {
                Label(monitor.management == .rejected ? "Key Rejected" : "No Management Key", systemImage: "key.slash")
            } description: {
                Text(monitor.management == .rejected
                     ? "Requests are paused until the key is replaced in Connection."
                     : "Set the management key in Connection to see and manage accounts.")
            }
        } else if model.credentials.isEmpty && model.loading {
            ProgressView("Loading accounts…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.credentials.isEmpty && model.error == nil {
            ContentUnavailableView("No Accounts", systemImage: "person.2.slash", description: Text("The hub has no credentials."))
        } else {
            table
        }
    }

    private var table: some View {
        Table(model.credentials, selection: $selection) {
            TableColumn("Account") { c in
                HStack(spacing: 8) {
                    ProviderMark(provider: c.provider, size: 16, name: c.providerName)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.label.emailHidden).lineLimit(1)
                        if c.nickname != nil || c.provider == .other {
                            Text((c.provider == .other ? "\(c.providerName) · \(c.name)" : c.name).emailHidden)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if model.busy == c.name { ProgressView().controlSize(.small) }
                }
                .opacity(c.disabled ? 0.55 : 1)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Plan") { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.planLabel ?? "Unknown").foregroundStyle(c.planLabel == nil ? .secondary : .primary).lineLimit(1)
                    if let o = c.org { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
                .width(min: 70, ideal: 100)
            TableColumn("Status") { c in
                if let pause = routingGuard.pause(for: c), pause.ownedMarker != nil {
                    Text("Paused by Team guard until \(pause.resetAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { StatusLabel(c: c, quota: quota(for: c)) }
            }
                .width(min: 80, ideal: 105)
            TableColumn("5-hour") { c in QuotaCell(c: c, quota: quota(for: c), kind: .session) }
                .width(min: 64, ideal: 84)
            TableColumn("Weekly") { c in QuotaCell(c: c, quota: quota(for: c), kind: .weekly) }
                .width(min: 64, ideal: 84)
            TableColumn("Priority") { c in Text("\(c.priority)").monospacedDigit().foregroundStyle(c.priority == 0 ? .secondary : .primary) }
                .width(min: 44, ideal: 52)
        }
        .contextMenu(forSelectionType: Credential.ID.self) { ids in
            if let id = ids.first, let c = model.credentials.first(where: { $0.id == id }) {
                AccountActions(c: c, busy: model.busy != nil, ask: ask, edit: { editing = $0 })
            }
        } primaryAction: { ids in
            selection = ids.first; showInspector = true
        }
    }

    @ViewBuilder private var banner: some View {
        if let e = model.error {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(.bar)
        } else if let n = model.notice {
            Label(n, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(.bar)
        }
    }

    private func ask(_ c: AccountChange) { pending = c }

    /// The hub's recorded rate-limit reading for this credential (from the Monitor's poll).
    private func quota(for c: Credential) -> QuotaReading? { accountQuota(monitor, c) }
}

@MainActor func accountQuota(_ monitor: Monitor, _ c: Credential) -> QuotaReading? {
    monitor.accounts.first { $0.name + ".json" == c.name || $0.name == c.name }?.quota
}

/// One quota window for one account: remaining % and time to reset, or why it is unknown.
struct QuotaCell: View {
    let c: Credential; let quota: QuotaReading?; let kind: QuotaWindowKind
    var body: some View {
        let now = Date()
        if c.provider == .other || quota == nil {
            Text("—").foregroundStyle(.tertiary)
        } else if let q = quota, let r = q.remaining(kind, at: now) {
            let reset = q.window(kind)?.resetAt
            HStack(spacing: 5) {
                Text("\(Int(r.rounded()))%").monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(r <= 0 ? .red : r < 10 ? .orange : .primary)
                if let reset { Text(shortDuration(until: reset, from: now)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .help(reset.map { "\(kind.title): \(Int(r.rounded()))% left · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? kind.title)
        } else if quota?.window(kind) != nil {
            Text("Expired").foregroundStyle(.secondary)
                .help("The last reading's window has reset. It updates on this account's next request.")
        } else if quota?.source == .live {
            Text("None reported").foregroundStyle(.tertiary)
                .help("The provider's latest answer had no \(kind == .session ? "5-hour" : "weekly") window for this account (not started, or not part of its plan).")
        } else {
            Text("No reading").foregroundStyle(.tertiary)
                .help("The hub has not recorded this limit for this account yet (or the plan has no such window).")
        }
    }
}

struct StatusLabel: View {
    let c: Credential
    var quota: QuotaReading? = nil

    /// Hub state first (disabled, error, cooling); a healthy account whose recorded limit is used up
    /// is "Limited" until that window resets, and under 10% left is "Near limit".
    var body: some View {
        let now = Date()
        let windows = QuotaWindowKind.allCases.compactMap { k in quota?.remaining(k, at: now).map { (k, $0) } }
        let low = windows.min { $0.1 < $1.1 }
        let reset = low.flatMap { quota?.window($0.0)?.resetAt }
        let (text, symbol, color, detail, help): (String, String, Color, String?, String) = {
            switch c.status {
            case .disabled: return ("Disabled", "pause.circle.fill", .secondary, nil, c.reason ?? "Disabled")
            case .error: return ("Error", "exclamationmark.triangle.fill", .red, nil, c.reason ?? "Error")
            case .cooling: return ("Cooling", "clock.fill", .orange, c.retryAt.map { "until \($0.formatted(date: .omitted, time: .shortened))" }, c.reason ?? "Cooling")
            case .healthy:
                if let (k, r) = low, r <= 0 {
                    return ("Limited", "hourglass", .orange, reset.map { "resets \(shortDuration(until: $0, from: now))" },
                            "\(k.title) limit reached; the hub routes to other accounts until it resets.")
                }
                if let (k, r) = low, r < 10 {
                    return ("Near limit", "gauge.with.dots.needle.67percent", .yellow, "\(k == .session ? "5-hour" : "weekly") \(Int(r.rounded()))% left",
                            "\(k.title): \(Int(r.rounded()))% left.")
                }
                return ("Healthy", "checkmark.circle.fill", .green, nil, "Routable; recorded limits are not exhausted.")
            }
        }()
        VStack(alignment: .leading, spacing: 1) {
            Label(text, systemImage: symbol).foregroundStyle(color)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .help(help)
    }
}

/// Shared by the context menu and the inspector.
struct AccountActions: View {
    let c: Credential
    let busy: Bool
    let ask: (AccountChange) -> Void
    let edit: (EditRequest) -> Void
    var body: some View {
        Button(c.nickname == nil ? "Set Nickname…" : "Rename…", systemImage: "pencil") { edit(.rename(c)) }
            .disabled(busy || c.runtimeOnly)
        Button("Set Priority…", systemImage: "arrow.up.arrow.down") { edit(.priority(c)) }
            .disabled(busy || c.runtimeOnly)
        Divider()
        Button(c.disabled ? "Enable" : "Disable", systemImage: c.disabled ? "play.circle" : "pause.circle") { ask(.setDisabled(c, !c.disabled)) }
            .disabled(busy)
        Button("Reset Cooldown", systemImage: "timer") { ask(.resetCooldown(c)) }
            .disabled(busy || c.retryAt == nil)
        Button("Refresh Token", systemImage: "arrow.triangle.2.circlepath") { ask(.refresh(c)) }
            .disabled(busy)
        Divider()
        Button("Delete Account…", systemImage: "trash", role: .destructive) { ask(.delete(c)) }
            .disabled(busy || c.runtimeOnly)
    }
}

struct AccountInspector: View {
    let c: Credential
    @ObservedObject var model: AccountsModel
    let ask: (AccountChange) -> Void
    let edit: (EditRequest) -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ProviderMark(provider: c.provider, size: 22, name: c.providerName)
                    VStack(alignment: .leading) {
                        Text(c.label.emailHidden).font(.headline)
                        Text(c.name.emailHidden).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                LabeledContent("Provider", value: c.provider == .other ? c.providerName : c.provider.title)
                LabeledContent("Plan", value: c.planLabel ?? "Unknown")
                if let o = c.org { LabeledContent("Organization", value: o) }
                LabeledContent("Status") { StatusLabel(c: c, quota: accountQuota(model.monitor, c)) }
                if c.provider != .other {
                    LabeledContent("5-hour") { QuotaCell(c: c, quota: accountQuota(model.monitor, c), kind: .session) }
                    LabeledContent("Weekly") { QuotaCell(c: c, quota: accountQuota(model.monitor, c), kind: .weekly) }
                }
                if let r = c.reason { Text(r).font(.callout).foregroundStyle(.secondary) }
                if let t = c.lastRefresh { LabeledContent("Last refresh", value: t.formatted(.relative(presentation: .named))) }
            }
            Section("Routing") {
                Toggle("Enabled", isOn: Binding(get: { !c.disabled }, set: { ask(.setDisabled(c, !$0)) }))
                    .disabled(model.busy != nil)
                LabeledContent("Priority") {
                    Button("\(c.priority)") { edit(.priority(c)) }.disabled(model.busy != nil || c.runtimeOnly)
                }
                LabeledContent("Nickname") {
                    Button(c.nickname?.emailHidden ?? "Set…") { edit(.rename(c)) }.disabled(model.busy != nil || c.runtimeOnly)
                }
            }
            Section {
                Button("Reset Cooldown", systemImage: "timer") { ask(.resetCooldown(c)) }
                    .disabled(model.busy != nil || c.retryAt == nil)
                Button("Refresh Token", systemImage: "arrow.triangle.2.circlepath") { ask(.refresh(c)) }
                    .disabled(model.busy != nil)
                Button("Delete Account…", systemImage: "trash", role: .destructive) { ask(.delete(c)) }
                    .disabled(model.busy != nil || c.runtimeOnly)
                if model.busy == c.name { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
    }
}

enum EditRequest: Identifiable {
    case rename(Credential), priority(Credential)
    var id: String { switch self { case .rename(let c): "n" + c.id; case .priority(let c): "p" + c.id } }
}

struct EditSheet: View {
    let request: EditRequest
    let submit: (AccountChange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var priority = 0

    var body: some View {
        Form {
            switch request {
            case .rename(let c):
                Section {
                    TextField("Nickname", text: $text, prompt: Text(c.name.emailHidden))
                } header: { Text("Nickname for “\(c.label.emailHidden)”") } footer: {
                    let n = (ManagementRules.cleanNickname(text) ?? "").unicodeScalars.count
                    let hidden = c.nickname.map { $0.emailHidden != $0 } ?? false
                    Text(n > ManagementRules.nicknameMax ? "Too long: \(n) of \(ManagementRules.nicknameMax) characters."
                         : (hidden ? "The current nickname contains an email address, so it isn't shown. " : "")
                            + "Leave empty to clear. Up to \(ManagementRules.nicknameMax) characters.")
                        .foregroundStyle(n > ManagementRules.nicknameMax ? .red : .secondary)
                }
            case .priority(let c):
                Section {
                    Stepper(value: $priority, in: ManagementRules.priorityRange) {
                        TextField("Priority", value: $priority, format: .number).monospacedDigit().frame(width: 60)
                    }
                } header: { Text("Priority for “\(c.label.emailHidden)”") } footer: {
                    Text("From \(ManagementRules.priorityRange.lowerBound) to \(ManagementRules.priorityRange.upperBound). Higher is used first; 0 is the default.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Continue…", action: commit).disabled(!valid) }
        }
        .onAppear {
            switch request {
            // A nickname containing an address is never put on screen; the field starts empty instead.
            case .rename(let c): text = c.nickname.map { $0.emailHidden == $0 ? $0 : "" } ?? ""
            case .priority(let c): priority = c.priority
            }
        }
    }

    private var valid: Bool {
        switch request {
        case .rename(let c):
            let clean = ManagementRules.cleanNickname(text)
            return (clean ?? "").unicodeScalars.count <= ManagementRules.nicknameMax && clean != c.nickname
        case .priority(let c): return ManagementRules.priorityRange.contains(priority) && priority != c.priority
        }
    }

    private func commit() {
        guard valid else { return }
        switch request {
        case .rename(let c): submit(.rename(c, ManagementRules.cleanNickname(text) ?? ""))
        case .priority(let c): submit(.priority(c, priority))
        }
    }
}
