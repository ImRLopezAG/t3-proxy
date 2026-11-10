import SwiftUI
import AppKit
import T3ProxyCore

private enum RoutingConfirmation: Identifiable {
    case priorities([PriorityChange])
    case models(String, [ModelAlias], [String], String)
    case addKey(String)
    case removeKey(ClientKeyReference, String)
    case resume(Credential)
    case offerNew
    var id: String {
        switch self { case .priorities: "priorities"; case .models: "models"; case .addKey: "add"; case .removeKey: "remove"; case .resume: "resume"; case .offerNew: "offer" }
    }
    var title: String {
        switch self {
        case .priorities: "Apply plan priorities?"
        case .models: "Apply model routing?"
        case .addKey: "Generate and add a client API key?"
        case .removeKey: "Remove this client API key?"
        case .resume: "Enable this account now?"
        case .offerNew: "Offer priorities for newly added accounts?"
        }
    }
}

/// Native routing controls. Confirmation values are immutable snapshots; writes reject stale reads.
struct RoutingPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var guardModel: RoutingGuard
    @State private var config: RoutingConfig?
    @State private var provider = "claude"
    @State private var aliases: [ModelAlias] = []
    @State private var excludedText = ""
    @State private var pending: RoutingConfirmation?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var notice: String?
    @State private var revealedKey: String?
    @State private var showingKey = false
    @State private var keyResult: String?

    init(monitor: Monitor) {
        self.monitor = monitor
        guardModel = RoutingGuard.shared(for: monitor)
    }
    private var locked: Bool { !monitor.hasKey || monitor.management == .rejected }
    private var priorityChanges: [PriorityChange] {
        PriorityRule(subscription: guardModel.subscriptionPriority, team: guardModel.teamPriority).changes(guardModel.credentials)
    }
    private var excluded: [String] { excludedText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var providers: [String] {
        Array(Set(modelChannels + Array(config?.aliases.keys ?? Dictionary<String, [ModelAlias]>().keys)
                  + Array(config?.excluded.keys ?? Dictionary<String, [String]>().keys) + [provider])).sorted()
    }
    private var modelsValid: Bool { (try? RoutingValidation.provider(provider)) != nil && (try? RoutingValidation.aliases(aliases)) != nil && (try? RoutingValidation.modelNames(excluded)) != nil }
    private var modelsChanged: Bool { aliases != (config?.aliases[provider] ?? []) || excluded != (config?.excluded[provider] ?? []) }

    var body: some View {
        Group {
            if locked { LockedView(monitor: monitor, what: "routing rules") }
            else {
                Form {
                    if let error = error ?? guardModel.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    prioritySection
                    guardSection
                    modelSection
                    keySection
                }
                .formStyle(.grouped)
                .disabled(saving)
            }
        }
        .navigationTitle("Routing")
        .toolbar {
            Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .disabled(loading || saving || locked || guardModel.busy)
        }
        .task(id: monitor.management) { await load() }
        .onChange(of: provider) { _, _ in resetModels() }
        .onChange(of: monitor.keyEpoch) { _, _ in
            pending = nil; config = nil; revealedKey = nil; showingKey = false
        }
        .sheet(item: $pending) { action in confirmation(action) }
        .sheet(isPresented: $showingKey, onDismiss: { revealedKey = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save your new client key").font(.headline)
                Text("This is the only time T3 Proxy shows the full key. After closing, any added key appears masked in the list.")
                if let keyResult { Text(keyResult).foregroundStyle(.secondary) }
                if let revealedKey {
                    Text(revealedKey).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Key", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(revealedKey, forType: .string)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Done") { showingKey = false; revealedKey = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 600)
        }
    }

    private var prioritySection: some View {
        Section {
            Stepper("Individual subscriptions: \(guardModel.subscriptionPriority)", value: $guardModel.subscriptionPriority, in: ManagementRules.priorityRange)
            Stepper("Team / Business / Enterprise: \(guardModel.teamPriority)", value: $guardModel.teamPriority, in: ManagementRules.priorityRange)
            Button("Apply to \(priorityChanges.count) Account\(priorityChanges.count == 1 ? "" : "s")…") { pending = .priorities(priorityChanges) }
                .disabled(priorityChanges.isEmpty || guardModel.busy)
            Toggle("Offer priorities for newly added accounts", isOn: Binding(get: { guardModel.offerNewAccountPriorities }, set: {
                if $0 { pending = .offerNew } else { guardModel.offerNewAccountPriorities = false }
            }))
            if !guardModel.newAccountChanges.isEmpty {
                Button("Review \(guardModel.newAccountChanges.count) New Account Priorities…") { pending = .priorities(guardModel.newAccountChanges) }
            }
        } header: { Text("Priority by Plan") } footer: {
            Text("Higher numbers are preferred. Round-robin rotates within the highest ready priority tier; fill-first takes its first available account. Existing session-affinity bindings can stay on a lower tier. Pro, Plus and Max subscriptions default to 10; Team defaults to 0. Unknown plans are left alone. New-account changes always require confirmation.")
        }
    }
    private var guardSection: some View {
        Section {
            Toggle("Pause Team accounts at their subscription limit", isOn: $guardModel.enabled)
            Picker("Pause at used", selection: $guardModel.threshold) {
                ForEach([95, 98, 100], id: \.self) { Text($0 == 98 ? "98% (recommended)" : "\($0)%").tag($0) }
            }
            ForEach(guardModel.credentials) { c in
                if guardModel.unclearPlans.contains(TeamGuardState.accountID(c)) {
                    Text("\(c.label.emailHidden): plan unclear; automatic pause withheld.").foregroundStyle(.orange)
                }
                if let message = guardModel.state.recoveryNotices?[TeamGuardState.accountID(c)] {
                    Text("\(c.label.emailHidden): \(message)").foregroundStyle(.orange)
                }
                if let pause = guardModel.pause(for: c) {
                    if pause.resumeStatus == .manual || pause.resumeStatus == .pending {
                        Text("T3 Proxy paused \(c.label.emailHidden) and couldn't re-enable it. Enable now?")
                        Button("Enable Now…") { pending = .resume(c) }.disabled(guardModel.busy)
                    } else if pause.resumeStatus == .authBlocked {
                        Text("\(c.label.emailHidden): recovery blocked by authentication. Review Accounts after updating the management key.")
                    } else if pause.resumeStatus == .retry {
                        Text("\(c.label.emailHidden): resume failed; will retry on a later refresh after \(pause.retryAfter?.formatted() ?? "the backoff").")
                    }
                    LabeledContent(c.label.emailHidden) {
                        Text(pause.ownedMarker == nil ? "Pause not verified" : "Paused until \(pause.resetAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            if guardModel.state.pauses.isEmpty { Text("No accounts paused by the Team guard.").foregroundStyle(.secondary) }
        } header: { Text("Team Limit Guard") } footer: {
            Text("""
                 Turns a Team account off when its 5-hour or weekly limit reaches this point, and back on when that limit resets. \
                 98% is safer: readings arrive about once a minute, so a few requests can slip past 100%.
                 It needs a hub reading with a reset time, never turns off a provider's last enabled account, and won't re-enable an account you changed yourself while it was paused. \
                 Turning the guard off stops new pauses; accounts it already paused still come back at their reset.
                 """)
        }
    }
    private var modelSection: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(providers, id: \.self) { Text($0).tag($0) }
            }
            TextField("Provider id", text: $provider)
            ForEach(aliases.indices, id: \.self) { i in
                HStack {
                    TextField("Model", text: $aliases[i].name)
                    TextField("Alias", text: $aliases[i].alias)
                    Toggle("Keep original", isOn: Binding(get: { aliases[i].fork == true }, set: { aliases[i].fork = $0 ? true : nil }))
                    Button("Remove", systemImage: "minus.circle") { aliases.remove(at: i) }.labelStyle(.iconOnly)
                }
            }
            Button("Add Alias", systemImage: "plus") { aliases.append(.init(name: "", alias: "")) }.disabled(aliases.count >= 500)
            Text("Excluded models or patterns, one per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $excludedText).font(.system(.body, design: .monospaced)).frame(minHeight: 70, maxHeight: 140)
            Button("Apply Model Routing…") {
                if let config { pending = .models(provider, aliases, excluded, config.revision) }
            }.disabled(config == nil || !modelsValid || !modelsChanged)
        } header: { Text("Model Aliases and Exclusions") } footer: {
            Text("Up to 500 entries per list. Model names and patterns must contain 1–200 characters without spaces. Keep original exposes both the original model and its alias. Applies to OAuth accounts of the selected provider.")
        }
    }
    private var keySection: some View {
        Section {
            ForEach(config?.clientKeys ?? []) { entry in
                LabeledContent(entry.masked) {
                    Button("Remove…", role: .destructive) {
                        if let config { pending = .removeKey(entry, config.revision) }
                    }
                }
            }
            Button("Generate Client API Key…", systemImage: "key.badge.ellipsis") {
                if let config { pending = .addKey(config.revision) }
            }.disabled(config == nil)
        } header: { Text("Client API Keys") } footer: {
            Text("Existing keys are always masked. Removing a key immediately prevents clients using it from authenticating. New keys are generated on this Mac and shown once after confirmation.")
        }
    }
    private func confirmation(_ action: RoutingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch action {
                    case .priorities(let changes):
                        ForEach(changes) { c in Text("\(c.credential.label.emailHidden): \(c.credential.priority) → \(c.priority)") }
                    case .models(let p, let aliases, let excluded, _):
                        Text("Provider: \(p)")
                        Text("Aliases (current)")
                        ForEach(Array((config?.aliases[p] ?? []).enumerated()), id: \.offset) { _, a in Text("\(a.name.emailHidden) → \(a.alias.emailHidden)\(a.fork == true ? " (keep original)" : "")") }
                        Text("Aliases (replacement)")
                        ForEach(Array(aliases.enumerated()), id: \.offset) { _, a in Text("\(a.name.emailHidden) → \(a.alias.emailHidden)\(a.fork == true ? " (keep original)" : "")") }
                        Text("Excluded (current): \((config?.excluded[p] ?? []).joined(separator: ", ").emailHidden)")
                        Text("Excluded (replacement): \(excluded.joined(separator: ", ").emailHidden)")
                    case .addKey: Text("A new client key will be generated, added to the hub and shown once for copying.")
                    case .removeKey(let entry, _): Text("Remove \(entry.masked)? A client such as T3 Code may be using this key and will immediately lose access.")
                    case .resume(let c): Text("Enable \(c.label.emailHidden)? The hub may route requests to it immediately, including paid extra usage if its limits have not reset. Identity and ownership will be checked again.")
                    case .offerNew: Text("New accounts will appear here with suggested plan priorities. Each batch requires your confirmation before any hub write.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { pending = nil }
                Button("Confirm") { pending = nil; Task { await apply(action) } }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
    private func resetModels() {
        aliases = config?.aliases[provider] ?? []
        excludedText = (config?.excluded[provider] ?? []).joined(separator: "\n")
    }
    private func load() async {
        guard !locked, !loading, !saving else { return }
        loading = true; defer { loading = false }
        let epoch = monitor.keyEpoch
        do {
            let fresh = try await monitor.management { try await $0.routingConfig(key: $1) }
            guard epoch == monitor.keyEpoch else { return }
            config = fresh; resetModels(); error = nil
            await guardModel.refresh()
        } catch { self.error = routingErrorDescription(error) }
    }
    private func apply(_ action: RoutingConfirmation) async {
        guard !saving, !locked else { return }
        saving = true; error = nil; notice = nil
        let epoch = monitor.keyEpoch
        do {
            switch action {
            case .priorities(let changes):
                await guardModel.applyPriorities(changes)
                if let failure = guardModel.error { error = failure; saving = false; return }
            case .resume(let c): await guardModel.manualResume(c)
            case .offerNew: guardModel.offerNewAccountPriorities = true; await guardModel.refresh()
            case .models(let provider, let aliases, let excluded, let revision):
                try await monitor.management { try await $0.applyModelRouting(provider: provider, aliases: aliases, excluded: excluded, revision: revision, key: $1) }
            case .addKey(let revision):
                let generated = try ClientKeyGenerator.generate()
                do {
                    try await monitor.management { try await $0.changeClientKey(.add(generated), revision: revision, key: $1) }
                } catch {
                    // An uncertain result is never retried. Preserve the generated value for the user's clients.
                    if epoch == monitor.keyEpoch {
                        switch error {
                        case ProxyError.unreachable, ProxyError.http:
                            keyResult = "The result is unknown. Save this key before closing, then reload the list to check whether it was added. The request will not be retried."
                            revealedKey = generated; showingKey = true
                        default: break
                        }
                    }
                    throw error
                }
                if epoch == monitor.keyEpoch {
                    keyResult = "The hub confirmed that this key was added."
                    revealedKey = generated; showingKey = true
                }
            case .removeKey(let entry, let revision):
                try await monitor.management { try await $0.changeClientKey(.remove(reference: entry.reference), revision: revision, key: $1) }
            }
            if epoch == monitor.keyEpoch { notice = "Routing change applied." }
        } catch { if epoch == monitor.keyEpoch { self.error = routingErrorDescription(error) } }
        saving = false
        // Refresh the revision without discarding the result/error or the one-time key sheet.
        if epoch == monitor.keyEpoch {
            do { config = try await monitor.management { try await $0.routingConfig(key: $1) }; resetModels() }
            catch { if self.error == nil { self.error = routingErrorDescription(error) } }
        }
    }
}
