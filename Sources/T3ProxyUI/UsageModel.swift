import Foundation
import SwiftUI
import T3ProxyCore

/// Daily token history for the panel and the Usage pane. Reads happen off the main thread.
@MainActor
public final class UsageModel: ObservableObject {
    public enum State: Equatable { case loading, loaded, missing, failed(String) }
    @Published public private(set) var days: [UsageDay] = []
    @Published public private(set) var state: State = .loading
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var ranges: [Int: UsageRangeDetail] = [:]
    @Published public private(set) var rangeError: String?
    /// One model shared by the panel and the Settings pane.
    public static let shared = UsageModel()
    /// Re-chosen at every refresh (see `selectSource`), so history follows Proxy Deck appearing or going away.
    public private(set) var source: any UsageSource
    private let injected: Bool
    private var sourcePath: String?
    /// Bumped when the source changes: reads started against the old file publish nothing.
    private var sourceGeneration = 0
    /// Tokens for the panel's headline `range`; nil until loaded or when the DB is unavailable.
    @Published public private(set) var recent: RecentUsage?
    /// Remembered across launches; changing it reloads the headline.
    @Published public var range: TokenRange = TokenRange(rawValue: UserDefaults.standard.string(forKey: "tokenRange") ?? "") ?? .today {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: "tokenRange")
            if range != oldValue { recentInFlight = false; refreshRecent() }
        }
    }
    private var timer: Timer?
    private var inFlight = false, recentInFlight = false
    private var rangesInFlight = false

    /// The DB path can be overridden with `defaults write <bundle id> usageDatabasePath <path>`.
    public init(source: (any UsageSource)? = nil) {
        injected = source != nil
        let path = Self.selectedPath()
        sourcePath = source == nil ? path : nil
        self.source = source ?? SQLiteUsageSource(path: path)
    }

    /// Proxy Deck's history while its recorder is active (it owns the hub's usage queue), else T3 Proxy's own recording.
    /// `usageDatabasePath` overrides both.
    private static func selectedPath() -> String {
        if let override = UserDefaults.standard.string(forKey: "usageDatabasePath") { return override }
        return ProxyDeckDetector.shared.cachedState == .active
            ? SQLiteUsageSource.proxyDeckPath : UsageRecorder.defaultDatabaseURL.path
    }

    private func selectSource() {
        guard !injected else { return }
        let path = Self.selectedPath()
        guard path != sourcePath else { return }
        sourcePath = path
        source = SQLiteUsageSource(path: path)
        sourceGeneration += 1
        inFlight = false; recentInFlight = false; rangesInFlight = false
        days = []; ranges = [:]; recent = nil; state = .loading; invalidateDetails()
    }

    /// Refresh now and every few minutes after.
    public func start(every seconds: TimeInterval = 300) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Cheap query; called on every monitor tick and panel open so the hero stays fresh.
    public func refreshRecent() {
        selectSource()
        guard !recentInFlight else { return }
        recentInFlight = true
        let source = self.source, generation = sourceGeneration
        let range = self.range
        Task {
            let r = await Task.detached(priority: .utility) { () -> RecentUsage? in
                let p = range.plan()
                guard var r = try? source.series(start: p.start, width: p.width, count: p.count) else { return nil }
                // Same period, priced per model; the headline shows it under the tokens.
                r.cost = try? source.costs(start: p.start, end: p.start.addingTimeInterval(p.width * Double(p.count)))
                return r
            }.value
            guard generation == sourceGeneration else { return }   // the source changed meanwhile
            recentInFlight = false
            guard range == self.range else { return }   // a newer range was picked meanwhile
            recent = r
        }
    }

    public func refresh() {
        selectSource()
        refreshRecent()
        refreshRanges()
        guard !inFlight else { return }
        inFlight = true
        let source = self.source, generation = sourceGeneration
        Task {
            let r = await Task.detached(priority: .utility) {
                Result { () throws(UsageError) in try source.daily(days: 365, now: Date(), calendar: .current) }
            }.value
            guard generation == sourceGeneration else { return }
            inFlight = false
            switch r {
            case .success(let d): days = d; state = .loaded; invalidateDetails(); updatedAt = Date()
            case .failure(.missing): days = []; state = .missing; invalidateDetails()
            case .failure(.unreadable): days = []; state = .failed("Couldn't read the usage database."); invalidateDetails()
            }
        }
    }

    private func refreshRanges() {
        guard !rangesInFlight else { return }
        rangesInFlight = true
        let source = self.source, generation = sourceGeneration
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { () throws(UsageError) -> [Int: UsageRangeDetail] in
                    let now = Date(), calendar = Calendar.current
                    var values: [Int: UsageRangeDetail] = [:]
                    for days in [1, 7, 30] { values[days] = try source.rangeDetail(days: days, now: now, calendar: calendar) }
                    return values
                }
            }.value
            guard generation == sourceGeneration else { return }
            rangesInFlight = false
            switch result {
            case .success(let values): ranges = values; rangeError = nil
            case .failure: ranges = [:]; rangeError = "Couldn't read cost totals. Try reloading."
            }
        }
    }

    /// Day details already loaded, keyed by local midnight. Cleared on each daily refresh so today stays current.
    @Published public private(set) var details: [Date: UsageDayDetail] = [:]
    private var detailLoads: [Date: Task<UsageDayDetail?, Never>] = [:]
    private var detailGeneration = 0

    private func invalidateDetails() {
        detailGeneration += 1
        for task in detailLoads.values { task.cancel() }
        detailLoads = [:]; details = [:]
    }

    /// Loads one day's detail off the main thread, once per day; concurrent callers share the read.
    @discardableResult
    public func detail(for day: Date) async -> UsageDayDetail? {
        let key = Calendar.current.startOfDay(for: day)
        if let d = details[key] { return d }
        if let t = detailLoads[key] { return await t.value }
        let generation = detailGeneration
        let source = self.source
        let t = Task.detached(priority: .userInitiated) { try? source.dayDetail(day: key, calendar: .current) }
        detailLoads[key] = t
        let d = await t.value
        guard generation == detailGeneration else { return nil }
        detailLoads[key] = nil
        if let d { details[key] = d }
        return d
    }

    public func breakdown(for day: Date) async -> [UsageBreakdownRow] {
        let source = self.source
        return await Task.detached(priority: .userInitiated) { (try? source.breakdown(day: day, calendar: .current)) ?? [] }.value
    }
}
