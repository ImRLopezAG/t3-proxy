import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI
import T3ProxyCore

/// One registration, shared with Connection settings. Carbon hotkeys require no Accessibility access.
@MainActor
public final class NativePanelShortcut: ObservableObject {
    public static let shared = NativePanelShortcut()
    @Published public private(set) var shortcut = NativeHotKey.load()
    @Published public private(set) var error: String?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    public func start(action: @escaping () -> Void) {
        self.action = action
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == 0x54335058, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<NativePanelShortcut>.fromOpaque(context).takeUnretainedValue().action?()
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { error = "Couldn't install the shortcut handler (\(status))."; return }
        }
        register(shortcut)
    }

    private func register(_ value: NativeHotKey?) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        error = nil
        guard let value, action != nil else { return }
        let status = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x54335058, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { error = "Shortcut unavailable (\(status)). Choose another combination." }
    }
    public func set(_ value: NativeHotKey?) {
        guard value?.isValid != false else { error = "Include Command, Option, or Control."; return }
        let previous = shortcut
        register(value)
        if let failure = error {
            register(previous)
            error = failure
            return
        }
        shortcut = value
        NativeHotKey.save(value)
    }
    public func suspend() { if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil } }
    public func resume() { register(shortcut) }
}

@MainActor
private final class NativeRecorderButton: NSButton {
    var receive: ((NativeHotKey) -> Void)?
    var finished: (() -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; finished?() }
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; finished?(); return }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= NativeHotKey.command }
        if flags.contains(.option) { modifiers |= NativeHotKey.option }
        if flags.contains(.control) { modifiers |= NativeHotKey.control }
        if flags.contains(.shift) { modifiers |= NativeHotKey.shift }
        let value = NativeHotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: event.charactersIgnoringModifiers ?? "")
        guard value.isValid else { NSSound.beep(); return }
        recording = false; finished?(); receive?(value)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}

private struct NativeShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: NativePanelShortcut
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSButton {
        let button = NativeRecorderButton(title: "Record…", target: context.coordinator, action: #selector(Coordinator.record(_:)))
        button.bezelStyle = .rounded
        button.receive = { [weak model] value in model?.set(value) }
        button.finished = { [weak model, weak button] in model?.resume(); button?.title = "Record…" }
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {}
    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) { coordinator.model.resume() }
    @MainActor final class Coordinator: NSObject {
        let model: NativePanelShortcut
        init(model: NativePanelShortcut) { self.model = model }
        @objc func record(_ sender: NativeRecorderButton) {
            model.suspend(); sender.recording = true; sender.title = "Type shortcut (Esc cancels)"
            sender.window?.makeFirstResponder(sender)
        }
    }
}

struct NativeConnectionSections: View {
    @AppStorage("nativeMenuBarMode") private var menuMode = NativeMenuBarMode.icon.rawValue
    @ObservedObject private var shortcut = NativePanelShortcut.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Section("Menu bar") {
            Picker("Show", selection: $menuMode) {
                ForEach(NativeMenuBarMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Text("Lowest measured remaining quota across the pooled 5-hour and weekly windows. Expired or unknown readings are excluded; — means no current reading.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Launch at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLogin))
            LabeledContent("Status", value: loginLabel)
            if loginStatus == .requiresApproval {
                Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let loginError { Text(loginError).foregroundStyle(.orange) }
        } header: { Text("Startup") } footer: {
            Text("Uses macOS Login Items. This app is ad-hoc signed; macOS may require approval or reject registration. Keep the app at a stable installed location and check Login Items after replacing a build.")
        }
        Section {
            LabeledContent("Open panel") {
                HStack {
                    Text(shortcut.shortcut?.label ?? "None").monospaced()
                    NativeShortcutRecorder(model: shortcut).fixedSize()
                    Button("Clear") { shortcut.set(nil) }.disabled(shortcut.shortcut == nil)
                }
            }
            if let error = shortcut.error { Text(error).foregroundStyle(.orange) }
        } header: { Text("Keyboard shortcut") } footer: {
            Text("Default: ⌃⌥⌘P (⌥⌘P is Finder's path bar shortcut). Uses a registered global hotkey, without Accessibility permission. If another app already uses it, choose another shortcut.")
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onChange(of: scenePhase) { _, _ in loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginStatus = SMAppService.mainApp.status }
    }
    private var loginLabel: String {
        switch loginStatus { case .enabled: "Enabled"; case .notRegistered: "Off"; case .requiresApproval: "Approval required in Login Items"; case .notFound: "App unavailable for registration"; @unknown default: "Unknown" }
    }
    private func setLogin(_ enabled: Bool) {
        loginError = nil
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            } catch { loginError = "macOS couldn't change the login item. Check Login Items and the app's signing and installation location." }
            loginStatus = SMAppService.mainApp.status
        }
    }
}
