import SwiftUI
import T3ProxyCore

struct QuotaPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var live: LiveQuotaModel

    var body: some View {
        Group {
            if monitor.accountsUpdatedAt == nil {
                ContentUnavailableView {
                    Label("No Quota Readings", systemImage: "gauge.with.dots.needle.0percent")
                } description: {
                    Text(monitor.management == .connected ? "Waiting for the first read." : "Add a management key to read quota from the proxy.")
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LiveQuotaDashboard(accounts: monitor.accounts, endpoint: monitor.endpointLabel, now: context.date,
                                           live: live, connected: monitor.management == .connected)
                            .padding(20).overlayScroller()
                    }
                }
            }
        }
        .navigationTitle("Quota")
        .toolbar {
            ToolbarItem {
                Button { Task { await live.refresh() } } label: {
                    if live.refreshing { ProgressView().controlSize(.small) }
                    else { Label("Read Live Quota", systemImage: "arrow.clockwise") }
                }
                .help("Ask Claude and Codex for each account's current quota")
                .disabled(live.refreshing || monitor.management != .connected)
            }
        }
        .task(id: monitor.management) { if monitor.management == .connected { await live.refresh() } }
    }
}
