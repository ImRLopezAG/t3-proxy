import SwiftUI
import T3ProxyCore

struct NativeUsageAccountTable: View {
    let accounts: [UsageAccountCost]
    let identities: [Account]
    var body: some View {
        Table(accounts) {
            TableColumn("Account") { row in
                HStack {
                    ProviderMark(provider: row.provider, size: 14)
                    Text(nativeUsageAccountLabel(row.accountKey, provider: row.provider, accounts: identities)).lineLimit(1)
                }
            }
            TableColumn("Tokens") { Text(compactTokens($0.totals.total)).monospacedDigit() }.width(80)
            TableColumn("Requests") { Text("\($0.totals.requests)").monospacedDigit() }.width(70)
            TableColumn("Est. cost") { row in Text(row.cost.short).monospacedDigit().help(row.cost.label) }.width(100)
        }.frame(minHeight: 120, maxHeight: 230)
    }
}
