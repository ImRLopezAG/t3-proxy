import SwiftUI
import T3ProxyCore

/// Hub config. Proxy Deck's allowlisted settings are editable; changes collect in a draft and are sent
/// together after one confirmation. Server, access and secrets stay read-only (masked in the decoder).
struct ConfigPane: View {
    @ObservedObject var monitor: Monitor
    @State private var summary: ConfigSummary?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var draft: [ConfigSetting: ConfigValue] = [:]
    @State private var confirming = false
    @State private var saving = false

    private var locked: Bool { monitor.management == .rejected || !monitor.hasKey }

    /// Draft entries that differ from what was read.
    private var changes: [ConfigSetting: ConfigValue] {
        guard let s = summary else { return [:] }
        return draft.filter { s.value($0.key) != $0.value }
    }
    private var invalid: [ConfigSetting] { changes.filter { $0.key.validated($0.value) == nil }.map(\.key) }

    var body: some View {
        content
            .navigationTitle("Config")
            .toolbar {
                ToolbarItemGroup {
                    if !changes.isEmpty {
                        Button("Revert") { draft = [:]; error = nil }.disabled(saving)
                        Button("Apply \(changes.count) Change\(changes.count == 1 ? "" : "s")…") { confirming = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || !invalid.isEmpty)
                    }
                    Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(loading || locked || saving)
                }
            }
            .task(id: monitor.management) { await load() }
            .confirmationDialog("Change \(changes.count) hub setting\(changes.count == 1 ? "" : "s")?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Apply") { Task { await apply() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(summaryText)
            }
    }

    private var summaryText: String {
        let lines = ConfigSetting.allCases.compactMap { s in changes[s].map { "\(s.title): \(show(summary?.value(s))) → \(show($0))" } }
        var text = lines.joined(separator: "\n")
        if changes[.requestLog] == .bool(true) { text += "\n\nRequest log writes full request and response bodies to disk." }
        text += "\n\nThe hub applies these right away for every client, including T3 Code."
        return text
    }

    @ViewBuilder private var content: some View {
        if locked {
            LockedView(monitor: monitor, what: "the hub config")
        } else if let s = summary {
            form(s)
        } else if loading {
            ProgressView("Loading config…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Config Unavailable", systemImage: "exclamationmark.triangle", description: Text(error ?? ""))
        }
    }

    private func form(_ s: ConfigSummary) -> some View {
        Form {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if let notice, changes.isEmpty { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Section("Routing") {
                edit(.strategy, s); edit(.forceModelPrefix, s); edit(.sessionAffinity, s); edit(.sessionAffinityTTL, s)
            }
            Section("Retries and Cooldowns") {
                edit(.requestRetry, s); edit(.maxRetryInterval, s); edit(.maxRetryCredentials, s)
                edit(.disableCooling, s); edit(.saveCooldownStatus, s); edit(.transientErrorCooldown, s)
            }
            Section("Logging and Usage") {
                edit(.loggingToFile, s); edit(.usageStatistics, s); edit(.debug, s); edit(.requestLog, s)
                edit(.errorLogsMaxFiles, s); edit(.logsMaxTotalSizeMB, s)
            }
            Section("When Quota Runs Out") {
                edit(.switchProject, s); edit(.switchPreviewModel, s)
            }
            Section("Requests") {
                edit(.passthroughHeaders, s); edit(.keepalive, s)
                row("Proxy URL", s.proxyURL ?? "Not set")
            }
            Section {
                edit(.commercialMode, s); edit(.plugins, s)
                row("Host", s.host); row("Port", s.port); row("TLS", s.tls)
            } header: { Text("Server") } footer: {
                Text("Host, port and TLS are read-only here: changing them would disconnect T3 Code and this app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                row("Client API keys", "\(s.clientKeys)")
                row("Provider API keys", "\(s.providers.reduce(0) { $0 + $1.keys.count })")
                row("Management key", s.managementKeySet ? "Set" : "Not set")
                row("Remote management", s.allowRemote)
                row("Control panel disabled", s.panelDisabled)
            } header: { Text("Access") } footer: {
                Text("Keys and remote management can't be changed from T3 Proxy.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(saving)
    }

    // MARK: - Editable rows

    private func current(_ k: ConfigSetting, _ s: ConfigSummary) -> ConfigValue? { draft[k] ?? s.value(k) }

    /// An edit back to the loaded value is dropped, so it can't come back as a pending change after a reload.
    private func put(_ k: ConfigSetting, _ v: ConfigValue, _ s: ConfigSummary) {
        if s.value(k) == v { draft[k] = nil } else { draft[k] = v }
    }

    @ViewBuilder private func edit(_ k: ConfigSetting, _ s: ConfigSummary) -> some View {
        let changed = changes[k] != nil
        Group {
            if current(k, s) == nil {
                row(k.title, "—")
            } else {
                switch k.kind {
                case .bool:
                    Toggle(isOn: Binding(get: { current(k, s) == .bool(true) }, set: { put(k, .bool($0), s) })) { label(k, changed) }
                case .choice(let options):
                    Picker(selection: Binding(get: { if case .text(let t)? = current(k, s) { t } else { "" } },
                                              set: { put(k, .text($0), s) })) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                        if case .text(let t)? = s.value(k), !options.contains(t) { Text(t).tag(t) }
                    } label: { label(k, changed) }
                case .int(let range):
                    LabeledContent { IntField(value: Binding(get: { if case .int(let i)? = current(k, s) { i } else { 0 } },
                                                             set: { put(k, .int($0), s) }), range: range) }
                        label: { label(k, changed) }
                case .duration:
                    LabeledContent {
                        TextField("", text: Binding(get: { if case .text(let t)? = current(k, s) { t } else { "" } },
                                                    set: { put(k, .text($0.trimmingCharacters(in: .whitespaces)), s) }))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .foregroundStyle(invalid.contains(k) ? Color.red : Color.primary)
                    } label: { label(k, changed) }
                }
            }
        }
    }

    private func label(_ k: ConfigSetting, _ changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(k.title)
                if changed { Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("Changed") }
            }
            if let help = k.help { Text(help).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func row(_ label: String, _ v: Bool?) -> some View { row(label, v.map { $0 ? "On" : "Off" }) }
    private func row(_ label: String, _ v: Int?) -> some View { row(label, v.map(String.init)) }
    private func row(_ label: String, _ v: String?) -> some View {
        LabeledContent(label) { Text(v ?? "—").monospacedDigit().textSelection(.enabled) }
    }

    private func show(_ v: ConfigValue?) -> String {
        switch v {
        case .bool(let b)?: b ? "On" : "Off"
        case .int(let i)?: "\(i)"
        case .text(let t)?: t
        case nil: "—"
        }
    }

    // MARK: - Loading and saving

    private func load() async {
        guard !locked else { summary = nil; return }
        loading = true; defer { loading = false }
        do {
            summary = try await monitor.management { try await $0.configSummary(key: $1) }
            // Keep only edits that still differ from the hub.
            if let s = summary { draft = draft.filter { s.value($0.key) != $0.value } }
            error = nil
        } catch { self.error = describeHubError(error) }
    }

    private func apply() async {
        guard let rev = summary?.revision, !saving, !changes.isEmpty, invalid.isEmpty else { return }
        let sent = changes
        saving = true; error = nil; notice = nil
        do {
            try await monitor.management { try await $0.applySettings(sent, revision: rev, key: $1) }
            draft = [:]
            notice = sent.count == 1 ? "\(sent.first!.key.title) updated." : "\(sent.count) settings updated."
        } catch { self.error = describeHubError(error) }
        saving = false
        let failure = error
        await load()
        if let failure { error = failure }
    }
}

/// A number field with a stepper, clamped to the setting's range.
private struct IntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.grouping(.never))
                .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 80)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// Shared by Config, AI Providers and Logs.
struct LockedView: View {
    @ObservedObject var monitor: Monitor
    var what: String
    var body: some View {
        ContentUnavailableView {
            Label(monitor.management == .rejected ? "Key Rejected" : "No Management Key", systemImage: "key.slash")
        } description: {
            Text(monitor.management == .rejected
                 ? "Requests are paused until the key is replaced in Connection."
                 : "Set the management key in Connection to see \(what).")
        }
    }
}

@MainActor func describeHubError(_ e: Error) -> String {
    switch e {
    case ConfigError.stale: "The hub's config changed since it was read. Reload and try again."
    case ConfigError.invalidChannel: "That provider has no model list."
    case ConfigError.invalidValue(let s): "\(s.title) has a value the hub won't accept."
    case ConfigError.nothingChanged: "Those settings already have these values."
    case LogsError.tooLarge: "The hub's answer was too large to show."
    case LogsError.invalidName: "That is not an error log file name."
    case LogsError.invalidRequestID: "A request id is letters, digits, - and _ (up to 64)."
    case LogsError.invalidCursor: "The log position was invalid; reloading the tail."
    case LogsError.loggingOff: "File logging is off on the hub."
    default: AccountsModel.describe(e)
    }
}
