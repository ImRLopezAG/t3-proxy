import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var settingsScrollOffset: CGFloat = 0
}

private struct SettingsQuotaDetails<Card: View>: ViewModifier {
    let inspect: () -> Void
    let card: () -> Card
    @State private var presented = false
    @State private var rowHovered = false
    @State private var cardHovered = false
    @State private var transition: Task<Void, Never>?
    @Environment(\.settingsScrollOffset) private var scrollOffset

    func body(content: Content) -> some View {
        Button(action: pin) { content }
            .buttonStyle(.plain)
            .onHover { inside in
                rowHovered = inside
                transition?.cancel()
                if inside {
                    transition = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, rowHovered else { return }
                        presented = true
                    }
                } else { closeAfterTransit() }
            }
            .accessibilityAction(named: "Show Details") { pin() }
            .popover(isPresented: $presented, arrowEdge: .trailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        card()
                        Button("Pin account details", systemImage: "sidebar.trailing") { pin() }
                    }.padding(18)
                }
                .frame(width: 350, height: 450)
                .onHover { inside in
                    cardHovered = inside
                    if inside { transition?.cancel() } else { closeAfterTransit() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in dismiss() }
            .onChange(of: scrollOffset) { _, _ in dismiss() }
            .onDisappear { dismiss() }
    }

    private func pin() { dismiss(); inspect() }
    private func dismiss() { transition?.cancel(); transition = nil; presented = false; cardHovered = false }
    private func closeAfterTransit() {
        transition?.cancel()
        transition = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, !rowHovered, !cardHovered else { return }
            presented = false
        }
    }
}

extension View {
    @ViewBuilder func settingsQuotaDetails<Card: View>(enabled: Bool = true, inspect: @escaping () -> Void,
                                                       @ViewBuilder card: @escaping () -> Card) -> some View {
        if enabled { modifier(SettingsQuotaDetails(inspect: inspect, card: card)) } else { self }
    }
}
