import SwiftUI
import AppKit
import UniformTypeIdentifiers
import T3ProxyCore

/// All management operations, including polling and cancellation, use the Monitor's shared gate.
struct AddAccountPane: View {
    @ObservedObject var monitor: Monitor
    /// Sign-in state outlives the pane: Settings swaps panes out (destroying `@State`), and a hub
    /// session started here must still be visible and cancellable when the user comes back.
    @ObservedObject private var store = AddAccountStore.shared
    private var phases: [OAuthProvider: Phase] { get { store.phases } nonmutating set { store.phases = newValue } }
    private var callback: String { get { store.callback } nonmutating set { store.callback = newValue } }
    private var sending: Bool { get { store.sending } nonmutating set { store.sending = newValue } }
    private var notice: String? { get { store.notice } nonmutating set { store.notice = newValue } }
    private var poller: Task<Void, Never>? { get { store.poller } nonmutating set { store.poller = newValue } }
    private var visible: Bool { get { store.visible } nonmutating set { store.visible = newValue } }
    @State private var choosingFile = false
    @State private var pendingImport: ImportFile?
    @State private var location = ""

    enum Phase: Equatable {
        case idle, choosing, confirming, starting, cancelling
        case waiting(OAuthSession, Date)
        case done
        case failed(String)

        var busy: Bool {
            switch self {
            case .choosing, .confirming, .starting, .cancelling, .waiting: true
            default: false
            }
        }
    }
    private struct ImportFile { let data: Data; let name: String; let location: String }

