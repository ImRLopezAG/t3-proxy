import SwiftUI
import AppKit
import UserNotifications
import T3ProxyCore

/// Which alerts post a notification, the low-quota threshold, and the notification permission.
struct NotificationsPane: View {
    @ObservedObject var notifier: Notifier

    init(monitor: Monitor) {
        _notifier = ObservedObject(wrappedValue: Notifier.shared(for: monitor, live: LiveQuotaModel.shared(for: monitor)))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Text(statusText).foregroundStyle(.secondary)
                        switch notifier.authorization {
                        case .notDetermined:
                            Button("Allow Notifications…") { Task { await notifier.requestPermission() } }
                                .disabled(!notifier.notificationsAvailable)
                        case .denied:
                            Button("Open System Settings…") { openSystemSettings() }
                        default:
                            Button("Send Test") { notifier.sendTest() }
                        }
                    }
                }
            } header: { Text("Permission") } footer: {
                Text("T3 Proxy asks the first time an alert would be shown. Notifications contain account nicknames only, never email addresses.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ForEach(AlertKind.proxyKinds) { k in toggle(k) }
                Picker("Warn when remaining is at or below", selection: $notifier.settings.threshold) {
                    ForEach([5.0, 10, 15, 20, 25], id: \.self) { Text("\(Int($0))%").tag($0) }
                }
                .disabled(!notifier.settings.isOn(.lowQuota))
            } header: { Text("Alerts") } footer: {
                Text("Each alert is shown once per account and limit period: low quota and used up for the 5-hour and weekly limits, a banked reset expiring within 48 hours, an account going on hold, and the proxy stopping and coming back. Nothing is shown at launch for things you were already told about.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ForEach(AlertKind.t3CodeKinds) { k in toggle(k) }
            } header: { Text("T3 Code threads") } footer: {
                Text("Shown once each time a thread changes to that state, with the thread title and project only. States that already held when T3 Proxy started aren't announced. Clicking one opens the thread in T3 Code.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task { await notifier.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
    }

    private func toggle(_ k: AlertKind) -> some View {
        Toggle(k.title, isOn: Binding(get: { notifier.settings.isOn(k) }, set: { notifier.settings.set(k, on: $0) }))
    }

    private var statusText: String {
        guard notifier.notificationsAvailable else { return "Unavailable outside the app bundle" }
        switch notifier.authorization {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Turned off in System Settings"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
