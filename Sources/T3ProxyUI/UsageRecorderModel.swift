import Foundation
import Combine
import T3ProxyCore

/// Owns only the opt-in preference and polling. Monitor remains the sole owner of key access.
/// The lead starts this once at launch and binds Settings' toggle/status to the shared instance.
@MainActor
public final class UsageRecorderModel: ObservableObject {
    public static let shared = UsageRecorderModel()
    @Published public var enabled: Bool {
        didSet {
            if enabled && UsageRecorder.otherRecorderPresent() {
                enabled = false
                defaults.set(false, forKey: "usageRecorder.enabled")
                status = .blockedByOtherRecorder
                if let recorder { Task { await recorder.setEnabled(false); _ = await recorder.tick(key: "") } }
                return
            }
            defaults.set(enabled, forKey: "usageRecorder.enabled")
            if !enabled { status = .off }
            if let recorder {
                let value = enabled
                Task {
                    await recorder.setEnabled(value)
                    await poll()
                }
            }
        }
    }
    @Published public private(set) var status: UsageRecorderStatus = .off
    private let defaults: UserDefaults
    private weak var monitor: Monitor?
    private var recorder: UsageRecorder?
    private var timer: Timer?
    private var busy = false
    private var endpointWatch: AnyCancellable?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let requested = defaults.bool(forKey: "usageRecorder.enabled")
        let blocked = requested && UsageRecorder.otherRecorderPresent()
        enabled = requested && !blocked
        if blocked {
            status = .blockedByOtherRecorder
            defaults.set(false, forKey: "usageRecorder.enabled")
        }
    }

    public func start(monitor: Monitor) {
        guard recorder == nil else { return }
        self.monitor = monitor
        let recorder = UsageRecorder(databaseURL: UsageRecorder.defaultDatabaseURL, client: monitor.managementClient)
        self.recorder = recorder
        Task {
            await recorder.setEnabled(enabled)
            await poll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        // A port change in Settings: hand the recorder the new client at once, which also ends any tick that is
        // still talking to the old hub (it saves what it already received and pops nothing more).
        endpointWatch = monitor.$endpoint.dropFirst().removeDuplicates().sink { [weak self, weak monitor] _ in
            Task { @MainActor in
                guard let monitor, let recorder = self?.recorder else { return }
                await recorder.retarget(monitor.managementClient)
            }
        }
    }

    /// Quit: stop popping, let an in-flight batch finish, then save (or spool) what was received.
    public func prepareForQuit() async {
        timer?.invalidate(); timer = nil
        await recorder?.shutdown()
    }

    private func poll() async {
        guard !busy, let recorder else { return }
        busy = true
        defer { busy = false }
        guard enabled else {
            // An empty key can NEVER send a request, but still recovers a pending local write.
            let local = await recorder.tick(key: "")
            if case .failed = local { status = local }
            return
        }
        guard !UsageRecorder.otherRecorderPresent() else {
            status = await recorder.tick(key: "")
            return
        }
        guard let monitor else { status = .waitingForHub; return }
        do {
            let result = try await monitor.management { client, key in
                let result = await recorder.tick(key: key, client: client)
                // Let Monitor publish its shared rejected-key lock even though the actor returns status.
                if result == .keyRejected { throw ProxyError.unauthorized }
                return result
            }
            if enabled { status = result }
        } catch {
            let local = await recorder.tick(key: "")
            if enabled {
                if case .failed = local { status = local }
                else { status = monitor.management == .rejected ? .keyRejected : .waitingForHub }
            }
        }
    }
}
