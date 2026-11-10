import Foundation
import CryptoKit

/// Plan and organization labels for an account ("max 20x", "team" / "AI-Robotix").
public struct PlanInfo: Sendable, Equatable {
    public var plan: String?
    public var org: String?
    public init(plan: String?, org: String?) { self.plan = plan; self.org = org }
}

/// Claude does not report plans to the hub. Proxy Deck learned them from account profile reads and
/// keeps them in `.data/plans.json`, keyed by its opaque account key. T3 Proxy reads that file
/// read-only (never writes, never contacts a provider) until it learns plans itself.
public enum PlanCache {
    public static let proxyDeckPath = NSHomeDirectory() + "/.t3/scratch/2026-10-29-search-a-thread-on-t3-6ad5e6d1/.data/plans.json"

    /// Proxy Deck's `accountKey()`: first 12 hex characters of SHA-256 of the hub's `auth_index`.
    public static func accountKey(_ authIndex: String) -> String {
        SHA256.hash(data: Data(authIndex.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Proxy Deck's PLAN_LABEL allowlist; anything else is dropped.
    static func isPlan(_ s: String) -> Bool {
        s.range(of: #"^(free|go|plus|pro|max|max [1-9]\d?x|team|team premium|business|enterprise|edu)$"#, options: .regularExpression) != nil
    }

    /// Org names are display text only: no emails, no control characters, short.
    static func cleanOrg(_ s: String?) -> String? {
        guard let s, !s.contains("@"), s.emailHidden == s, s.range(of: "%40", options: .caseInsensitive) == nil, let c = ManagementRules.cleanNickname(s, max: 64), c == s else { return nil }
        return c
    }

    /// Missing, unreadable or malformed files give an empty map (plans then show as unknown).
    public static func load(path: String = UserDefaults.standard.string(forKey: "planCachePath") ?? proxyDeckPath) -> [String: PlanInfo] {
        // Check the size before reading so an unexpectedly large file is never loaded.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size < 1_000_000,
              let data = FileManager.default.contents(atPath: path), data.count < 1_000_000,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: PlanInfo] = [:]
        for (key, value) in raw.prefix(500) {
            guard key.range(of: #"^[a-f0-9]{12}$"#, options: .regularExpression) != nil,
                  let e = value as? [String: Any] else { continue }
            let plan = (e["plan"] as? String).flatMap { isPlan($0) ? $0 : nil }
            let org = cleanOrg(e["org"] as? String)
            if plan != nil || org != nil { out[key] = PlanInfo(plan: plan, org: org) }
        }
        return out
    }
}
