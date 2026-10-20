import XCTest
@testable import NotchAgent

/// Reads the "Cloud usage" section of ollama.com/settings — the only place the
/// session and weekly percentages are still published since the API went to
/// request counts.
final class OllamaWebUsageTests: XCTestCase {
    /// The structure of the signed-in page, trimmed to the usage section, with
    /// the classes stripped. The anchors read are the meters' `aria-label`s, the
    /// `data-time` after each, and the segments' `data-model`/`data-requests`.
    private let signedIn = """
    <a href="/signout">Sign out</a>
    <h2 class="text-xl font-medium">Cloud usage</h2>
    <div><span class="text-sm ">Session usage</span><span class="text-sm "> 1.3% used </span></div>
    <div data-usage-meter>
      <div data-usage-track aria-label="Session usage 1.3% used">
        <div style="width: 1.3%; ">
          <button type="button" style="width: 92.6%" data-usage-segment data-model="web search" data-requests="12"></button>
          <button type="button" style="width: 6.2%" data-usage-segment data-model="web fetch" data-requests="12"></button>
        </div>
      </div>
    </div>
    <div class="local-time" data-time="2026-10-20T16:00:00Z"> Resets in 30 minutes. </div>
    <div><span>Weekly usage</span><span>1.4% used</span></div>
    <div data-usage-meter>
      <div data-usage-track aria-label="Weekly usage 1.4% used">
        <div style="width: 1.4%">
          <button type="button" data-usage-segment data-model="web search" data-requests="40"></button>
          <button type="button" data-usage-segment data-model="glm-5.3" data-requests="7"></button>
          <button type="button" data-usage-segment data-model="deepseek-v4.1-flash:1017" data-requests="2"></button>
        </div>
      </div>
    </div>
    <div class="local-time" data-time="2026-10-26T00:00:00Z"> Resets in 5 days. </div>
    """

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testSessionAndWeeklyAreFractionsWithTheirResets() throws {
        let result = try OllamaWebUsage.parse(signedIn)
        let session = try XCTUnwrap(result.windows.first { $0.id == "session" })
        let weekly = try XCTUnwrap(result.windows.first { $0.id == "weekly" })

        XCTAssertEqual(session.usedFraction ?? -1, 0.013, accuracy: 0.00001)
        XCTAssertEqual(session.resetsAt, date("2026-10-20T16:00:00Z"))
        XCTAssertEqual(session.duration, 5 * 3600)
        XCTAssertEqual(weekly.usedFraction ?? -1, 0.014, accuracy: 0.00001)
        XCTAssertEqual(weekly.resetsAt, date("2026-10-26T00:00:00Z"))
        XCTAssertEqual(weekly.duration, 7 * 86400)
        XCTAssertEqual(result.headlineID, "session")
    }

    /// The weekly meter's segments become per-model rows, so the tooltip says
    /// what the week went on.
    func testWeeklyModelsAreCountedRows() throws {
        let rows = try OllamaWebUsage.parse(signedIn).windows.filter { $0.id.hasPrefix("weekly.") }
        XCTAssertEqual(rows.map(\.label), ["web search", "glm-5.3", "deepseek-v4.1-flash:1017"])
        XCTAssertEqual(rows.map(\.used), [40, 7, 2])
        XCTAssertTrue(rows.allSatisfy { $0.usedFraction == nil })
    }

    /// A stale cookie lands on a page with no usage on it and a way to sign in.
    func testASignedOutPageAsksForSignIn() {
        let signedOut = #"<a href="https://signin.ollama.com/">Sign in</a><h1>Welcome</h1>"#
        XCTAssertThrowsError(try OllamaWebUsage.parse(signedOut)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// Signed in but no meters means the page changed under us — say so,
    /// rather than claiming the account is signed out.
    func testASignedInPageWithoutMetersIsABadResponse() {
        XCTAssertThrowsError(try OllamaWebUsage.parse(#"<a href="/signout">Sign out</a>"#)) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }
}
