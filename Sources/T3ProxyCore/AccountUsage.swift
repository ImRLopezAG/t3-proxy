import Foundation

extension Account {
    /// Proxy Deck records the first 12 hex characters of SHA-256(auth_index).
    public var usageKey: String? {
        guard let authIndex, !authIndex.isEmpty else { return nil }
        return PlanCache.accountKey(authIndex)
    }
}

public struct AccountUsageDay: Sendable, Equatable, Identifiable {
    public let date: Date
    public let totals: UsageTotals
    public let cost: CostEstimate
    public var id: Date { date }
    public init(date: Date, totals: UsageTotals, cost: CostEstimate) { self.date = date; self.totals = totals; self.cost = cost }
}

public struct AccountUsageSummary: Sendable, Equatable {
    public let today: UsageTotals, todayCost: CostEstimate
    public let window: UsageTotals?, windowCost: CostEstimate?
    public let last30: UsageTotals, last30Cost: CostEstimate
    public let days: [AccountUsageDay]
    public let models: [UsageModelRow]
    public init(today: UsageTotals, todayCost: CostEstimate, window: UsageTotals?, windowCost: CostEstimate?,
                last30: UsageTotals, last30Cost: CostEstimate, days: [AccountUsageDay], models: [UsageModelRow]) {
        self.today = today; self.todayCost = todayCost; self.window = window; self.windowCost = windowCost
        self.last30 = last30; self.last30Cost = last30Cost; self.days = days; self.models = models
    }
}

extension UsageSource {
    /// Alternate sources must implement timestamp-filtered aggregation: day-only breakdowns cannot
    /// recover a partial limit window or exclude records after `now` without inventing precision.
    // No default arguments here: with defaults, a call through `any UsageSource` that leaves one out bound to this
    // fallback instead of the conformer's implementation, and every card said "unavailable".
    public func accountSummary(provider: Provider, accountKey: String, windowStart: Date?,
                               now: Date, calendar: Calendar) throws(UsageError) -> AccountUsageSummary {
        throw .unreadable("This usage source does not support account summaries.")
    }
}

struct AccountUsageAccumulator {
    let dates: [Date]
    let provider: Provider
    var daily: [Int: [String: UsageTotals]] = [:]
    var windowModels: [String: UsageTotals]?

    init(dates: [Date], provider: Provider, hasWindow: Bool) {
        self.dates = dates; self.provider = provider
        windowModels = hasWindow ? [:] : nil
    }

    mutating func add(day: Int, inWindow: Bool, model: String, totals: UsageTotals) {
        if inWindow, windowModels != nil {
            windowModels![model] = (windowModels![model] ?? UsageTotals()) + totals
        }
        guard dates.indices.contains(day) else { return }
        daily[day, default: [:]][model] = (daily[day]?[model] ?? UsageTotals()) + totals
    }

    private func cost(_ models: [String: UsageTotals]) -> CostEstimate {
        var result = CostEstimate()
        for (model, totals) in models where totals.total > 0 || totals.requests > 0 {
            result.add(Pricing.cost(totals, model: model), model: model)
        }
        return result
    }

    var summary: AccountUsageSummary {
        let days = dates.enumerated().map {
            let models = daily[$0.offset] ?? [:]
            return AccountUsageDay(date: $0.element, totals: models.values.reduce(UsageTotals(), +), cost: cost(models))
        }
        let models = daily.values.reduce(into: [String: UsageTotals]()) { result, day in
            for (model, totals) in day { result[model] = (result[model] ?? UsageTotals()) + totals }
        }
        let rows = models.map { UsageModelRow(provider: provider, model: $0.key, totals: $0.value, cost: Pricing.cost($0.value, model: $0.key)) }
            .sorted { ($0.totals.total, $0.id) > ($1.totals.total, $1.id) }
        return AccountUsageSummary(today: days.last?.totals ?? UsageTotals(), todayCost: days.last?.cost ?? CostEstimate(),
                                   window: windowModels.map { $0.values.reduce(UsageTotals(), +) }, windowCost: windowModels.map(cost),
                                   last30: models.values.reduce(UsageTotals(), +), last30Cost: cost(models), days: days, models: rows)
    }
}
