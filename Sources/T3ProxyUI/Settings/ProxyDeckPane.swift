import AppKit
import SwiftUI
import T3ProxyCore

/// Moving off Proxy Deck: import its history, then retire it so T3 Proxy serves T3 Code's limits endpoint
/// (127.0.0.1:8318, the URL T3 Code already uses) and records usage itself. Nothing here runs without a click,
/// and stopping or restoring Proxy Deck asks first.
struct ProxyDeckPane: View {
    @ObservedObject private var model = ProxyDeckMigrationModel.shared
    @ObservedObject private var recorder = UsageRecorderModel.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Proxy Deck") { Label(stateText, systemImage: stateSymbol).foregroundStyle(stateColor) }
                LabeledContent("T3 Code limits endpoint") { Label(shimText, systemImage: shimSymbol).foregroundStyle(shimColor) }
                LabeledContent("Usage recording") { Text(recorder.enabled ? "On" : "Off").foregroundStyle(.secondary) }
            } header: { Text("Status") } footer: {
                Text(model.stoppedButSettling
                     ? "Proxy Deck is stopped. Recording turns on by itself once its database has been quiet for 15 minutes, so nothing else is still reading the hub's usage queue."
                     : model.proxyDeckState == .active
                     ? "Proxy Deck currently answers T3 Code's limit bars on 127.0.0.1:8318 and records the hub's usage. After it is retired, T3 Proxy does both, on the same address, so T3 Code needs no change."
                     : "T3 Proxy answers T3 Code's limit bars on 127.0.0.1:8318 and records the hub's usage. Proxy Deck's files are kept; Restore brings it back.")
            }

            Section {
                LabeledContent("History") {
                    if model.importing { ProgressView().controlSize(.small) }
                    else if let r = model.importResult {
                        Text("\(r.insertedRows.formatted()) new · \(r.sourceRows.formatted()) in Proxy Deck").monospacedDigit().foregroundStyle(.secondary)
                    } else { Text("Not imported").foregroundStyle(.secondary) }
                }
                Button(model.importResult == nil ? "Import History" : "Import Again") { Task { await model.importHistory() } }
                    .disabled(model.importing || model.actionInProgress)
            } header: { Text("1 · Import history") } footer: {
                Text("Copies Proxy Deck's usage history and plan labels into T3 Proxy (Application Support/T3 Proxy). Proxy Deck's files are only read. Safe to repeat: rows already copied are skipped. Import again after retiring to pick up the last minutes.")
            }

            Section {
                if model.proxyDeckState == .active {
                    Button("Retire Proxy Deck…", role: .destructive) { confirmRetire() }
                        .disabled(model.importing || model.actionInProgress || model.importResult == nil)
                    if model.importResult == nil { Text("Import its history first.").font(.callout).foregroundStyle(.secondary) }
                } else {
                    Button("Restore Proxy Deck…") { confirmRestore() }
                        .disabled(model.importing || model.actionInProgress)
                }
                if model.actionInProgress { ProgressView().controlSize(.small) }
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                if let result = model.retirementResult, !result.succeeded {
                    ForEach(Array(result.commands.enumerated()), id: \.offset) { _, c in
                        Text("launchctl \(c.arguments.first ?? "") → exit \(c.exitStatus)").font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                }
            } header: { Text("2 · Retire Proxy Deck") } footer: {
                Text("Stops Proxy Deck's launch agent (dev.proxy-deck) and keeps it from starting at login. Its files stay where they are, so Restore undoes this. T3 Proxy then takes over 127.0.0.1:8318 and turns on usage recording once Proxy Deck has gone quiet.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Proxy Deck")
        .task { await model.refresh() }
    }

    // MARK: Confirmations (app-modal; the panel and Settings are not always key)

    private func confirmRetire() {
        confirm("Stop Proxy Deck and disable it at login?",
                "T3 Proxy will take over the T3 Code limits endpoint and usage recording. Proxy Deck's files will be kept, and Restore Proxy Deck can undo this.",
                "Retire Proxy Deck", destructive: true) { Task { await model.retire() } }
    }
    private func confirmRestore() {
        confirm("Restore Proxy Deck?",
                "T3 Proxy will stop recording and release the limits endpoint, then enable and start Proxy Deck's launch agent.",
                "Restore Proxy Deck") { Task { await model.restore() } }
    }
    private func confirm(_ title: String, _ info: String, _ button: String, destructive: Bool = false, then: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        then()
    }

    // MARK: Status text

    private var stateText: String {
        switch model.proxyDeckState {
        case .active: model.stoppedButSettling ? "Stopped · waiting for its database to go quiet" : "Running"
        case .retired: "Retired (files kept)"
        case .absent: "Not installed"
        }
    }
    private var stateSymbol: String { model.proxyDeckState == .active ? (model.stoppedButSettling ? "hourglass" : "bolt.circle") : "checkmark.circle" }
    private var stateColor: Color { model.proxyDeckState == .active ? .secondary : .green }

    private var shimText: String {
        switch model.shimStatus {
        case .listening(let port): "Served by T3 Proxy on 127.0.0.1:\(port)"
        case .portBusy(let port): model.proxyDeckState == .active ? "Served by Proxy Deck (port \(port))" : "Waiting for port \(port)"
        case .stopped: "Off"
        case .failed(let m): m
        }
    }
    private var shimSymbol: String {
        switch model.shimStatus {
        case .listening: "checkmark.circle"
        case .portBusy: "arrow.triangle.2.circlepath"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
    private var shimColor: Color {
        switch model.shimStatus {
        case .listening: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
