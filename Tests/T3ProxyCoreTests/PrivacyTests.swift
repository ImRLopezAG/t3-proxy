import Testing
@testable import T3ProxyCore

@Suite struct PrivacyTests {
    @Test func hubFileNamesKeepTheirShape() {
        #expect("codex-28b589bb-jane.doe@example.net-pro.json".emailHidden == "codex-28b589bb-•••-pro.json")
        #expect("codex-be7c1234-jane.doe@example.net-team".emailHidden == "codex-be7c1234-•••-team")
        #expect("claude-00b1-jane.doe@example.net.json".emailHidden == "claude-00b1-•••.json")
        #expect("xai-someone@gmail.com.json".emailHidden == "xai-•••.json")
        #expect("jane@example.co.uk".emailHidden == "•••")
    }

    @Test func textAndLogs() {
        #expect("signed in as jane@example.com, ok".emailHidden == "signed in as •••, ok")
        #expect("user=jane%40example.com".emailHidden == "user=•••")
        #expect("no address here".emailHidden == "no address here")
        #expect(!LogRedactor.redact("auth file claude-a@b.io-pro.json refreshed", secrets: []).contains("a@b.io"))
    }

    @Test func resetCreditIdsAreRedactedInLogs() {
        let line = #"POST consume {"credit_id":"RateLimitResetCredit_abc123","redeem_request_id":"9f1c-77"} list {"id":"RateLimitResetCredit_zz9"}"#
        let out = LogRedactor.redact(line, secrets: [])
        #expect(!out.contains("abc123") && !out.contains("9f1c-77") && !out.contains("zz9"), "\(out)")
    }

    @Test func orgNamesNeverCarryAddresses() {
        #expect(PlanCache.cleanOrg("AI Robotix") == "AI Robotix")
        #expect(PlanCache.cleanOrg("person%40example.com") == nil)
        #expect(PlanCache.cleanOrg("person@example.com") == nil)
    }

    @Test func nothingShapedLikeAnAddressSurvives() {
        for s in ["a.b+c@d-e.f.gh-plus-team.json", "x@y", "codex-1-me@corp.internal-business", "first-last@example.org"] {
            #expect(!s.emailHidden.contains("@"), "\(s) -> \(s.emailHidden)")
        }
    }
}
