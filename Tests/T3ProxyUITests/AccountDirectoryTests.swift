import Testing
import T3ProxyCore
@testable import T3ProxyUI

@Suite struct AccountDirectoryTests {
    let credentials = [
        Credential(name: "claude-one.json", provider: .claude, nickname: "Work", plan: "team"),
        Credential(name: "claude-two.json", provider: .claude, nickname: "Work", plan: "max", disabled: true, status: .disabled),
        Credential(name: "codex-one.json", provider: .codex, nickname: "Personal", plan: "pro"),
        Credential(name: "xai-one.json", provider: .other, providerName: "xai")
    ]

    @Test func searchFindsIdentityPlanAndProviderWithoutLosingGroups() {
        let work = AccountDirectory.groups(credentials, search: "work", filter: .all)
        #expect(work.count == 1)
        #expect(work.first?.credentials.map(\.name) == ["claude-one.json", "claude-two.json"])
        #expect(AccountDirectory.groups(credentials, search: "pro", filter: .all).first?.credentials.first?.nickname == "Personal")
        #expect(AccountDirectory.groups(credentials, search: "xai", filter: .all).first?.title == "xai")
        #expect(AccountDirectory.groups(credentials, search: "missing", filter: .all).isEmpty)
    }

    @Test func filteringPreservesIdentityAndOnlyDisambiguatesDuplicateNicknames() {
        #expect(AccountDirectory.groups(credentials, search: "", filter: .disabled).flatMap(\.credentials).map(\.name) == ["claude-two.json"])
        #expect(AccountDirectory.groups(credentials, search: "", filter: .enabled).flatMap(\.credentials).count == 3)
        #expect(AccountDirectory.disambiguator(for: credentials[0], among: credentials) != nil)
        #expect(AccountDirectory.disambiguator(for: credentials[2], among: credentials) == nil)
        #expect(AccountDirectory.disambiguator(for: credentials[0], among: credentials) != AccountDirectory.disambiguator(for: credentials[1], among: credentials))
    }
}
