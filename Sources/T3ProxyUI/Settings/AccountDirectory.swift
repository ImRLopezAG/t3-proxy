import SwiftUI
import T3ProxyCore
import CryptoKit

enum AccountFilter: String, CaseIterable {
    case all = "All accounts", enabled = "Enabled", disabled = "Disabled"
}

enum AccountDirectory {
    struct Group: Identifiable {
        let id: String
        let title: String
        let credentials: [Credential]
    }

    static func groups(_ credentials: [Credential], search: String, filter: AccountFilter) -> [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = credentials.filter { c in
            let included = filter == .all || (filter == .disabled ? c.disabled : !c.disabled)
            let fields = [c.label, c.name, c.provider.title, c.providerName, c.planLabel ?? "", c.org ?? ""]
            return included && (query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return Dictionary(grouping: matches, by: { $0.provider == .other ? $0.providerName : $0.provider.rawValue })
            .map { key, values in
                Group(id: key, title: values[0].provider == .other ? values[0].providerName : values[0].provider.title,
                      credentials: values.sorted { $0.label == $1.label ? $0.name < $1.name : $0.label.localizedStandardCompare($1.label) == .orderedAscending })
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func disambiguator(for credential: Credential, among all: [Credential]) -> String? {
        let peers = all.filter { $0.provider == credential.provider && ($0.provider != .other || $0.providerName == credential.providerName) }
        guard credential.nickname != nil,
              peers.contains(where: { $0.id != credential.id && $0.label.emailHidden == credential.label.emailHidden }) else { return nil }
        let masked = credential.name.emailHidden
        let collisions = peers.filter { $0.label.emailHidden == credential.label.emailHidden && $0.name.emailHidden == masked }
        guard collisions.count > 1 else { return masked }
        let fingerprints = Dictionary(uniqueKeysWithValues: collisions.map {
            ($0.id, SHA256.hash(data: Data($0.id.utf8)).map { String(format: "%02x", $0) }.joined())
        })
        var length = 6
        while length < 64 && Set(fingerprints.values.map { $0.prefix(length) }).count < fingerprints.count { length += 2 }
        return masked + " · " + String(fingerprints[credential.id]!.prefix(length))
    }
}

struct AccountQuotaBar: View {
    let quota: QuotaReading?
    let kind: QuotaWindowKind
    let provider: Provider
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let remaining = quota?.remaining(kind, at: now)
        let window = quota?.accountWindows().first { $0.window.kind == kind }
        let state = window.flatMap { window in quota.map { WindowState(window, $0, now: now) } }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(kind == .session ? "5-hour" : "Weekly").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? (state?.expired == true ? "Expired" : "—"))
                    .monospacedDigit().foregroundStyle(remaining == 0 ? .red : .primary)
            }.font(.caption)
            PaceBar(remaining: remaining, pace: state?.pace,
                    tint: state?.fill(Theme(scheme).tint(provider)) ?? Theme(scheme).tint(provider))
                .frame(height: 4)
        }
        .help(quota?.window(kind)?.resetAt.map { "\(kind.title) resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No current \(kind.title.lowercased()) reading")
        .accessibilityElement(children: .combine)
    }
}
