import AppKit
import SwiftUI
import T3ProxyCore

/// The same verified reset flow in the menu panel, hover card and Settings. Inline tickets are scoped to
/// the limit they affect; details show every type separately, including an uncertain attempt with no status.
struct QuotaResetControls: View {
    let account: Account
    @ObservedObject var live: LiveQuotaModel
    let now: Date
    var windowID: String? = nil
    var compact = false
    var connected = true

    private var busy: Bool { live.claiming != nil || live.preparingClaude != nil }

    var body: some View {
        if !account.disabled {
            if account.provider == .claude { claude }
            else if account.provider == .codex, windowID == nil || windowID == "weekly" { codex }
        }
    }

    @ViewBuilder private var claude: some View {
        let pending = live.claudePending[account.id]
        let status = account.quota.claudeResets
        let grants = status?.grants.filter { $0.isUnexpired(at: now) } ?? []
        if !compact, grants.isEmpty, pending == nil {
            Text(status == nil ? (live.refreshing ? "Checking reset credits…" : "Reset credits unavailable") : "No banked resets")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        ForEach(ClaudeResetKind.allCases, id: \.self) { kind in
            if windowID == nil || (windowID == "weekly" && kind != .fable) || (windowID?.contains("fable") == true && kind == .fable) {
                let group = grants.filter { $0.kind == kind }
                let retry = pending?.confirmation.grant.kind == kind
                if let grant = (retry ? pending?.confirmation.grant : nil)
                    ?? group.first(where: { status?.canUse($0, at: now) == true }) ?? group.first {
                    let count = group.reduce(0) { $0 + $1.resetsLeft }
                    let enabled = connected && !busy && (retry || pending == nil && status?.canUse(grant, at: now) == true)
                    ticket(title: kind.title, short: kind == .fable ? "F" : kind == .weekly ? "W" : "Full",
                           count: count, retry: retry, expiry: group.compactMap(\.expiresAt).min(), enabled: enabled,
                           effect: claudeResetEffect(grant)) {
                        Task { @MainActor in
                            guard let intent = await live.claudeIntent(for: account, grant: grant) else { return }
                            let retry = live.claudePending[account.id] != nil
                            let expiry = intent.confirmation.grant.expiresAt.map { " Expires \(resetDate($0))." } ?? ""
                            let message = retry ? "Sends the same grant and request again. If the first attempt went through, this won't spend another reset."
                                : claudeResetEffect(intent.confirmation.grant) + " This uses one banked reset and can't be undone." + expiry
                            if await confirmReset(title: "\(retry ? "Retry" : "Use") \(kind.title.lowercased()) on “\(live.label(for: account))”?",
                                                  message: message, retry: retry) {
                                await live.useClaudeReset(intent)
                            }
                        }
                    }
                    if !compact {
                        let shown = group + (retry && !group.contains(where: { $0.id == grant.id }) ? [grant] : [])
                        ForEach(shown) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.title) · \(item.resetsLeft) banked")
                                Text(item.expiresAt.map { "Expires \(resetDate($0))" } ?? "No expiry reported")
                                Text(claudeResetEffect(item))
                                if pending?.confirmation.grant.id == item.id { Text("Unconfirmed · retry keeps this grant") }
                                else if item.paused || !item.usableNow { Text(item.paused ? "Paused" : "Not currently usable") }
                            }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var codex: some View {
        let retry = live.pending[account.id] != nil
        let list = live.credits[account.id]
        let count = list?.count ?? account.quota.availableResetCredits ?? 0
        if retry || count > 0 {
            ticket(title: "Full reset", short: "Full", count: count, retry: retry,
                   expiry: (live.pending[account.id]?.credit ?? list?.first)?.expiresAt,
                   enabled: connected && !busy && (retry || list?.isEmpty == false), effect: "Restarts 5-hour and weekly limits.") {
                guard let intent = live.intent(for: account) else { return }
                let expiry = (live.pending[account.id]?.credit ?? list?.first)?.expiresAt.map { " Expires \(resetDate($0))." } ?? ""
                Task { @MainActor in
                    if await confirmReset(title: "\(retry ? "Retry" : "Use") full reset on “\(live.label(for: account))”?",
                                          message: retry ? "Sends the same reset request again. If the first one went through, no second credit is spent."
                                            : "Restarts this account's 5-hour and weekly limits. This uses one banked reset and can't be undone." + expiry,
                                          retry: retry) {
                        await live.useReset(intent)
                    }
                }
            }
        }
    }

    @ViewBuilder private func ticket(title: String, short: String, count: Int, retry: Bool, expiry: Date?,
                                     enabled: Bool, effect: String, action: @escaping () -> Void) -> some View {
        if compact {
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: retry ? "exclamationmark.arrow.circlepath" : "ticket")
                    Text(retry ? "Retry" : "\(short) \(count)")
                }.font(.system(size: 10, weight: .medium)).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).disabled(!enabled)
            .help("\(title): \(retry ? "unconfirmed, retry the same request" : "\(count) banked"). Confirmation required.")
            .accessibilityLabel("\(retry ? "Retry" : "Use") \(title) for \(live.label(for: account)), \(count) banked")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(title, systemImage: "ticket").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(retry ? "Unconfirmed" : "\(count) banked").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button(retry ? "Retry…" : "Use…", action: action).controlSize(.mini).disabled(!enabled)
                        .accessibilityLabel("\(retry ? "Retry" : "Use") \(title) for \(live.label(for: account))")
                }
                if account.provider == .codex {
                    Text(retry ? "Retry keeps the same grant and request." : expiry.map { "Next expires \(resetDate($0))" } ?? "No expiry reported")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(effect).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

func claudeResetEffect(_ grant: ClaudeResetGrant) -> String {
    if grant.givesBackWeekly {
        return "Returns Fable's contribution to weekly usage."
            + (grant.clears.contains("five_hour") ? " Also restarts the 5-hour window." : "")
    }
    let session = grant.clears.contains("five_hour"), weekly = grant.clears.contains("seven_day")
    if session && weekly { return "Restarts the 5-hour and weekly limits covered by this grant." }
    if weekly { return "Restarts the weekly limits covered by this grant." }
    if session { return "Restarts the 5-hour limits covered by this grant." }
    return "Resets the usage limits covered by this grant."
}

private func resetDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened) + " " + (TimeZone.current.abbreviation(for: date) ?? "")
}

/// NSAlert works from the nonactivating menu panel as well as Settings; mutations stay behind the final button.
@MainActor private func confirmReset(title: String, message: String, retry: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            HoverCards.hide()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: retry ? "Retry Reset" : "Use Reset")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            NSApp.activate()
            alert.window.level = .popUpMenu
            continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
