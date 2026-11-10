import SwiftUI
import AppKit
import T3ProxyCore

struct ConnectionPane: View {
    @ObservedObject var monitor: Monitor
    @State private var keyDraft = ""
    @State private var editingKey = false
    @State private var saving = false
    @State private var keyError: String?
    @State private var confirmRemove = false
    @State private var portDraft = ""
    @State private var portError: String?

    private static let intervals: [(String, TimeInterval)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]

    var body: some View {
        Form {
            NativeConnectionSections()
            Section {
                LabeledContent("Endpoint") { Text(monitor.endpointLabel).monospaced().textSelection(.enabled) }
                LabeledContent("Port") {
                    HStack(spacing: 6) {
                        Text("127.0.0.1 :").monospaced().foregroundStyle(.secondary)
                        TextField("Port", text: $portDraft, prompt: Text(String(HubPort.defaultPort)))
                            .labelsHidden().monospacedDigit().frame(width: 72).multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(HubPort.parse(portDraft) == nil || HubPort.parse(portDraft) == monitor.endpoint.port)
                        Button("Default (\(String(HubPort.defaultPort)))") { portDraft = String(HubPort.defaultPort); applyPort() }
                            .disabled(monitor.endpoint.port == HubPort.defaultPort)
                    }
                }
                if let portError { Label(portError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                LabeledContent("Status") { reachability }
                Picker("Refresh every", selection: $monitor.interval) {
                    ForEach(Self.intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text("The port CLIProxyAPI listens on (port: in its config.yaml), \(String(HubPort.range.lowerBound))–\(String(HubPort.range.upperBound)). The host is always 127.0.0.1. Changing it reconnects; the key is checked again on the new port.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Management key") { keyStatus }
                if editingKey || !monitor.hasKey {
                    SecureField("Management key", text: $keyDraft, prompt: Text("Paste the CLIProxyAPI management key"))
                        .onSubmit(save)
                    HStack {
                        if let keyError { Label(keyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        Spacer()
                        if monitor.hasKey { Button("Cancel") { editingKey = false; keyDraft = "" } }
                        Button(monitor.hasKey ? "Replace Key" : "Set Key", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Replace…") { editingKey = true }
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                    }
                }
            } header: {
                Text("Management")
            } footer: {
                Text("Stored in the Keychain on this Mac only and sent only to 127.0.0.1. After a rejected key, T3 Proxy sends nothing until the key changes, because repeated failures make the proxy block this Mac for 30 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("T3 Proxy") {
                    Button("Quit T3 Proxy") { NSApp.terminate(nil) }
                }
            } footer: {
                Text("Quitting closes only this app; the proxy keeps running. You can also right-click the menu bar icon.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .onAppear { portDraft = String(monitor.endpoint.port) }
        .onChange(of: portDraft) { _, _ in portError = nil }
        .toolbar {
            ToolbarItem {
                Button { Task { await monitor.refresh() } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                    .disabled(monitor.refreshing)
            }
        }
        .confirmationDialog("Remove the management key?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) { monitor.removeKey(); keyDraft = "" }
        } message: {
            Text("Accounts and account settings stop loading until a key is set again.")
        }
    }

    @ViewBuilder private var reachability: some View {
        switch monitor.reachability {
        case .live: Label("Live", systemImage: "circle.fill").foregroundStyle(.green)
        case .offline: Label("Offline", systemImage: "circle.fill").foregroundStyle(.red)
        case .unknown: Label("Checking…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyStatus: some View {
        switch monitor.management {
        case .connected: Label("Accepted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .rejected: Label("Rejected — replace the key", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .noKey:
            if monitor.hasKey { Label("Saved, not checked yet", systemImage: "key.fill").foregroundStyle(.secondary) }
            else { Label("Not set", systemImage: "key.slash").foregroundStyle(.secondary) }
        }
    }

    private func applyPort() {
        guard let p = HubPort.parse(portDraft) else {
            portError = "Enter a whole number from \(String(HubPort.range.lowerBound)) to \(String(HubPort.range.upperBound))."; return
        }
        portError = nil
        HubPort.save(p)
        portDraft = String(p)
        Task { await monitor.setEndpoint(.configured()) }
    }

    private func save() {
        let k = keyDraft
        guard !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !saving else { return }
        saving = true; keyError = nil
        Task {
            switch await monitor.setKey(k) {
            case .saved: keyDraft = ""; editingKey = false
            case .previouslyRejected: keyError = "The proxy already rejected this key. It won't be sent again, to avoid a 30-minute lockout."
            case .keychainFailed: keyError = "Could not save the key to the Keychain."
            }
            saving = false
        }
    }
}
