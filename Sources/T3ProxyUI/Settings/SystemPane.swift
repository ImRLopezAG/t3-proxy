import SwiftUI
import AppKit
import T3ProxyCore

/// "About Proxy": Proxy Deck's SystemPage and a key-free Quick Start.
struct SystemPane: View {
    @ObservedObject var monitor: Monitor
    @State private var info: HubVersionInfo?
    @State private var error: String?
    @State private var loading = false
    @State private var copied: String?
    @StateObject private var updater = HubUpdateModel()
    @State private var confirmUpdate = false
    @State private var showUpdate = false
    @State private var usageIssue: String?

    private static let keyPlaceholder = "<your client key>"
    private var base: String { monitor.endpoint.base.absoluteString }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Endpoint") { Text(monitor.endpointLabel).monospaced().textSelection(.enabled) }
                LabeledContent("Version") { Text(info?.current ?? (loading ? "Checking…" : "Unknown")) }
                LabeledContent("Latest release") { latest }
                if let installation = updater.installation {
                    LabeledContent("Homebrew installed", value: installation.installed)
                    if let latest = installation.latest { LabeledContent("Homebrew available", value: latest) }
                    Button("Update via Homebrew…") { confirmUpdate = true }.disabled(updater.running)
                }
                LabeledContent("Management key") { keyStatus }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } header: { Text("CLIProxyAPI") } footer: {
                if let installed = updater.installation?.installed, let running = info?.current,
                   running.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) != installed.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) {
                    Text("The hub is running \(running) but Homebrew has \(installed) installed. Update via Homebrew restarts it on the installed version.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("Updates use your Homebrew installation.").font(.footnote).foregroundStyle(.secondary)
                if let message = updater.result, updater.installation == nil { Text(message).font(.footnote) }
            }
            Section("T3 Proxy") {
                LabeledContent("Version") { Text(appVersion) }
                if let usageIssue { LabeledContent("Usage history", value: usageIssue) }
            }
            Section {
                snippet("Claude Code", "export ANTHROPIC_BASE_URL='\(base)'\nexport ANTHROPIC_AUTH_TOKEN='\(Self.keyPlaceholder)'\nclaude")
                snippet("Codex (~/.codex/config.toml)", """
                    model_provider = "cliproxyapi"

                    [model_providers.cliproxyapi]
                    name = "CLIProxyAPI"
                    base_url = "\(base)/v1"
                    wire_api = "responses"
                    env_key = "CLIPROXYAPI_KEY"
                    """)
                snippet("Codex (shell)", "export CLIPROXYAPI_KEY='\(Self.keyPlaceholder)'\ncodex")
                snippet("OpenAI-compatible", "export OPENAI_BASE_URL='\(base)/v1'\nexport OPENAI_API_KEY='\(Self.keyPlaceholder)'")
            } header: {
                Text("Quick Start")
            } footer: {
                Text("Replace \(Self.keyPlaceholder) with one of the hub's client API keys (not the management key). T3 Proxy never shows or copies keys.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About Proxy")
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task {
            await load()
            // Monitor's management path has already resolved the per-launch Keychain cache.
            await updater.inspect(managementKey: KeychainKeyStore().load())
            let source = UsageModel.shared.source
            usageIssue = await Task.detached(priority: .utility) { () -> String? in
                do { _ = try source.daily(days: 1, now: Date(), calendar: .current); return Optional<String>.none }
                catch UsageError.unreadable(let message) where message == "usage database too large" { return message }
                catch { return nil }
            }.value
        }
        .confirmationDialog("Update the hub and restart its service?", isPresented: $confirmUpdate) {
            Button("Update and Restart", role: .destructive) {
                showUpdate = true
                Task { await updater.update(managementKey: KeychainKeyStore().load()); await load() }
            }
        } message: {
            Text("Runs brew upgrade cliproxyapi, then brew services restart cliproxyapi. Restarting briefly drops in-flight requests, including T3 Code requests. Finish active work before continuing.")
        }
        .sheet(isPresented: $showUpdate) { HubUpdateSheet(model: updater) }
    }

    @ViewBuilder private var latest: some View {
        if let l = info?.latest {
            if let c = info?.current, Self.newer(l, than: c) {
                Label("\(l) available", systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
            } else {
                Text(info?.current == nil ? l : "\(l) (up to date)")
            }
        } else {
            Text(loading ? "Checking…" : info == nil ? "Couldn't check" : "Not reported").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyStatus: some View {
        switch monitor.management {
        case .connected: Label("Accepted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .rejected: Label("Rejected", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .noKey: Text(monitor.hasKey ? "Not checked yet" : "Not set").foregroundStyle(.secondary)
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
            }
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            info = try await monitor.management { try await $0.versions(key: $1) }
            error = nil
        } catch {
            info = nil
            self.error = AddAccountPane.message(error)
        }
    }

    /// Numeric x.y.z comparison; suffixes are ignored.
    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { $0 == "v" }).split(separator: ".").prefix(3)
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        return parts(a).lexicographicallyPrecedes(parts(b)) == false && parts(a) != parts(b)
    }
}
