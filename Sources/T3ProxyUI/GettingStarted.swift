import SwiftUI
import AppKit
import T3ProxyCore

/// What a new install still needs. Built from live state; nothing here runs a command or reads a key.
struct SetupChecklist: Equatable {
    var endpoint: String
    var hubLive: Bool
    var hubChecking: Bool
    var management: ManagementState
    var t3Connected: Bool
    /// The usage recorder's real state (optional step), not just its switch.
    var recorder: RecorderCheck

    var keyOK: Bool { management == .connected }
    /// The panel shows the guide until the required steps pass.
    var needsSetup: Bool { !hubLive || !keyOK }

    @MainActor init(_ c: PanelContent, t3Connected: Bool, recorder: RecorderCheck = recorderCheck()) {
        endpoint = c.endpoint; hubLive = c.reachability == .live; hubChecking = c.reachability == .unknown
        management = c.management; self.t3Connected = t3Connected; self.recorder = recorder
    }

    var keyDetail: String {
        switch management {
        case .connected: "Accepted by the hub"
        case .noKey: hubLive ? "Not set" : "Waiting for the hub"
        case .rejected: "Rejected — enter a new key"
        case .failed(let m): m
        }
    }
}

enum RecorderCheck: Equatable { case off, recording, otherApp, attention(String) }

/// Green only while records are actually being saved; a switched-on recorder that can't record says why.
@MainActor func recorderCheck(_ m: UsageRecorderModel = .shared) -> RecorderCheck {
    if UsageRecorder.otherRecorderPresent() { return .otherApp }
    guard m.enabled else { return .off }
    switch m.status {
    case .recording: return .recording
    case .off, .waitingForHub: return .attention("Waiting for the hub")
    case .blockedByOtherRecorder: return .otherApp
    case .statisticsDisabled: return .attention("Turn on the hub's usage statistics")
    case .keyRejected: return .attention("Management key rejected")
    case .unsupported: return .attention("This hub has no usage queue")
    case .failed(let m): return .attention(m)
    }
}

enum CheckState { case ok, missing, optional, checking }

struct CheckRow: View {
    let state: CheckState
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let button, let action {
                Button(button, action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var icon: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .checking: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

/// Compact checklist for the panel's Overview (fits the 360-pt panel; no scroll view, no new window).
struct SetupGuideCard: View {
    let list: SetupChecklist
    let openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Getting started", systemImage: "list.bullet.clipboard").font(.headline)
                Spacer()
                Button("Guide…") { open(.gettingStarted) }.buttonStyle(.borderless).font(.caption)
            }
            CheckRow(state: list.hubLive ? .ok : list.hubChecking ? .checking : .missing,
                     title: "Hub running on \(list.endpoint)",
                     detail: list.hubLive ? "CLIProxyAPI answers" : "Install and start cliproxyapi, or change the port",
                     button: list.hubLive ? nil : "Port…", action: { open(.connection) })
            CheckRow(state: list.keyOK ? .ok : .missing, title: "Management key", detail: list.keyDetail,
                     button: list.keyOK ? nil : "Set Key…", action: { open(.connection) })
            CheckRow(state: list.t3Connected ? .ok : .optional, title: "T3 Code connected",
                     detail: list.t3Connected ? "Threads tab is live" : "Optional · for the Threads tab",
                     button: list.t3Connected ? nil : "Connect…", action: { open(.t3code) })
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private func open(_ p: SettingsPane) { SettingsRouter.shared.pane = p; openSettings() }
}

/// Settings → Getting Started. Instructions only; the app never runs shell commands.
struct GettingStartedPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var t3 = T3CodeModel.shared()
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var recorder = UsageRecorderModel.shared

    var body: some View {
        let content = PanelContent(reachability: monitor.reachability, management: monitor.management,
                                   endpoint: monitor.endpointLabel, accounts: [], updatedAt: nil)
        Form { GettingStartedSections(list: SetupChecklist(content, t3Connected: t3.status.isConnected),
                                      port: monitor.endpoint.port) { router.pane = $0 } }
            .formStyle(.grouped)
            .navigationTitle("Getting Started")
            .toolbar {
                ToolbarItem {
                    Button { Task { await monitor.refresh() } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                        .disabled(monitor.refreshing)
                }
            }
    }
}

/// Shared by the pane and its offscreen still.
struct GettingStartedSections: View {
    let list: SetupChecklist
    let port: Int
    let go: (SettingsPane) -> Void
    var body: some View {
        Section {
            CheckRow(state: list.hubLive ? .ok : list.hubChecking ? .checking : .missing,
                     title: "Hub running on \(list.endpoint)", detail: list.hubLive ? "CLIProxyAPI answers" : "Nothing answers yet")
            CheckRow(state: list.keyOK ? .ok : .missing, title: "Management key", detail: list.keyDetail,
                     button: "Connection…", action: { go(.connection) })
            CheckRow(state: list.t3Connected ? .ok : .optional, title: "T3 Code connected",
                     detail: list.t3Connected ? "Threads tab is live" : "Optional", button: "T3 Code…", action: { go(.t3code) })
            switch list.recorder {
            case .recording:
                CheckRow(state: .ok, title: "Usage history", detail: "Recording", button: "Usage…", action: { go(.usage) })
            case .otherApp:
                CheckRow(state: .ok, title: "Usage history", detail: "Recorded by another app (Proxy Deck)", button: "Usage…", action: { go(.usage) })
            case .attention(let why):
                CheckRow(state: .missing, title: "Usage history", detail: why, button: "Usage…", action: { go(.usage) })
            case .off:
                CheckRow(state: .optional, title: "Usage history", detail: "Optional", button: "Usage…", action: { go(.usage) })
            }
        } header: { Text("Checklist") } footer: {
            Text("Checks update live. T3 Proxy only talks to 127.0.0.1.").font(.footnote).foregroundStyle(.secondary)
        }
        Section("1 · Install and run the hub") {
            step("T3 Proxy reads CLIProxyAPI, the local hub your tools send requests through. Install it with Homebrew:")
            code("brew install cliproxyapi")
            step("Start it however you like (for example as a Homebrew service). T3 Proxy never starts it or runs commands.")
        }
        Section("2 · Port") {
            step("The hub listens on 127.0.0.1:\(port). If the hub's config.yaml sets another port (the top-level port: key), change it in Settings → Connection. Only loopback is supported.")
        }
        Section("3 · Management key") {
            step("In the hub's config.yaml, set remote-management → secret-key, then restart the hub. Paste that secret in Settings → Connection. It is stored in the Keychain and sent only to 127.0.0.1.")
            step("After a rejected key, nothing is sent until you enter a different one, so the hub doesn't lock this Mac out.")
        }
        Section("Optional") {
            step("T3 Code: connect it in Settings → T3 Code to see threads that need you in the panel's Threads tab.")
            step("Usage history: turn on recording in Settings → Usage to keep token and cost history over time.")
        }
    }
    private func step(_ s: String) -> some View { Text(s).fixedSize(horizontal: false, vertical: true) }
    private func code(_ s: String) -> some View { Text(s).monospaced().textSelection(.enabled) }
}
