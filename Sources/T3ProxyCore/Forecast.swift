import Foundation

/// Port of Proxy Deck's burn-rate projection (src/pool.ts: burnRate + forecast), reduced to the question
/// the app shows: at the measured pace, does the pool run out before its next reset?
public enum PoolForecast: Sendable, Equatable {
    /// Every member reaches 0% at this time, before the soonest reset.
    case runsOut(Date)
    /// The pool still has quota when the soonest member reset arrives.
    case lastsUntilReset(Date)
}

public enum Forecast {
    /// Readings whose reset times differ by less than this describe the same window instance.
    static let sameResetTolerance: TimeInterval = 10 * 60
    /// How far back the consumption rate is measured.
    public static func burnWindow(_ kind: QuotaWindowKind) -> TimeInterval { kind == .session ? 3600 : 3 * 3600 }

    static func sameInstance(_ a: QuotaSample, _ b: QuotaSample) -> Bool {
        switch (a.resetAt, b.resetAt) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) <= sameResetTolerance
        default: return false
        }
    }

    /// Percentage points per hour per member, measured within one window instance. Nil unless every member has
    /// at least two readings of its latest instance spanning half the burn window (as in pool.ts).
    public static func burnRates(_ samples: [QuotaSample], members: [String], kind: QuotaWindowKind,
                                 burn: TimeInterval? = nil, now: Date) -> [String: Double]? {
        let burn = burn ?? burnWindow(kind)
        guard !members.isEmpty, burn > 0 else { return nil }
        let inRange = samples.filter { $0.kind == kind.rawValue && $0.observedAt >= now.addingTimeInterval(-burn) && $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        var out: [String: Double] = [:]
        for m in members {
            let own = inRange.filter { $0.key == m }
            guard let last = own.last else { return nil }
            let same = own.filter { sameInstance($0, last) }
            guard let first = same.first, same.count >= 2 else { return nil }
            let span = last.observedAt.timeIntervalSince(first.observedAt)
            guard span >= burn / 2 else { return nil }
            out[m] = max(0, first.remaining - last.remaining) / (span / 3600)
        }
        return out
    }

    /// The pooled projection. Nil when there isn't enough data: a member without a current reading,
    /// a reset time, or a measured rate.
    public static func pool(_ samples: [QuotaSample], members: [String], kind: QuotaWindowKind,
                            burn: TimeInterval? = nil, now: Date) -> PoolForecast? {
        guard let rates = burnRates(samples, members: members, kind: kind, burn: burn, now: now) else { return nil }
        var soonest: Date?
        var emptyAt = now
        for m in members {
            guard let x = samples.filter({ $0.key == m && $0.kind == kind.rawValue && $0.observedAt <= now })
                    .max(by: { $0.observedAt < $1.observedAt }),
                  let reset = x.resetAt, reset > now, let rate = rates[m] else { return nil }
            let age = now.timeIntervalSince(x.observedAt) / 3600
            let r = max(0, x.remaining - rate * age)
            soonest = min(soonest ?? reset, reset)
            let empty = r <= 0 ? now : rate > 0 ? now.addingTimeInterval(r / rate * 3600) : .distantFuture
            emptyAt = max(emptyAt, empty)
        }
        guard let soonest else { return nil }
        // Before the soonest reset nothing refills, so the pool is empty once its last member is.
        return emptyAt < soonest ? .runsOut(emptyAt) : .lastsUntilReset(soonest)
    }

    /// Members as in `pooledQuota`: enabled accounts of the provider.
    public static func pool(_ samples: [QuotaSample], accounts: [Account], provider: Provider, kind: QuotaWindowKind,
                            now: Date) -> PoolForecast? {
        let enabled = accounts.filter { $0.provider == provider && !$0.disabled }
        guard !enabled.isEmpty else { return nil }
        var current: [String: QuotaSample] = [:]
        for a in enabled {
            guard let seen = a.quota.observedAt, seen <= now,
                  now.timeIntervalSince(seen) <= burnWindow(kind),
                  let used = a.quota.window(kind)?.usedPercent, used.isFinite,
                  let remaining = a.quota.remaining(kind, at: now),
                  let reset = a.quota.window(kind)?.resetAt, reset > now else { return nil }
            let key = accountHistoryKey(a)
            current[key] = QuotaSample(key: key, kind: kind, remaining: remaining, resetAt: reset, observedAt: seen)
        }
        let matching = samples.filter { sample in
            guard let reading = current[sample.key] else { return false }
            return sample.remaining.isFinite && sample.kind == kind.rawValue
                && sample.observedAt <= reading.observedAt && sameInstance(sample, reading)
        }
        // Include the actual current values even if history thinning omitted an unchanged reading.
        let evidence = matching.filter { sample in sample.observedAt != current[sample.key]?.observedAt } + Array(current.values)
        return pool(evidence, members: enabled.map(accountHistoryKey), kind: kind, now: now)
    }
}
