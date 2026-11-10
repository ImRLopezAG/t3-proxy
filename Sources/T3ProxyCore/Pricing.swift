import Foundation

/// List price for one model, USD per million tokens. Used only for "≈ API-equivalent" estimates:
/// subscription accounts are not billed per token.
public struct ModelPrice: Sendable, Equatable {
    public var input: Double, output: Double, cacheRead: Double
    /// nil when the source doesn't publish a cache-write rate; cache-creation tokens then leave the cost unknown.
    public var cacheWrite: Double?
    /// OpenAI reports `input` including cached tokens; Anthropic reports uncached input only.
    public var inputIncludesCacheRead: Bool
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double?, inputIncludesCacheRead: Bool = false) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.inputIncludesCacheRead = inputIncludesCacheRead
    }

    /// USD for `t`, or nil when it has cache-write tokens and no cache-write rate is known.
    /// Reasoning tokens are part of `output` in Proxy Deck's records and are not added again.
    public func cost(_ t: UsageTotals) -> Double? {
        let uncached = inputIncludesCacheRead ? max(0, t.input - t.cached) : t.input
        var usd = Double(uncached) * input + Double(t.output) * output + Double(t.cached) * cacheRead
        if t.cacheCreation > 0 {
            guard let w = cacheWrite else { return nil }
            usd += Double(t.cacheCreation) * w
        }
        return usd / 1_000_000
    }
}

public enum Pricing {
    /// Standard-tier list prices, USD per 1M tokens, as of 2026-11-06.
    ///
    /// Anthropic: the `claude-api` reference (pricing table cached 2026-10-06; cache reads as stated per model,
    /// "~0.1× base input" elsewhere; cache writes 1.25× base input for the 5-minute TTL). The proxy can't tell
    /// 5-minute from 1-hour writes (2×), so writes are priced at 1.25× and may undercount. Haiku 5.5 is $0.10/$0.50
    /// only for prompts up to 100K tokens ($0.50/$2.50 beyond); totals here use the lower tier.
    ///
    /// OpenAI: GPT-6.1 Sol launch post (openai.com/index/introducing-gpt-6-1-sol): $2 input, $0.10 cached input,
    /// $10 output (short context, ≤272K). No official cache-write rate is published there, so none is used.
    /// gpt-6-astra, gpt-6-luna and gpt-6.1-terra are deliberately unpriced: only third-party trackers could be
    /// checked, not an official source.
    public static let table: [String: ModelPrice] = [
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        "claude-haiku-5-5": .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        "gpt-6.1-sol": .init(input: 2, output: 10, cacheRead: 0.10, cacheWrite: nil, inputIncludesCacheRead: true),
    ]

    private static let prefixes = table.keys.sorted { $0.count > $1.count }

    /// Exact id first, then the longest table id that prefixes it at a `-`/`@`/`.` boundary
    /// (dated snapshots, `anthropic.` / `models/` prefixes stripped). Unknown → nil.
    public static func price(for model: String) -> ModelPrice? {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["anthropic.", "openai/", "anthropic/", "models/"] where id.hasPrefix(p) { id.removeFirst(p.count) }
        if let p = table[id] { return p }
        for k in prefixes where id.hasPrefix(k) {
            let rest = id.dropFirst(k.count)
            guard let next = rest.first else { continue }
            if next == "@" || next == ":" || next == "[" { return table[k] }
            // Only dated snapshots ("-20260101", "-2026-01-01"); "-9" or "-mini" would be a different model.
            if next == "-" {
                let seg = rest.dropFirst().prefix { $0 != "-" && $0 != "@" && $0 != ":" && $0 != "[" }
                if seg.count >= 4, seg.allSatisfy(\.isNumber) { return table[k] }
            }
        }
        return nil
    }

    public static func cost(_ t: UsageTotals, model: String) -> Double? { price(for: model)?.cost(t) }
}

/// A cost estimate that knows what it left out.
public struct CostEstimate: Sendable, Equatable {
    public var usd: Double = 0
    /// Model ids with tokens but no price (or no cache-write rate where one was needed).
    public var unpriced: Set<String> = []
    public init(usd: Double = 0, unpriced: Set<String> = []) { self.usd = usd; self.unpriced = unpriced }
    public mutating func add(_ cost: Double?, model: String) {
        if let cost { usd += cost } else { unpriced.insert(model.isEmpty ? "unknown" : model) }
    }
    public static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate { .init(usd: a.usd + b.usd, unpriced: a.unpriced.union(b.unpriced)) }
    /// "≈ $12.34", "≈ $12.34 + 2 unpriced models", or "—" when nothing could be priced.
    public var label: String {
        if usd == 0 && !unpriced.isEmpty { return "— (\(unpricedText))" }
        return "≈ \(formatUSD(usd))" + (unpriced.isEmpty ? "" : " + \(unpricedText)")
    }
    public var short: String { usd == 0 && !unpriced.isEmpty ? "—" : "≈ \(formatUSD(usd))" + (unpriced.isEmpty ? "" : "+") }
    var unpricedText: String { "\(unpriced.count) unpriced model\(unpriced.count == 1 ? "" : "s")" }
}

/// "$12.34", "$1,234", "<$0.01", "$0".
public func formatUSD(_ v: Double) -> String {
    if v <= 0 { return "$0" }
    if v < 0.01 { return "<$0.01" }
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true
    f.groupingSeparator = ","; f.decimalSeparator = "."; f.groupingSize = 3
    let digits = v >= 1000 ? 0 : 2
    f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
    return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v))
}
