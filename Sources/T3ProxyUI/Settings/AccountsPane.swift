import SwiftUI
import AppKit
import T3ProxyCore

struct AccountsPane: View {
    @ObservedObject var model: AccountsModel
    @ObservedObject var monitor: Monitor
    @ObservedObject private var routingGuard: RoutingGuard
    @ObservedObject private var router = SettingsRouter.shared
    @State private var search = ""
    @State private var filter = AccountFilter.all
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search accounts, plans or teams", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search accounts")
                Picker("Filter accounts", selection: $filter) {
                    ForEach(AccountFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }.padding(20)
            Divider()
            content
        }
            .navigationTitle("Accounts")
            .navigationSubtitle(model.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    banner
                    HStack {
                        Text("\(model.credentials.count) accounts").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { router.addingAccount = true } label: { Label("Add Account", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
                            .keyboardShortcut("n", modifiers: .command)
                    }.padding(16)
                }.background(.bar)
            }
            .inspector(isPresented: $showInspector) {
                Group {
                    if let c = selected { AccountInspector(c: c, model: model, monitor: monitor, ask: ask, edit: { editing = $0 }) }
                    else { ContentUnavailableView("No Selection", systemImage: "person.crop.circle", description: Text("Select an account.")) }
                }
                .inspectorColumnWidth(min: 290, ideal: 320, max: 380)
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
            .sheet(isPresented: Binding(get: { router.addingAccount }, set: { router.addingAccount = $0 }), onDismiss: {
                Task { await model.load() }
            }) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Add Account").font(.title2).fontWeight(.semibold)
                        Spacer()
                        Button("Done") { router.addingAccount = false }.keyboardShortcut(.cancelAction)
                    }.padding(20)
                    Divider()
                    AddAccountPane(monitor: monitor)
                }.frame(width: 620, height: 560)
            }
            .onChange(of: model.credentials) { _, values in
                if let selection, !values.contains(where: { $0.id == selection }) { self.selection = nil; showInspector = false }
            }
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
                     ? "Requests are paused until the key is replaced in Settings → CLIProxyAPI → Connection."
                     : "Set the management key in Settings → CLIProxyAPI → Connection to see and manage accounts.")
            }
        } else if model.credentials.isEmpty && model.loading {
            ProgressView("Loading accounts…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.credentials.isEmpty && model.error == nil {
            ContentUnavailableView("No Accounts", systemImage: "person.2.slash", description: Text("The hub has no credentials."))
        } else {
            directory
        }
    }

    private var directory: some View {
        let groups = AccountDirectory.groups(model.credentials, search: search, filter: filter)
        return List(selection: $selection) {
            if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.credentials) { credential in
                        accountRow(credential).tag(credential.id)
                            .contextMenu {
                                AccountActions(c: credential, busy: model.busy != nil, ask: ask, edit: { editing = $0 })
                            }
                            .onTapGesture(count: 2) { selection = credential.id; showInspector = true }
                            .accessibilityAction(named: "Show Account Details") { selection = credential.id; showInspector = true }
                    }
                } header: {
                    HStack { Text(group.title); Text("\(group.credentials.count)").foregroundStyle(.tertiary) }
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, value in if value != nil { showInspector = true } }
    }

    private func accountRow(_ c: Credential) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                identity(c).frame(width: 220, alignment: .leading)
                quotaBars(c).frame(width: 260)
                status(c).frame(width: 112, alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { identity(c); Spacer(); status(c) }
                quotaBars(c).frame(maxWidth: 300)
            }
        }
        .padding(.vertical, 8)
        .opacity(c.disabled ? 0.6 : 1)
    }

    private func identity(_ c: Credential) -> some View {
        HStack(spacing: 10) {
            ProviderMark(provider: c.provider, size: 24, name: c.providerName)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.label.emailHidden).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text([c.planLabel ?? "Unknown plan", c.org].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let duplicate = AccountDirectory.disambiguator(for: c, among: model.credentials) {
                    Text(duplicate).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            if model.busy == c.name { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private func status(_ c: Credential) -> some View {
        if let pause = routingGuard.pause(for: c), pause.ownedMarker != nil {
            Label("Team guard", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                .help("Paused until \(pause.resetAt.formatted(date: .abbreviated, time: .shortened))")
        } else { StatusLabel(c: c, quota: quota(for: c)).font(.caption) }
    }

    private func quotaBars(_ c: Credential) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 14) {
                AccountQuotaBar(quota: quota(for: c), kind: .session, provider: c.provider, now: context.date)
                AccountQuotaBar(quota: quota(for: c), kind: .weekly, provider: c.provider, now: context.date)
            }
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

struct StatusLabel: View {
    let c: Credential
    var quota: QuotaReading? = nil

    /// Genuine hub failures stay errors; provider quota responses and exhausted readings are "Limited".
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
            case .healthy, .limited:
                if let (k, r) = low, r <= 0 {
                    return ("Limited", "hourglass", .orange, reset.map { "resets \(shortDuration(until: $0, from: now))" },
                            "\(k.title) limit reached; the hub routes to other accounts until it resets.")
                }
                if c.status == .limited {
                    let retry = c.retryAt.flatMap { $0 > now ? $0 : nil }
                    return ("Limited", "hourglass", .orange, retry.map { "retry in \(shortDuration(until: $0, from: now))" },
                            c.reason ?? "Rate limited by the provider")
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
    @ObservedObject var monitor: Monitor
    let ask: (AccountChange) -> Void
    let edit: (EditRequest) -> Void

    private var account: Account? {
        monitor.accounts.first { $0.name == c.name || $0.name + ".json" == c.name }
    }

    var body: some View {
        Form {
            Section {
                if let account {
                    QuotaAccountDetails(account: account, label: c.label.emailHidden, endpoint: monitor.endpointLabel,
                                        live: LiveQuotaModel.shared(for: monitor), connected: monitor.management == .connected)
                        .id(account.id)
                } else {
                    HStack(spacing: 10) {
                        ProviderMark(provider: c.provider, size: 24, name: c.providerName)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.label.emailHidden).font(.headline)
                            Text(c.planLabel ?? "Unknown plan").foregroundStyle(.secondary)
                        }
                    }
                }
                if let org = c.org { LabeledContent("Organization", value: org) }
                LabeledContent("Routing status") { StatusLabel(c: c, quota: accountQuota(monitor, c)) }
            }
            Section("Manage account") {
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
                DisclosureGroup("Troubleshooting") {
                    if let reason = c.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if let time = c.lastRefresh { LabeledContent("Last refresh", value: time.formatted(.relative(presentation: .named))) }
                    Button("Reset Cooldown", systemImage: "timer") { ask(.resetCooldown(c)) }
                        .disabled(model.busy != nil || c.retryAt == nil)
                    Button("Refresh Token", systemImage: "arrow.triangle.2.circlepath") { ask(.refresh(c)) }
                        .disabled(model.busy != nil)
                }
                DisclosureGroup("Technical details") {
                    LabeledContent("Provider", value: c.providerName)
                    Text(c.name.emailHidden).font(.caption).textSelection(.enabled)
                    Button("Copy filename", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.name.emailHidden, forType: .string)
                    }
                }
            }
            Section {
                Button("Delete Account…", systemImage: "trash", role: .destructive) { ask(.delete(c)) }
                    .disabled(model.busy != nil || c.runtimeOnly)
                if model.busy == c.name { ProgressView().controlSize(.small) }
            }
        }.formStyle(.grouped)
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
