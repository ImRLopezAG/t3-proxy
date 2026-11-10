import Foundation
import Combine

@MainActor
public final class Monitor: ObservableObject {
    @Published public private(set) var reachability: Reachability = .unknown
    @Published public private(set) var management: ManagementState = .noKey
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var accountsUpdatedAt: Date?
    @Published public private(set) var refreshing = false
    @Published public var interval: TimeInterval = 60 { didSet { schedule() } }

    public private(set) var client: ProxyClient
    public private(set) var managementClient: ManagementClient
    /// Published so views showing the endpoint update when the port changes.
    @Published public private(set) var endpoint: ProxyEndpoint
    private let store: KeyStore
    private var timer: Timer?
    /// Bumped when the key is saved or removed; results from reads started earlier are dropped.
    private var keyGeneration = 0
    private var refreshAgain = false
    /// Latest live quota reads by Account.id (LiveQuotaService), merged over the hub's recorded quota.
    private var live: [String: QuotaReading] = [:]

    public init(client: ProxyClient = .init(), store: KeyStore = KeychainKeyStore(), management: ManagementClient? = nil) {
        self.client = client; self.store = store; self.endpoint = client.endpoint
        var m = management ?? ManagementClient(endpoint: client.endpoint)
        m.gate = client.gate   // one lock for polling and Settings
        self.managementClient = m
    }

    public var hasKey: Bool { store.load() != nil }

    /// The only way to send a management request. Shares the rejected-key lock with polling:
    /// nothing is sent without a key or after a 401/403, and a 401/403 here locks polling too.
    public func management<T: Sendable>(_ op: (ManagementClient, String) async throws -> T) async throws -> T {
        guard let key = store.load(), client.gate.permits(key) else {
            if let k = store.load(), !client.gate.permits(k) { lockOut() }
            throw ManagementError.locked
        }
        do { return try await op(managementClient, key) } catch {
            if !client.gate.permits(key) { lockOut() }
            throw error
        }
    }

    public var endpointLabel: String { endpoint.label }

    /// Points polling and management at another loopback port. Like a key change, this bumps the key epoch,
    /// so reads started against the old port never publish, and live readings are dropped. The new hub gets a
    /// fresh rejected-key lock (a rejection by one hub says nothing about another); both clients share it.
    public func setEndpoint(_ e: ProxyEndpoint) async {
        guard e != endpoint else { return }
        let classes = client.session.configuration.protocolClasses
        var c = ProxyClient(endpoint: e, protocolClasses: classes)
        c.gate = AuthGate()
        var m = ManagementClient(endpoint: e, protocolClasses: managementClient.session.configuration.protocolClasses)
        m.gate = c.gate
        client = c; managementClient = m; endpoint = e
        keyGeneration += 1
        live = [:]; accounts = []; accountsUpdatedAt = nil
        management = .noKey; reachability = .unknown
        await refresh()
    }

    public func start() { schedule(); Task { await refresh() } }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func lockOut() { management = .rejected; accounts = []; accountsUpdatedAt = nil; live = [:] }

    /// Publishes live quota reads. A live reading replaces the recorded one unless the hub recorded something newer.
    /// Changes whenever the key is saved or removed; pass the value read before starting live reads.
    public var keyEpoch: Int { keyGeneration }

    public func applyLive(_ readings: [String: QuotaReading], epoch: Int) {
        guard management == .connected, epoch == keyGeneration else { return }
        for (id, r) in readings { live[id] = r }
        accounts = merged(accounts)
    }

    private func merged(_ list: [Account]) -> [Account] {
        list.map { a in
            guard let l = live[a.id], let seen = l.observedAt, seen >= (a.quota.observedAt ?? .distantPast) else { return a }
            var out = a
            var q = l
            if q.plan == nil { q.plan = a.quota.plan }
            out.quota = q
            return out
        }
    }

    public enum SetKeyResult: Sendable, Equatable { case saved, previouslyRejected, keychainFailed }

    /// A key the hub already rejected is not saved or sent again until the app restarts.
    @discardableResult
    public func setKey(_ key: String) async -> SetKeyResult {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return .keychainFailed }
        guard client.gate.permits(k) else { return .previouslyRejected }
        guard store.save(k) else { return .keychainFailed }
        keyGeneration += 1
        live = [:]
        management = .noKey   // clears a rejected lock for the new key
        await refresh()
        return .saved
    }

    public func removeKey() { keyGeneration += 1; store.remove(); management = .noKey; accounts = []; accountsUpdatedAt = nil; live = [:] }

    /// Reads never overlap. Without a key, or after a rejection, no management request is sent.
    public func refresh() async {
        // A refresh asked for during another (e.g. right after a key change) runs once it ends.
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }

        // Captured before the first await: a port or key change meanwhile bumps the generation, and this
        // read (against the old client) must then publish nothing. The change itself schedules a fresh refresh.
        let client = self.client
        let generation = keyGeneration
        let up = await client.health()
        guard generation == keyGeneration else { return }
        reachability = up ? .live : .offline
        guard up else { return }
        guard let key = store.load() else { management = .noKey; return }
        guard client.gate.permits(key) else { lockOut(); return }
        do {
            let fresh = try await client.accounts(key: key)
            // A read that finished after a key change, or after a rejection elsewhere, must not publish.
            guard generation == keyGeneration else { return }
            guard client.gate.permits(key) else { lockOut(); return }
            accounts = merged(fresh); accountsUpdatedAt = Date()
            management = .connected
        } catch where generation != keyGeneration {
            return
        } catch where !client.gate.permits(key) {
            lockOut()
        } catch ProxyError.incompatible {
            management = .failed("Unexpected response")
        } catch ProxyError.http(let c) {
            management = .failed("HTTP \(c)")
        } catch {
            management = .failed("Request failed")
        }
    }
}
