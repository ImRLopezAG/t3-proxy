import SwiftUI
import AppKit
import T3ProxyCore

/// "T3 Code": local server status and whether T3 Code's provider instances reach the hub.
/// Read-only: inspects ~/.t3/userdata and the provider homes; never writes them.
struct T3CodePane: View {
    @ObservedObject var monitor: Monitor
    @State private var status: T3CodeLocalStatus?
    @State private var loading = false
    @ObservedObject private var t3 = T3CodeModel.shared()

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if t3.busy || t3.status == .connecting { ProgressView().controlSize(.small) }
                        Text(t3.status.text).foregroundStyle(t3.status.isConnected ? .green : t3.status == .expired ? .orange : .secondary)
                    }
                }
                HStack {
                    Spacer()
                    if t3.hasSession {
                        if !t3.status.isConnected { Button("Reconnect") { t3.reconnect() }.disabled(t3.busy) }
                        Button("Disconnect") { Task { await t3.disconnect() } }.disabled(t3.busy)
                    } else {
                        Button("Connect") { Task { await t3.connect() } }.disabled(t3.busy).keyboardShortcut(.defaultAction)
                    }
                }
                if t3.hasPendingRevocations {
                    Text("Couldn't revoke the old T3 Code session").foregroundStyle(.orange)
                    Button("Revoke Old Session") { Task { await t3.revokeOldSessions() } }
                        .disabled(t3.revoking || t3.busy)
                }
            } header: { Text("Threads connection") } footer: {
                Text("Connect issues a 30-day T3 Code session that can read threads and stop or resume them. It's kept in the Keychain and only used on 127.0.0.1. Disconnect revokes it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let status {
                    Label(status.summary, systemImage: status.problems == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.problems == 0 ? .green : .orange)
                        .font(.headline)
                } else {
                    Text(loading ? "Checking…" : "Not checked yet").foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Status") { running }
                LabeledContent("Version", value: status?.version ?? "Unknown")
                LabeledContent("Uptime") { uptime }
                if let host = status?.host, let port = status?.port {
                    LabeledContent("Listening on") { Text(host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)").monospaced() }
                }
                if status?.exposed == true {
                    Label("T3 Code is reachable from the local network, not just this Mac.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Button("Open T3 Code") { Self.openApp() }.disabled(Self.appURL == nil)
            } header: { Text("Server") }
            Section {
                if let checks = status?.checks, !checks.isEmpty {
                    ForEach(checks) { row($0) }
                } else if status != nil {
                    Text("Nothing to check.").foregroundStyle(.secondary)
                }
            } header: { Text("Connection to the hub") } footer: {
                Text("Keys are compared by digest in memory and are never shown. Nothing in T3 Code's settings is changed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("T3 Code")
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var running: some View {
        if status?.running == true {
            Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
        } else {
            Label(status == nil ? "Unknown" : "Not running", systemImage: "circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var uptime: some View {
        if status?.running == true, let start = status?.startedAt {
            Text(start, style: .relative)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func row(_ c: T3CodeCheck) -> some View {
        LabeledContent {
            Text(c.message).multilineTextAlignment(.trailing)
        } label: {
            Label {
                Text(c.title)
            } icon: {
                Image(systemName: c.state == .ok ? "checkmark.circle.fill" : c.state == .warning ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(c.state == .ok ? .green : c.state == .warning ? .orange : .red)
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let m = monitor
        status = await T3CodeLocal.inspect { await m.t3CodeHubKeys() }
    }

    /// Prefers the stable app, then Nightly, by bundle id; falls back to the known install paths.
    static var appURL: URL? {
        let ws = NSWorkspace.shared
        for id in ["com.t3tools.t3code.stable", "com.t3tools.t3code"] {
            if let u = ws.urlForApplication(withBundleIdentifier: id) { return u }
        }
        for p in ["/Applications/T3 Code.app", "/Applications/T3 Code (Nightly).app"] where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func openApp() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