    private var busy: Bool { sending || phases.values.contains(where: \.busy) }
    private var locked: Bool { monitor.management == .rejected || !monitor.hasKey }
    private var session: OAuthSession? {
        for phase in phases.values { if case .waiting(let s, _) = phase { return s } }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sign in with a provider to add an account to your local proxy. Finish in your browser, enter a device code, or import a service-account file.")
                    .foregroundStyle(.secondary)
                if locked {
                    Label(monitor.hasKey ? "Management key rejected. Check Connection." : "Set a management key in Connection first.", systemImage: "key.slash")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 166), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(OAuthProvider.allCases) { provider in card(provider) }
                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
        .navigationTitle("Add Account")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in chooseFile(result) }
        .confirmationDialog("Import Vertex service account?", isPresented: Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil; if phases[.vertex] == .confirming { phases[.vertex] = .idle } } }
        ), titleVisibility: .visible, presenting: pendingImport) { file in
            Button("Import Account") { importFile(file) }
            Button("Cancel", role: .cancel) { pendingImport = nil; phases[.vertex] = .idle }
        } message: { file in
            Text("Send “\(file.name.emailHidden)” to the local hub to add a Vertex AI account\(file.location.isEmpty ? "" : " in \(file.location)")? The file contains service-account credentials.")
        }
        .onAppear {
            visible = true
            if let s = session, case .waiting(_, let deadline) = phases[s.provider] { poll(s, until: deadline) }
        }
        .onDisappear {
            visible = false
            poller?.cancel(); poller = nil
            callback = ""
            pendingImport = nil
            if phases[.vertex] == .confirming || phases[.vertex] == .choosing {
                phases[.vertex] = .idle; choosingFile = false
            }
            // A hub session keeps running. Only the explicit Cancel action cancels it.
        }
    }

    private func card(_ p: OAuthProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                ProviderMark(provider: p == .claude ? .claude : p == .codex ? .codex : .other, size: 22, name: p.markName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.headline)
                    Text(p.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            cardStatus(p)
            if !(phases[p] ?? .idle).busy {
                if p == .vertex {
                    TextField("Location (optional)", text: $location, prompt: Text("us-central1"))
                        .textFieldStyle(.roundedBorder).disabled(busy || locked)
                }
                Button("Start") { start(p) }
                    .disabled(busy || locked || (p == .vertex && !OAuthRules.isValidLocation(location.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private func cardStatus(_ p: OAuthProvider) -> some View {
        switch phases[p] ?? .idle {
        case .idle: EmptyView()
        case .choosing: Text("Choose a JSON file…").foregroundStyle(.secondary)
        case .confirming: Text("Waiting for confirmation…").foregroundStyle(.secondary)
        case .starting, .cancelling:
            HStack { ProgressView().controlSize(.small); Text(phases[p] == .cancelling ? "Cancelling…" : "Starting…") }
        case .done:
            Label("Account added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .waiting(let s, let deadline):
            waiting(s, until: deadline)
        }
    }

    private func waiting(_ s: OAuthSession, until deadline: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.userCode == nil ? "Waiting for browser sign-in…" : "Enter this code on the verification page.")
                .font(.callout).foregroundStyle(.secondary)
            if let code = s.userCode {
                Text(code).font(.system(size: 23, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    .minimumScaleFactor(0.5).lineLimit(1)
                Button("Copy Code", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            Button(s.userCode == nil ? "Open Sign-in Page" : "Open Verification Page", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(s.url)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(deadline.timeIntervalSince(context.date)))
                Text("Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if s.provider.method == .browser {
                DisclosureGroup("Browser didn't return?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copy the full redirect address from your browser and paste it here.").font(.caption).foregroundStyle(.secondary)
                        TextField("Redirect URL", text: $store.callback).textFieldStyle(.roundedBorder).onSubmit(submit)
                        Button(sending ? "Sending…" : "Send Callback", action: submit)
                            .disabled(sending || locked || !OAuthRules.isValidRedirect(callback))
                    }
                }
            }
            Button("Cancel", role: .cancel) { cancel(s, deadline: deadline) }.disabled(sending)
        }
    }

    private func start(_ p: OAuthProvider) {
        guard !busy, !locked else { return }
        callback = ""; notice = nil
        if p.method == .importFile {
            phases[p] = .choosing; choosingFile = true
            return
        }
        phases[p] = .starting
        // Do not cancel this request when leaving: cancellation could lose an already-created hub session.
        Task {
            do {
                let s = try await monitor.management { try await $0.startOAuth(p, key: $1) }
                let deadline = Date().addingTimeInterval(s.expiresIn ?? 600)
                phases[p] = .waiting(s, deadline)
                // The user asked for this sign-in, so the page opens even if they switched panes meanwhile;
                // polling resumes when the pane is shown again.
                if p.method == .browser { NSWorkspace.shared.open(s.url) }
                if visible { poll(s, until: deadline) }
            } catch { phases[p] = .failed(Self.message(error)) }
        }
    }

    private func poll(_ s: OAuthSession, until deadline: Date) {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(s.pollInterval)) } catch { return }
                guard !Task.isCancelled, visible, session?.state == s.state else { return }
                if Date() >= deadline { phases[s.provider] = .failed("The sign-in session expired. Start again."); return }
                do {
                    let status = try await monitor.management { try await $0.oauthStatus(state: s.state, key: $1) }
                    guard !Task.isCancelled, visible, session?.state == s.state else { return }
                    switch status {
                    case .wait: continue
                    case .ok:
                        phases[s.provider] = .done; callback = ""
                        await monitor.refresh(); return
                    case .error(let message): phases[s.provider] = .failed(message); callback = ""; return
                    }
                } catch {
                    guard !Task.isCancelled, visible, session?.state == s.state else { return }
                    if error is ManagementError || error as? ProxyError == .unauthorized {
                        phases[s.provider] = .failed(Self.message(error)); return
                    }
                    // A transient missed status read is retried until the fixed deadline.
                }
            }
        }
    }

    private func cancel(_ s: OAuthSession, deadline: Date) {
        guard session?.state == s.state, !sending else { return }
        poller?.cancel(); poller = nil
        phases[s.provider] = .cancelling; callback = ""
        Task {
            do {
                let cancelled = try await monitor.management { try await $0.cancelOAuth(state: s.state, key: $1) }
                if cancelled { phases[s.provider] = .idle; notice = "Sign-in cancelled."; return }
                notice = "The hub did not cancel the session. Checking its status."
            } catch { notice = Self.message(error) }
            phases[s.provider] = .waiting(s, deadline)
            if visible { poll(s, until: deadline) }
        }
    }

    private func submit() {
        guard let s = session, s.provider.method == .browser,
              !sending, !locked, OAuthRules.isValidRedirect(callback) else { return }
        let raw = callback
        sending = true
        Task {
            do {
                try await monitor.management { try await $0.submitOAuthCallback(s.provider, redirectURL: raw, key: $1) }
                callback = ""; notice = "Callback sent. Waiting for the hub to finish."
            } catch { notice = Self.message(error) }
            sending = false
        }
    }

    private func chooseFile(_ result: Result<URL, Error>) {
        guard phases[.vertex] == .choosing else { return }
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= OAuthRules.importMaxBytes else {
                throw OAuthError.invalidImport
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: OAuthRules.importMaxBytes + 1) ?? Data()
            try OAuthRules.validateImport(data, name: url.lastPathComponent)
            let region = location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard OAuthRules.isValidLocation(region) else { throw OAuthError.invalidLocation }
            pendingImport = ImportFile(data: data, name: url.lastPathComponent, location: region)
            phases[.vertex] = .confirming
        } catch {
            if (error as NSError).code == NSUserCancelledError { phases[.vertex] = .idle }
            else { phases[.vertex] = .failed(Self.message(error)) }
        }
    }

    private func importFile(_ file: ImportFile) {
        guard !locked else { pendingImport = nil; phases[.vertex] = .idle; return }
        pendingImport = nil; phases[.vertex] = .starting
        Task {
            do {
                try await monitor.management {
                    try await $0.importOAuthFile(file.data, name: file.name, location: file.location, confirmed: true, key: $1)
                }
                phases[.vertex] = .done
                await monitor.refresh()
            } catch { phases[.vertex] = .failed(Self.message(error)) }
        }
    }

    static func message(_ e: Error) -> String {
        switch e {
        case ManagementError.locked: "No accepted management key. Check Connection."
        case ProxyError.unauthorized: "The proxy rejected the management key."
        case ProxyError.unreachable: "The proxy isn't reachable."
        case ProxyError.http(let c): "The hub answered HTTP \(c)."
        case OAuthError.untrustedURL: "The hub returned an untrusted sign-in address. It was not opened."
        case OAuthError.invalidState: "The hub returned an invalid sign-in session."
        case OAuthError.invalidDeviceCode: "The hub returned an invalid device code. Start again."
        case OAuthError.invalidRedirect: "Paste the full callback URL from the browser's address bar."
        case OAuthError.invalidImport: "Choose a JSON object in a .json file up to 256 KB with a simple filename."
        case OAuthError.invalidLocation: "Location must look like us-central1."
        case OAuthError.confirmationRequired: "Confirm the service-account import first."
        default: "The operation could not finish. Check the file or try again."
        }
    }
}

/// Shared sign-in state for `AddAccountPane` (see the note on its `store`).
@MainActor final class AddAccountStore: ObservableObject {
    static let shared = AddAccountStore()
    @Published var phases: [OAuthProvider: AddAccountPane.Phase] = [:]
    @Published var callback = ""
    @Published var sending = false
    @Published var notice: String?
    var poller: Task<Void, Never>?
    var visible = false
}
