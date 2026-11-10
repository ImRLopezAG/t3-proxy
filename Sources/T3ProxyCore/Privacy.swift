import Foundation

/// Email addresses never reach the screen. The hub names credential files after the account's
/// email (`codex-28b589bb-name@example.com-pro.json`), so every displayed name, nickname and log
/// line goes through `hideEmails`, which keeps the useful parts: `codex-28b589bb-•••-pro.json`.
public enum Privacy {
    public static let placeholder = "•••"

    private static let rules: [NSRegularExpression] = [
        // A well-formed address, stopping before a hub file-name suffix ("-pro", ".json") or a non-address character.
        #"[A-Za-z0-9._%+]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*?\.[A-Za-z]{2,}(?=$|-[A-Za-z0-9]+(?:\.json)?$|\.json$|[^A-Za-z0-9.-])"#,
        // Catch-all for anything still shaped like local@domain (URL-encoded @ included).
        #"[^\s@/"'<>()\[\]{},;:=]+(?:@|%40)[^\s@/"'<>()\[\]{},;:=]+"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func hideEmails(_ s: String) -> String {
        guard s.contains("@") || s.range(of: "%40", options: .caseInsensitive) != nil else { return s }
        var out = s
        for re in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: placeholder)
        }
        return out
    }
}

extension String {
    /// This string with any email address replaced by `•••`.
    public var emailHidden: String { Privacy.hideEmails(self) }
}
