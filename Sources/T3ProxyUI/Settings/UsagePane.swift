import SwiftUI
import T3ProxyCore

/// T3 Proxy's own usage recorder: opt-in, because reading the hub's usage queue removes the records for any other
/// app reading it. Disabled (and explained) while Proxy Deck's database is present.
struct UsageRecordingSection: View {
    @ObservedObject private var recorder = UsageRecorderModel.shared
    private var blocked: Bool { UsageRecorder.otherRecorderPresent() }

    var body: some View {
        Section {
            Toggle("Record usage history", isOn: $recorder.enabled).disabled(blocked)
            LabeledContent("Status") {
                Label(statusText, systemImage: statusSymbol).foregroundStyle(statusColor)
            }
        } header: { Text("Recording") } footer: {
            Text(blocked
                 ? "Another app (Proxy Deck) already records this hub's usage, and T3 Proxy reads its history. T3 Proxy won't read the hub's usage queue while that app's database is present."
                 : "T3 Proxy reads the hub's usage queue every 30 seconds and keeps the history on this Mac (Application Support/T3 Proxy). Reading the queue removes the records from it, so leave this off if another app records usage from the same hub. Needs the hub's \"Usage statistics\" setting (Settings → CLIProxyAPI → Configuration).")
        }
    }

    private var statusText: String {
        if blocked { return "Another app records usage" }
        switch recorder.status {
        case .off: return "Off"
        case .blockedByOtherRecorder: return "Another app records usage"
        case .waitingForHub: return "Waiting for the hub"
        case .recording(let last, let total):
            let when = last.map { " · last \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return "Recording · \(total.formatted()) requests\(when)"
        case .statisticsDisabled: return "The hub's usage statistics are off"
        case .keyRejected: return "The management key was rejected"
        case .unsupported: return "This hub has no usage queue"
        case .failed(let m): return m
        }
    }
    private var statusSymbol: String {
        switch recorder.status {
        case .recording: "record.circle"
        case .off: "pause.circle"
        case .waitingForHub: "clock"
        default: blocked ? "person.2.circle" : "exclamationmark.triangle"
        }
    }
    private var statusColor: Color {
        switch recorder.status {
        case .recording: .green
        case .off, .waitingForHub: .secondary
        default: blocked ? .secondary : .orange
        }
    }
}
