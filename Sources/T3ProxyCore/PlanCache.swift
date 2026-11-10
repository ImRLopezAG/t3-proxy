import Foundation
import CryptoKit

/// Plan and organization labels for an account ("max 20x", "team" / "AI-Robotix").
public struct PlanInfo: Sendable, Equatable {
    public var plan: String?
    public var org: String?
    public var orgID: String?
    public var observedAt: Date?
    public func freshOrgID(now: Date = Date()) -> String? {
        guard let observedAt, observedAt <= now, now.timeIntervalSince(observedAt) < 7 * 86400 else { return nil }; return orgID
    }
    public init(plan: String?, org: String?, orgID: String? = nil, observedAt: Date? = nil) { self.plan = plan; self.org = org; self.orgID = orgID; self.observedAt = observedAt }
}

/// Claude does not report plans to the hub. Proxy Deck learned them from account profile reads and
/// keeps them in `.data/plans.json`, keyed by its opaque account key. T3 Proxy reads that file
/// read-only (never writes, never contacts a provider) until it learns plans itself.
public enum PlanCache {
    public static let proxyDeckPath = NSHomeDirectory() + "/.t3/scratch/2026-10-29-search-a-thread-on-t3-6ad5e6d1/.data/plans.json"

    public static var ownURL: URL { UsageRecorder.defaultDatabaseURL.deletingLastPathComponent().appendingPathComponent("plans.json") }
    public static func orgFingerprint(_ uuid: String?) -> String? {
        guard let uuid = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), uuid.range(of: #"^[0-9a-f-]{8,64}$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return SHA256.hash(data: Data(uuid.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

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

    /// Records one account's plan/org fingerprint in T3 Proxy's own plans.json (0600, atomic), in Proxy Deck's format.
    /// Only allowlisted plans, cleaned org names and 16-hex fingerprints are written.
    private static let writeLock = NSLock()
    public static func record(key: String, _ info: PlanInfo, at url: URL = ownURL) {
        guard key.range(of: #"^[a-f0-9]{12}$"#, options: .regularExpression) != nil,
              let plan = info.plan.flatMap({ isPlan($0) ? $0 : nil }) else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        let fm = FileManager.default
        var raw = (fm.contents(atPath: url.path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let orgID = info.orgID.flatMap { $0.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil ? $0 : nil }
        raw[key] = ["plan": plan, "org": cleanOrg(info.org) as Any? ?? NSNull(), "orgId": orgID as Any? ?? NSNull(),
                    "at": ((info.observedAt ?? Date()).timeIntervalSince1970 * 1000).rounded()]
        guard raw.count <= 500, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { return }
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if fm.fileExists(atPath: url.path) { _ = try? fm.replaceItemAt(url, withItemAt: tmp) } else { try? fm.moveItem(at: tmp, to: url) }
    }

    /// Missing, unreadable or malformed files give an empty map (plans then show as unknown).
    public static func load(path: String? = nil) -> [String: PlanInfo] {
        if let path = path ?? UserDefaults.standard.string(forKey: "planCachePath") { return read(path: path) }
        return load(ownPath: ownURL.path, fallbackPath: proxyDeckPath)
    }
    public static func load(ownPath: String, fallbackPath: String) -> [String: PlanInfo] {
        read(path: fallbackPath).merging(read(path: ownPath)) { _, own in own }
    }
    private static func read(path: String) -> [String: PlanInfo] {
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
            if plan != nil || org != nil {
                let validOrg = e["org"] is NSNull || ((e["org"] as? String) != nil && org != nil)
                let orgID = (e["orgId"] as? String).flatMap { $0.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil ? $0 : nil }
                let at = (e["at"] as? Double).flatMap { $0.isFinite && $0 >= 0 && $0 <= Date().timeIntervalSince1970 * 1000 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                out[key] = PlanInfo(plan: plan, org: org, orgID: (plan != nil && validOrg) ? orgID : nil, observedAt: at)
            }
        }
        return out
    }
}
