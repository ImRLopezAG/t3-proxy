import Foundation

/// One hub log line, parsed from text that `LogRedactor` has already scrubbed.
/// Shape: `[time] [request id] [level] [file.go:123] message`, where the message of a gin access
/// line is `status | latency | client ip | METHOD "path"`. Unknown shapes keep the whole line as message.
public struct LogLine: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable, CaseIterable { case error, warn, info, debug, other }

    public struct Access: Sendable, Equatable {
        public var status: Int
        public var latency: String
        /// Latency in milliseconds, when the Go duration string parses.
        public var latencyMs: Double?
        public var clientIP: String
        public var method: String
        public var path: String
    }

    /// Arrival order, assigned by the viewer; the identity for tables.
    public var seq: Int = 0
    public var id: Int { seq }
    public var raw: String
    public var time: String?
    public var requestID: String?
    public var level: Level
    /// Everything after the level tag (source included), as Proxy Deck's parseLine().
    public var message: String
    /// `file.go:123` when the message starts with one.
    public var source: String?
    /// The message without its source tag.
    public var text: String
    public var access: Access?

    private static let line = try! NSRegularExpression(
        pattern: #"^\[(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}[^\]]*)\]\s*(?:\[([A-Za-z0-9_-]{4,64}|-+)\]\s*)?\[\s*([A-Za-z]+)\s*\]\s*(.*)$"#,
        options: [.dotMatchesLineSeparators])
    private static let levels: [String: Level] = ["error": .error, "fatal": .error, "panic": .error, "warn": .warn, "warning": .warn,
                                                   "info": .info, "debug": .debug, "trace": .debug]

    public init(_ raw: String, seq: Int = 0) {
        self.seq = seq
        self.raw = raw
        let ns = raw as NSString
        if let m = Self.line.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            time = g(1)
            requestID = g(2).flatMap { $0.allSatisfy { $0 == "-" } ? nil : $0 }
            level = Self.levels[(g(3) ?? "").lowercased()] ?? .other
            message = g(4) ?? ""
            (source, text) = Self.splitSource(message)
            access = Self.parseAccess(text)
        } else {
            let word = raw.range(of: #"\b(error|fatal|panic|warn(?:ing)?|info|debug|trace)\b"#, options: [.regularExpression, .caseInsensitive])
            level = word.flatMap { Self.levels[raw[$0].lowercased()] } ?? .other
            message = raw
            text = raw
        }
    }

    /// The access path, or the message text.
    public var detail: String { access?.path ?? text }

    /// A call to the hub's own management API (this app's polling included).
    public var isManagementCall: Bool {
        guard let p = access?.path else { return false }
        return p.hasPrefix("/v0/management") || p.hasPrefix("/v8/management")
    }

    /// `[name.ext:123] rest` → ("name.ext:123", "rest").
    static func splitSource(_ m: String) -> (String?, String) {
        guard m.hasPrefix("["), let close = m.prefix(256).firstIndex(of: "]") else { return (nil, m) }
        let inner = m[m.index(after: m.startIndex)..<close]
        guard let colon = inner.lastIndex(of: ":"), colon != inner.startIndex,
              case let digits = inner[inner.index(after: colon)...], !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              !inner.contains(where: \.isWhitespace)
        else { return (nil, m) }
        return (String(inner), m[m.index(after: close)...].trimmingCharacters(in: .whitespaces))
    }

    /// gin: `200 | 102ms | 127.0.0.1 | GET "/path"`.
    static func parseAccess(_ t: String) -> Access? {
        let parts = t.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, parts[0].count == 3, let status = Int(parts[0]), (100...599).contains(status) else { return nil }
        let req = parts[3]
        guard let sp = req.firstIndex(where: \.isWhitespace) else { return nil }
        let method = String(req[..<sp])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        var path = req[sp...].trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        return Access(status: status, latency: parts[1], latencyMs: goDurationMs(parts[1]), clientIP: parts[2], method: method, path: path)
    }

    /// Go's Duration.String(): `1h2m3.5s`, `102.3ms`, `45µs`, `800ns`.
    static func goDurationMs(_ s: String) -> Double? {
        let units: [(String, Double)] = [("ns", 1e-6), ("µs", 1e-3), ("μs", 1e-3), ("us", 1e-3), ("ms", 1), ("h", 3_600_000), ("m", 60_000), ("s", 1000)]
        var rest = Substring(s), total = 0.0
        guard !rest.isEmpty, rest.count <= 64 else { return nil }
        while !rest.isEmpty {
            let num = rest.prefix { $0.isNumber || $0 == "." }
            guard !num.isEmpty, let v = Double(num) else { return nil }
            rest = rest.dropFirst(num.count)
            guard let u = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += v * u.1
            rest = rest.dropFirst(u.0.count)
        }
        return total
    }

    /// Proxy Deck's filterLines(): level (nil = all) and a case-insensitive substring over the whole line.
    public static func filter(_ lines: [LogLine], level: Level?, query: String, hideManagement: Bool = false) -> [LogLine] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return lines.filter {
            (level == nil || $0.level == level) && !(hideManagement && $0.isManagementCall)
                && (q.isEmpty || $0.raw.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }
}
