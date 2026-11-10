import Foundation
import SwiftUI
import T3ProxyCore

@MainActor
final class HubUpdateModel: ObservableObject {
    @Published private(set) var installation: HubUpdateInstallation?
    @Published private(set) var running = false
    @Published private(set) var output = ""
    @Published private(set) var result: String?
    private var inspecting = false
    private var operation: Task<Void, Never>?
    private var secrets: [String] = []
    func inspect(managementKey: String? = nil) async {
        guard !inspecting, !running else { return }
        secrets = managementKey.map { [$0] } ?? []
        inspecting = true; defer { inspecting = false }
        do { installation = try await HubUpdater(runner: HomebrewCommandRunner(secrets: secrets)).installation() }
        catch { installation = nil; result = error.localizedDescription }
    }
    func cancel() { operation?.cancel() }
    /// The caller must present confirmation before invoking this method.
    func update(managementKey: String? = nil) async {
        guard !running, installation != nil else { return }
        secrets = managementKey.map { [$0] } ?? []
        running = true; output = ""; result = nil
        let updater = HubUpdater(runner: HomebrewCommandRunner(secrets: secrets))
        let task = Task { [weak self] in
            guard let self else { return }
            defer { running = false; operation = nil }
            let emit: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor [weak self] in self?.append(line) }
            }
            do {
                guard try await updater.installation() != nil else {
                    result = "Homebrew installation could not be verified."; return
                }
                try await updater.update(line: emit)
                installation = try await updater.installation()
                result = "Homebrew update and service restart completed. Check the hub version after it reconnects."
            } catch {
                result = error is CancellationError ? HubCommandError.cancelled.localizedDescription : error.localizedDescription
            }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func append(_ line: String) {
        output += HubUpdateOutput.redact(line, secrets: secrets) + "\n"
        if output.count > 100_000 { output = "[Earlier output omitted]\n" + String(output.suffix(80_000)) }
    }
}

struct HubUpdateSheet: View {
    @ObservedObject var model: HubUpdateModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Update CLIProxyAPI").font(.headline); Spacer(); if model.running { ProgressView().controlSize(.small) } }
            ScrollView { Text(model.output.isEmpty ? "Preparing Homebrew…" : model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let result = model.result { Text(result).font(.callout) }
            HStack { Spacer(); if model.running { Button("Cancel", role: .cancel) { model.cancel() } }; Button("Done") { dismiss() }.disabled(model.running) }
        }.padding(20).frame(width: 650, height: 430).interactiveDismissDisabled(model.running)
    }
}
