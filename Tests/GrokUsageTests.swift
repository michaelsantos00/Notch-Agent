import XCTest
@testable import NotchAgent

/// Pinned to a response recorded from a live SuperGrok CLI session.
final class GrokUsageTests: XCTestCase {
    private let credits = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-05T08:21:18.802818+00:00",\
    "end":"2026-09-12T08:21:18.802818+00:00"},\
    "creditUsagePercent":8.0,\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
    "productUsage":[{"product":"GrokBuild","usagePercent":8.0}],\
    "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},\
    "topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-09-05T08:21:18.802818+00:00",\
    "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
    """

    func testTheRingIsTheCreditsPercentage() throws {
        let reading = try GrokUsage.reading(creditsJSON: credits)
        let credits = reading.window
        XCTAssertTrue(reading.isWeekly)
        XCTAssertEqual(credits.id, "credits")
        XCTAssertEqual(credits.duration, 7 * 86400)
        XCTAssertEqual(credits.label, "Weekly limit")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.08, accuracy: 0.0001)
    }

    func testWeeklyCreditsHaveTheirOwnReset() throws {
        let credits = try GrokUsage.reading(creditsJSON: credits).window
        let reset = try XCTUnwrap(credits.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 9)
        XCTAssertEqual(utc.component(.day, from: reset), 12)
    }

    /// An empty config has nothing to draw a ring from — not a reading of
    /// zero, an absence of one.
    func testAnEmptyConfigIsNotASuccessfulReading() {
        XCTAssertThrowsError(try GrokUsage.reading(
            creditsJSON: #"{"config":{}}"#
        )) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testAProductShareDoesNotStandInForTheSharedQuota() {
        let productOnly = """
        {"config":{"productUsage":[{"product":"GrokBuild","usagePercent":33.0}],\
        "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
        """
        XCTAssertThrowsError(try GrokUsage.reading(creditsJSON: productOnly)) { error in
            guard case UsageProviderError.apiError = error else {
                return XCTFail("Expected unavailable shared usage, got \(error)")
            }
        }
    }

    func testWeeklyPoolRequiresAnExplicitPercentage() throws {
        let weeklyOnly = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-09-07T20:59:12+00:00",\
        "end":"2026-09-14T20:59:12+00:00"},\
        "onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
        "isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}
        """
        XCTAssertThrowsError(try GrokUsage.reading(creditsJSON: weeklyOnly)) { error in
            guard case UsageProviderError.apiError = error else {
                return XCTFail("Expected unavailable shared usage, got \(error)")
            }
        }
        let reportedZero = weeklyOnly.replacingOccurrences(of: "\"onDemandCap\"",
                                                            with: "\"creditUsagePercent\":0,\"onDemandCap\"")
        let credits = try GrokUsage.reading(creditsJSON: reportedZero).window
        XCTAssertEqual(credits.label, "Weekly limit")
        XCTAssertEqual(credits.usedFraction ?? -1, 0, accuracy: 0.0001)
        let reset = try XCTUnwrap(credits.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 9)
        XCTAssertEqual(utc.component(.day, from: reset), 14)
    }

    func testGarbageIsABadResponseRatherThanAGuess() {
        XCTAssertThrowsError(try GrokUsage.reading(creditsJSON: "not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testMonthlyCreditsKeepTheirMonthlyLabel() throws {
        let monthly = credits.replacingOccurrences(of: "USAGE_PERIOD_TYPE_WEEKLY", with: "USAGE_PERIOD_TYPE_MONTHLY")
        let reading = try GrokUsage.reading(creditsJSON: monthly)
        XCTAssertEqual(reading.window.label, "Monthly limit")
        XCTAssertFalse(reading.isWeekly)
    }

    /// The issuer is compared whole: a host that merely begins with
    /// `auth.x.ai` is someone else's, and its token must not be sent to xAI.
    func testALookalikeIssuerIsNotTrusted() {
        XCTAssertFalse(GrokCredentials.isTrusted(key: "https://auth.x.ai.example.com::cli", entry: [:]))
        XCTAssertFalse(GrokCredentials.isTrusted(key: "https://auth.x.aix::cli", entry: [:]))
        XCTAssertTrue(GrokCredentials.isTrusted(key: "https://auth.x.ai::cli", entry: [:]))
        XCTAssertTrue(GrokCredentials.isTrusted(key: "https://auth.x.ai", entry: [:]))
    }
}
