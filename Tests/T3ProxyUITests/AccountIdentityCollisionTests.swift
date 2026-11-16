import Testing
import T3ProxyCore
@testable import T3ProxyUI

@Suite struct AccountIdentityCollisionTests {
    @Test func maskedFilenamesRemainDistinctAndStableAcrossSorting() {
        let a = Credential(name: "claude-alice@example.com.json", provider: .claude, nickname: "Work", plan: "team")
        let b = Credential(name: "claude-bob@example.com.json", provider: .claude, nickname: "Work", plan: "team")
        #expect(a.name.emailHidden == b.name.emailHidden)
        let first = AccountDirectory.disambiguator(for: a, among: [a, b])
        let second = AccountDirectory.disambiguator(for: b, among: [a, b])
        #expect(first != second)
        #expect(first == AccountDirectory.disambiguator(for: a, among: [b, a]))
        #expect(first?.contains("@") == false)
        #expect(first?.contains("alice") == false)
    }
}

@Suite struct AccountProviderIdentityTests {
    @Test func providerGroupingDisambiguatesMatchingNicknames() {
        let claude = Credential(name: "claude-work.json", provider: .claude, nickname: "Work")
        let codex = Credential(name: "codex-work.json", provider: .codex, nickname: "Work")
        #expect(AccountDirectory.disambiguator(for: claude, among: [claude, codex]) == nil)
        #expect(AccountDirectory.disambiguator(for: codex, among: [claude, codex]) == nil)
    }
}
