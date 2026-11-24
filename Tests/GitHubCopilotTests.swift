import XCTest
@testable import NotchAgent

final class GitHubCopilotUsageTests: XCTestCase {
    func testReadsCopilotQuotas() throws {
        let json = """
        {"copilot_plan":"individual","quota_reset_date":"2026-10-01T00:00:00Z",
         "quota_snapshots":{
          "chat":{"entitlement":50,"remaining":48,"used":2,"unlimited":false},
          "completions":{"entitlement":2000,"remaining":1990,"used":10,"unlimited":false},
          "premium_interactions":{"entitlement":300,"remaining":294,"used":6,"unlimited":false}}}
        """

        let windows = try GitHubCopilotUsage.windows(from: Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["premium_interactions", "chat", "completions"])
        XCTAssertEqual(windows[0].label, "Premium requests")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertEqual(windows[0].duration, 30 * 86400)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.04, accuracy: 0.0001)
    }

    func testSkipsUnlimitedAndZeroEntitlement() throws {
        let json = """
        {"quota_snapshots":{
          "chat":{"entitlement":0,"remaining":0,"used":0,"unlimited":false},
          "completions":{"entitlement":0,"remaining":0,"used":0,"unlimited":true}}}
        """

        XCTAssertThrowsError(try GitHubCopilotUsage.windows(from: Data(json.utf8))) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testLoadsEnvironmentTokenBeforeHosts() throws {
        let credentials = try GitHubCopilotCredentials.load(
            environment: ["GH_TOKEN": "env-token"],
            hosts: "github.com:\n    user: octocat\n    oauth_token: old-token\n"
        )
        XCTAssertEqual(credentials.token, "env-token")
        XCTAssertEqual(credentials.username, "octocat")
    }

    func testParsesGitHubCLIHosts() throws {
        let credentials = try GitHubCopilotCredentials.load(
            environment: [:],
            hosts: "github.com:\n    user: octocat\n    oauth_token: cli-token\n"
        )
        XCTAssertEqual(credentials.token, "cli-token")
        XCTAssertEqual(credentials.source, "GitHub CLI")
    }

    func testMissingConfiguredTokenRequiresSignIn() {
        XCTAssertThrowsError(try GitHubCopilotCredentials.load(environment: [:], hosts: "github.com:\n  user: octocat\n")) {
            guard case UsageProviderError.needsAuth = $0 else { return XCTFail("Expected sign-in guidance") }
        }
    }

    func testReadsAICreditsAndUsesTheirReportedReset() throws {
        let data = Data(#"""
        {"quota_reset_date_utc":"2026-12-01T00:00:00Z","quota_snapshots":{
          "premium_interactions":{"token_based_billing":true,"entitlement":100,"credits_used":12.5},
          "chat":{"has_quota":false,"entitlement":50,"used":0}}}
        """#.utf8)
        let windows = try GitHubCopilotUsage.windows(from: data)
        XCTAssertEqual(windows.map(\.label), ["AI credits"])
        XCTAssertEqual(windows.first?.usedFraction, 0.125)
        XCTAssertEqual(windows.first?.duration, 30 * 86400)
    }

    func testCreditPercentageCanBeReportedWithoutAnAbsoluteCap() throws {
        let data = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"percent_remaining":75}}}"#.utf8)
        let window = try XCTUnwrap(GitHubCopilotUsage.windows(from: data).first)
        XCTAssertEqual(window.label, "AI credits")
        XCTAssertEqual(window.usedFraction, 0.25)
    }
}
